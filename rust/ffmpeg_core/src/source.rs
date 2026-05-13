use std::collections::VecDeque;
use std::path::Path;
use std::slice;
use std::time::Duration;

use ffmpeg_next as ffmpeg;
use ffmpeg::util::mathematics::{rescale::TIME_BASE, Rescale};
use ffmpeg::{
    codec, frame, media, software, util::format::sample::Type as SampleType,
};

use crate::{ensure_initialized, AudioProbe, Error, Result};

fn is_again(error: &ffmpeg::Error) -> bool {
    matches!(
        *error,
        ffmpeg::Error::Other {
            errno,
        } if errno == ffmpeg::error::EAGAIN || errno == ffmpeg::error::EWOULDBLOCK
    )
}

fn input_duration(input: &ffmpeg::format::context::Input, sample_rate: u32) -> Option<Duration> {
    if input.duration() > 0 {
        return Some(Duration::from_micros(input.duration() as u64));
    }

    let stream = input.streams().best(media::Type::Audio)?;
    if stream.duration() <= 0 || sample_rate == 0 {
        return None;
    }

    let duration_us = stream.duration().rescale(stream.time_base(), TIME_BASE);
    (duration_us > 0).then(|| Duration::from_micros(duration_us as u64))
}

fn build_resampler(
    source_format: ffmpeg::format::Sample,
    source_layout: ffmpeg::ChannelLayout,
    source_rate: u32,
    target_format: ffmpeg::format::Sample,
    target_layout: ffmpeg::ChannelLayout,
    target_rate: u32,
) -> Result<software::resampling::Context> {
    software::resampler(
        (source_format, source_layout, source_rate),
        (target_format, target_layout, target_rate),
    )
    .map_err(Error::from)
}

pub struct AudioSource {
    probe: AudioProbe,
    input: ffmpeg::format::context::Input,
    stream_index: usize,
    decoder: codec::decoder::Audio,
    resampler: software::resampling::Context,
    source_format: ffmpeg::format::Sample,
    source_layout: ffmpeg::ChannelLayout,
    source_rate: u32,
    target_format: ffmpeg::format::Sample,
    target_layout: ffmpeg::ChannelLayout,
    target_rate: u32,
    pending_samples: VecDeque<f32>,
    finished: bool,
}

unsafe impl Send for AudioSource {}

impl AudioSource {
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        ensure_initialized()?;

        let input = ffmpeg::format::input(path.as_ref()).map_err(Error::from)?;
        let stream = input
            .streams()
            .best(media::Type::Audio)
            .ok_or(Error::NoAudioStream)?;

        let stream_index = stream.index();
        let context = codec::context::Context::from_parameters(stream.parameters())
            .map_err(Error::from)?;
        let mut decoder = context.decoder().audio().map_err(Error::from)?;
        decoder
            .set_parameters(stream.parameters())
            .map_err(Error::from)?;
        decoder.set_packet_time_base(stream.time_base());

        let source_layout = if decoder.channel_layout().is_empty() {
            ffmpeg::ChannelLayout::default(i32::from(decoder.channels()))
        } else {
            decoder.channel_layout()
        };
        let source_format = decoder.format();
        let source_rate = decoder.rate();
        if source_rate == 0 {
            return Err(Error::InvalidSampleRate);
        }
        let channel_count = source_layout.channels() as u16;
        if channel_count == 0 {
            return Err(Error::InvalidChannelCount);
        }

        let target_format = ffmpeg::format::Sample::F32(SampleType::Packed);
        let target_layout = source_layout;
        let target_rate = source_rate;
        let resampler = build_resampler(
            source_format,
            source_layout,
            source_rate,
            target_format,
            target_layout,
            target_rate,
        )?;

        let total_duration = input_duration(&input, source_rate);
        let probe = AudioProbe {
            channels: channel_count,
            sample_rate: source_rate,
            total_duration,
            seekable: true,
        };

        Ok(Self {
            probe,
            input,
            stream_index,
            decoder,
            resampler,
            source_format,
            source_layout,
            source_rate,
            target_format,
            target_layout,
            target_rate,
            pending_samples: VecDeque::new(),
            finished: false,
        })
    }

    pub fn probe(&self) -> &AudioProbe {
        &self.probe
    }

    pub fn channels(&self) -> u16 {
        self.probe.channels
    }

    pub fn sample_rate(&self) -> u32 {
        self.probe.sample_rate
    }

    pub fn total_duration(&self) -> Option<Duration> {
        self.probe.total_duration
    }

    pub fn current_span_len(&self) -> Option<usize> {
        if self.pending_samples.is_empty() {
            None
        } else {
            Some(self.pending_samples.len())
        }
    }

    pub fn seek_to(&mut self, position: Duration) -> Result<()> {
        if !self.probe.seekable {
            return Err(Error::Message(
                "seek is not supported for this media".to_string(),
            ));
        }

        let target_ts = position.as_micros().min(i64::MAX as u128) as i64;
        self.input.seek(target_ts, ..target_ts).map_err(Error::from)?;
        self.decoder.flush();
        self.resampler = build_resampler(
            self.source_format,
            self.source_layout,
            self.source_rate,
            self.target_format,
            self.target_layout,
            self.target_rate,
        )?;
        self.pending_samples.clear();
        self.finished = false;
        Ok(())
    }

    fn push_resampled_frame(&mut self, input: &frame::Audio) -> Result<()> {
        let mut output = frame::Audio::empty();
        self.resampler.run(input, &mut output).map_err(Error::from)?;
        self.push_audio_frame(&output);
        Ok(())
    }

    fn push_audio_frame(&mut self, frame: &frame::Audio) {
        if frame.samples() == 0 || frame.planes() == 0 {
            return;
        }

        let sample_count = frame.samples().saturating_mul(frame.channels() as usize);
        if sample_count == 0 {
            return;
        }

        let samples = unsafe {
            slice::from_raw_parts(frame.data(0).as_ptr() as *const f32, sample_count)
        };
        self.pending_samples.extend(samples.iter().copied());
    }

    fn drain_decoder(&mut self) -> Result<()> {
        let mut decoded = frame::Audio::empty();
        loop {
            match self.decoder.receive_frame(&mut decoded) {
                Ok(()) => {
                    self.push_resampled_frame(&decoded)?;
                }
                Err(error) if is_again(&error) => break,
                Err(ffmpeg::Error::Eof) => break,
                Err(error) => return Err(Error::from(error)),
            }
        }
        Ok(())
    }

    fn drain_resampler(&mut self) -> Result<()> {
        let mut output = frame::Audio::empty();
        loop {
            match self.resampler.flush(&mut output) {
                Ok(Some(_)) => {
                    self.push_audio_frame(&output);
                    output = frame::Audio::empty();
                }
                Ok(None) => break,
                Err(error) => return Err(Error::from(error)),
            }
        }
        Ok(())
    }

    fn refill(&mut self) -> Result<bool> {
        if self.finished {
            return Ok(false);
        }

        while self.pending_samples.len() < 4096 {
            let mut packet = ffmpeg::Packet::empty();
            match packet.read(&mut self.input) {
                Ok(()) => {
                    if packet.stream() != self.stream_index {
                        continue;
                    }

                    self.decoder.send_packet(&packet).map_err(Error::from)?;
                    self.drain_decoder()?;
                }
                Err(error) if is_again(&error) => continue,
                Err(ffmpeg::Error::Eof) => {
                    self.decoder.send_eof().map_err(Error::from)?;
                    self.drain_decoder()?;
                    self.drain_resampler()?;
                    self.finished = true;
                    break;
                }
                Err(error) => return Err(Error::from(error)),
            }
        }

        Ok(!self.pending_samples.is_empty())
    }
}

impl Iterator for AudioSource {
    type Item = f32;

    fn next(&mut self) -> Option<Self::Item> {
        if self.pending_samples.is_empty() {
            let has_more = self.refill().ok()?;
            if !has_more {
                return None;
            }
        }

        self.pending_samples.pop_front()
    }

    fn size_hint(&self) -> (usize, Option<usize>) {
        let len = self.pending_samples.len();
        (len, Some(len))
    }
}
