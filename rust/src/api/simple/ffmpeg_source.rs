use std::num::NonZero;
use std::path::Path;
use std::time::Duration;

use ffmpeg_core::AudioSource as CoreAudioSource;
use rodio::{Sample, Source};

pub struct FfmpegAudioSource {
    inner: CoreAudioSource,
}

impl FfmpegAudioSource {
    pub fn open(path: impl AsRef<Path>) -> Result<Self, String> {
        CoreAudioSource::open(path)
            .map(|inner| Self { inner })
            .map_err(|error| error.to_string())
    }

    pub fn seek_to(&mut self, position: Duration) -> Result<(), String> {
        self.inner
            .seek_to(position)
            .map_err(|error| error.to_string())
    }

    pub fn total_duration(&self) -> Option<Duration> {
        self.inner.total_duration()
    }
}

impl Iterator for FfmpegAudioSource {
    type Item = Sample;

    fn next(&mut self) -> Option<Self::Item> {
        self.inner.next()
    }

    fn size_hint(&self) -> (usize, Option<usize>) {
        self.inner.size_hint()
    }
}

impl Source for FfmpegAudioSource {
    fn current_span_len(&self) -> Option<usize> {
        self.inner.current_span_len()
    }

    fn channels(&self) -> rodio::ChannelCount {
        NonZero::new(self.inner.channels()).expect("ffmpeg source channels must be non-zero")
    }

    fn sample_rate(&self) -> rodio::SampleRate {
        NonZero::new(self.inner.sample_rate()).expect("ffmpeg source sample rate must be non-zero")
    }

    fn total_duration(&self) -> Option<Duration> {
        self.inner.total_duration()
    }

    fn try_seek(&mut self, pos: Duration) -> Result<(), rodio::source::SeekError> {
        self.inner.seek_to(pos).map_err(|error| {
            rodio::source::SeekError::Other(std::sync::Arc::new(std::io::Error::other(error)))
        })
    }
}
