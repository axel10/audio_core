use std::collections::VecDeque;
use std::time::Duration;
use log::{debug, info, warn};
use rodio::source::SeekError;
use rodio::{ChannelCount, SampleRate, Source};
use rubato::audioadapter_buffers::direct::InterleavedSlice;
use rubato::{
    Async, Fft, FixedAsync, FixedSync, Indexing, Resampler, SincInterpolationParameters,
    SincInterpolationType, WindowFunction,
};

/// Downmixes or upmixes channels to `target_channels` using high-fidelity coefficients.
pub struct ChannelConverterSource<S> {
    inner: S,
    from_channels: usize,
    target_channels: ChannelCount,
    frame_in: Vec<f32>,
    out_queue: VecDeque<f32>,
}

impl<S> ChannelConverterSource<S>
where
    S: Source<Item = f32>,
{
    pub fn new(inner: S, target_channels: ChannelCount) -> Self {
        let from_channels = inner.channels().get() as usize;
        Self {
            inner,
            from_channels,
            target_channels,
            frame_in: Vec::with_capacity(from_channels),
            out_queue: VecDeque::with_capacity(target_channels.get() as usize * 16),
        }
    }
}

impl<S> Iterator for ChannelConverterSource<S>
where
    S: Source<Item = f32>,
{
    type Item = f32;

    fn next(&mut self) -> Option<Self::Item> {
        if let Some(s) = self.out_queue.pop_front() {
            return Some(s);
        }

        self.frame_in.clear();
        for _ in 0..self.from_channels {
            if let Some(s) = self.inner.next() {
                self.frame_in.push(s);
            } else {
                return None;
            }
        }

        let to_ch = self.target_channels.get() as usize;
        match (self.from_channels, to_ch) {
            (from, to) if from == to => {
                for &s in &self.frame_in {
                    self.out_queue.push_back(s);
                }
            }
            // Mono -> Stereo
            (1, 2) => {
                let m = self.frame_in[0];
                self.out_queue.push_back(m);
                self.out_queue.push_back(m);
            }
            // Stereo -> Mono
            (2, 1) => {
                let m = (self.frame_in[0] + self.frame_in[1]) * 0.5;
                self.out_queue.push_back(m);
            }
            // 5.1 Surround -> Stereo (ITU-R BS.775 standard matrix downmix with headroom normalization)
            // Order: [FL, FR, FC, LFE, SL, SR]
            (6, 2) => {
                let fl = self.frame_in[0];
                let fr = self.frame_in[1];
                let fc = self.frame_in[2];
                let sl = self.frame_in[4];
                let sr = self.frame_in[5];
                // 0.7071 (-3dB center/surround contribution)
                // Normalize factor 1 / (1 + 0.7071 + 0.7071) approx 0.4142
                let norm = 0.4142_f32;
                let left = (fl + 0.7071 * fc + 0.7071 * sl) * norm;
                let right = (fr + 0.7071 * fc + 0.7071 * sr) * norm;
                self.out_queue.push_back(left);
                self.out_queue.push_back(right);
            }
            // 7.1 Surround -> Stereo
            // Order: [FL, FR, FC, LFE, BL, BR, SL, SR]
            (8, 2) => {
                let fl = self.frame_in[0];
                let fr = self.frame_in[1];
                let fc = self.frame_in[2];
                let bl = self.frame_in[4];
                let br = self.frame_in[5];
                let sl = self.frame_in[6];
                let sr = self.frame_in[7];
                let norm = 0.3204_f32; // 1 / (1 + 0.7071 * 3)
                let left = (fl + 0.7071 * fc + 0.7071 * sl + 0.7071 * bl) * norm;
                let right = (fr + 0.7071 * fc + 0.7071 * sr + 0.7071 * br) * norm;
                self.out_queue.push_back(left);
                self.out_queue.push_back(right);
            }
            // Generic downmix to stereo
            (from, 2) => {
                let mut sum_l = self.frame_in[0];
                let mut sum_r = self.frame_in.get(1).copied().unwrap_or(0.0);
                for (i, &s) in self.frame_in.iter().enumerate().skip(2) {
                    if i % 2 == 0 {
                        sum_l += s * 0.5;
                    } else {
                        sum_r += s * 0.5;
                    }
                }
                let norm = 1.0 / (1.0 + (from.saturating_sub(2) as f32 * 0.25)).max(1.0);
                self.out_queue.push_back(sum_l * norm);
                self.out_queue.push_back(sum_r * norm);
            }
            // Generic downmix to mono
            (from, 1) => {
                let sum: f32 = self.frame_in.iter().sum();
                self.out_queue.push_back(sum / (from as f32));
            }
            // Generic upmix or other mapping
            (_from, to) => {
                for i in 0..to {
                    let s = self.frame_in.get(i).copied().unwrap_or(0.0);
                    self.out_queue.push_back(s);
                }
            }
        }

        self.out_queue.pop_front()
    }
}

impl<S> Source for ChannelConverterSource<S>
where
    S: Source<Item = f32>,
{
    fn current_span_len(&self) -> Option<usize> {
        None
    }

    fn channels(&self) -> ChannelCount {
        self.target_channels
    }

    fn sample_rate(&self) -> SampleRate {
        self.inner.sample_rate()
    }

    fn total_duration(&self) -> Option<Duration> {
        self.inner.total_duration()
    }

    fn try_seek(&mut self, pos: Duration) -> Result<(), SeekError> {
        self.out_queue.clear();
        self.frame_in.clear();
        self.inner.try_seek(pos)
    }
}

/// High-quality Rubato audio resampler wrapping rodio::Source.
pub struct RubatoSource<S> {
    inner: S,
    resampler: Box<dyn Resampler<f32>>,
    channels: ChannelCount,
    source_sample_rate: usize,
    target_sample_rate: SampleRate,
    out_queue: VecDeque<f32>,
    in_chunk_buf: Vec<f32>,
    out_chunk_buf: Vec<f32>,
    exhausted: bool,
}

impl<S> RubatoSource<S>
where
    S: Source<Item = f32>,
{
    pub fn new(
        inner: S,
        target_sample_rate: SampleRate,
    ) -> Result<Self, String> {
        let from_rate = inner.sample_rate().get() as usize;
        let to_rate = target_sample_rate.get() as usize;
        let channels = inner.channels();
        let ch = channels.get() as usize;

        let resampler = Self::create_resampler(from_rate, to_rate, ch)?;
        Ok(Self::with_resampler(inner, target_sample_rate, resampler))
    }

    pub fn with_resampler(
        inner: S,
        target_sample_rate: SampleRate,
        resampler: Box<dyn Resampler<f32>>,
    ) -> Self {
        let from_rate = inner.sample_rate().get() as usize;
        let channels = inner.channels();
        let ch = channels.get() as usize;

        info!(
            "[RubatoSource] Initialized resampler from_rate={} to_rate={} channels={}",
            from_rate, target_sample_rate.get(), ch
        );

        Self {
            inner,
            resampler,
            channels,
            source_sample_rate: from_rate,
            target_sample_rate,
            out_queue: VecDeque::with_capacity(2048 * ch),
            in_chunk_buf: Vec::new(),
            out_chunk_buf: Vec::new(),
            exhausted: false,
        }
    }

    pub fn create_resampler(
        from_rate: usize,
        to_rate: usize,
        channels: usize,
    ) -> Result<Box<dyn Resampler<f32>>, String> {
        // Try FFT synchronous resampler first (highest performance, zero aliasing, pristine SNR)
        match Fft::<f32>::new(from_rate, to_rate, 1024, channels, FixedSync::Both) {
            Ok(fft) => {
                debug!("[RubatoSource] Using FFT synchronous resampler");
                Ok(Box::new(fft))
            }
            Err(e) => {
                warn!(
                    "[RubatoSource] Fft resampler unavailable ({:?}), falling back to Sinc resampler",
                    e
                );
                let params = SincInterpolationParameters {
                    sinc_len: 256,
                    f_cutoff: None,
                    oversampling_factor: 128,
                    interpolation: SincInterpolationType::Cubic,
                    window: WindowFunction::BlackmanHarris2,
                };
                let ratio = to_rate as f64 / from_rate as f64;
                Async::<f32>::new_sinc(ratio, 1.0, &params, 1024, channels, FixedAsync::Input)
                    .map(|sinc| Box::new(sinc) as Box<dyn Resampler<f32>>)
                    .map_err(|err| format!("Failed to create Sinc resampler: {:?}", err))
            }
        }
    }

    fn process_next_chunk(&mut self) -> bool {
        if self.exhausted {
            return false;
        }

        let needed_in_frames = self.resampler.input_frames_next();
        let ch = self.channels.get() as usize;
        let needed_in_samples = needed_in_frames * ch;

        self.in_chunk_buf.clear();
        let mut samples_read = 0;
        while samples_read < needed_in_samples {
            if let Some(s) = self.inner.next() {
                self.in_chunk_buf.push(s);
                samples_read += 1;
            } else {
                break;
            }
        }

        if samples_read == 0 {
            self.exhausted = true;
            return false;
        }

        let frames_read = samples_read / ch;
        let needed_out_frames = self.resampler.output_frames_next();
        self.out_chunk_buf.resize(needed_out_frames * ch, 0.0);

        if frames_read < needed_in_frames {
            // End of stream partial chunk: pad remaining with silence
            self.exhausted = true;
            self.in_chunk_buf.resize(needed_in_samples, 0.0);

            let input_adapter = match InterleavedSlice::new(&self.in_chunk_buf, ch, needed_in_frames) {
                Ok(a) => a,
                Err(e) => {
                    warn!("[RubatoSource] input_adapter error: {:?}", e);
                    return false;
                }
            };
            let mut output_adapter = match InterleavedSlice::new_mut(&mut self.out_chunk_buf, ch, needed_out_frames) {
                Ok(a) => a,
                Err(e) => {
                    warn!("[RubatoSource] output_adapter error: {:?}", e);
                    return false;
                }
            };

            let mut indexing = Indexing::new();
            indexing.partial_len = Some(frames_read);

            match self.resampler.process_into_buffer(&input_adapter, &mut output_adapter, Some(&indexing)) {
                Ok((_nbr_in, nbr_out)) => {
                    let valid_out_frames = ((frames_read as f64)
                        * (self.target_sample_rate.get() as f64)
                        / (self.source_sample_rate as f64))
                        .round() as usize;
                    let frames_to_take = valid_out_frames.min(nbr_out);
                    for &s in &self.out_chunk_buf[..frames_to_take * ch] {
                        self.out_queue.push_back(s);
                    }
                    !self.out_queue.is_empty()
                }
                Err(e) => {
                    warn!("[RubatoSource] Resampling partial error: {:?}", e);
                    false
                }
            }
        } else {
            // Full chunk
            let input_adapter = match InterleavedSlice::new(&self.in_chunk_buf, ch, needed_in_frames) {
                Ok(a) => a,
                Err(e) => {
                    warn!("[RubatoSource] input_adapter error: {:?}", e);
                    return false;
                }
            };
            let mut output_adapter = match InterleavedSlice::new_mut(&mut self.out_chunk_buf, ch, needed_out_frames) {
                Ok(a) => a,
                Err(e) => {
                    warn!("[RubatoSource] output_adapter error: {:?}", e);
                    return false;
                }
            };

            match self.resampler.process_into_buffer(&input_adapter, &mut output_adapter, None) {
                Ok((_nbr_in, nbr_out)) => {
                    for &s in &self.out_chunk_buf[..nbr_out * ch] {
                        self.out_queue.push_back(s);
                    }
                    true
                }
                Err(e) => {
                    warn!("[RubatoSource] Resampling error: {:?}", e);
                    false
                }
            }
        }
    }
}

impl<S> Iterator for RubatoSource<S>
where
    S: Source<Item = f32>,
{
    type Item = f32;

    fn next(&mut self) -> Option<Self::Item> {
        loop {
            if let Some(s) = self.out_queue.pop_front() {
                return Some(s);
            }
            if !self.process_next_chunk() {
                return None;
            }
        }
    }
}

impl<S> Source for RubatoSource<S>
where
    S: Source<Item = f32>,
{
    fn current_span_len(&self) -> Option<usize> {
        if self.exhausted && self.out_queue.is_empty() {
            Some(0)
        } else {
            None
        }
    }

    fn channels(&self) -> ChannelCount {
        self.channels
    }

    fn sample_rate(&self) -> SampleRate {
        self.target_sample_rate
    }

    fn total_duration(&self) -> Option<Duration> {
        self.inner.total_duration()
    }

    fn try_seek(&mut self, pos: Duration) -> Result<(), SeekError> {
        self.out_queue.clear();
        self.in_chunk_buf.clear();
        self.exhausted = false;
        let _ = self.resampler.reset();
        self.inner.try_seek(pos)
    }
}

/// Helper function to normalize audio source to `target_channels` and `target_sample_rate`
/// using high-fidelity downmix and Rubato resampling.
pub fn normalize_audio_source(
    source: Box<dyn Source<Item = f32> + Send>,
    target_channels: ChannelCount,
    target_sample_rate: SampleRate,
) -> Box<dyn Source<Item = f32> + Send> {
    let from_channels = source.channels();
    let from_sample_rate = source.sample_rate();

    if from_channels == target_channels && from_sample_rate == target_sample_rate {
        return source;
    }

    // Step 1: Channel normalization (if needed)
    let channel_normalized: Box<dyn Source<Item = f32> + Send> = if from_channels != target_channels {
        Box::new(ChannelConverterSource::new(source, target_channels))
    } else {
        source
    };

    // Step 2: Sample rate conversion with Rubato (if needed)
    if from_sample_rate != target_sample_rate {
        let from_rate = from_sample_rate.get() as usize;
        let to_rate = target_sample_rate.get() as usize;
        let ch = target_channels.get() as usize;
        match RubatoSource::<Box<dyn Source<Item = f32> + Send>>::create_resampler(from_rate, to_rate, ch) {
            Ok(resampler) => Box::new(RubatoSource::with_resampler(
                channel_normalized,
                target_sample_rate,
                resampler,
            )),
            Err(e) => {
                warn!(
                    "[normalize_audio_source] Failed to initialize Rubato ({}), falling back to rodio UniformSourceIterator",
                    e
                );
                Box::new(rodio::source::UniformSourceIterator::new(
                    channel_normalized,
                    target_channels,
                    target_sample_rate,
                ))
            }
        }
    } else {
        channel_normalized
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rodio::buffer::SamplesBuffer;
    use std::num::NonZero;

    #[test]
    fn test_channel_converter_mono_to_stereo() {
        let data = vec![0.1, 0.2, 0.3];
        let buffer = SamplesBuffer::new(NonZero::new(1).unwrap(), NonZero::new(44100).unwrap(), data);
        let mut converter = ChannelConverterSource::new(buffer, NonZero::new(2).unwrap());

        let mut out = Vec::new();
        while let Some(s) = converter.next() {
            out.push(s);
        }
        assert_eq!(out, vec![0.1, 0.1, 0.2, 0.2, 0.3, 0.3]);
    }

    #[test]
    fn test_channel_converter_stereo_to_mono() {
        let data = vec![0.2, 0.4, 0.6, 0.8];
        let buffer = SamplesBuffer::new(NonZero::new(2).unwrap(), NonZero::new(44100).unwrap(), data);
        let mut converter = ChannelConverterSource::new(buffer, NonZero::new(1).unwrap());

        let mut out = Vec::new();
        while let Some(s) = converter.next() {
            out.push(s);
        }
        assert_eq!(out.len(), 2);
        assert!((out[0] - 0.3).abs() < 1e-6);
        assert!((out[1] - 0.7).abs() < 1e-6);
    }

    #[test]
    fn test_channel_converter_5_1_to_stereo() {
        // [FL, FR, FC, LFE, SL, SR]
        let data = vec![1.0, 1.0, 0.0, 0.0, 0.0, 0.0];
        let buffer = SamplesBuffer::new(NonZero::new(6).unwrap(), NonZero::new(44100).unwrap(), data);
        let mut converter = ChannelConverterSource::new(buffer, NonZero::new(2).unwrap());

        let mut out = Vec::new();
        while let Some(s) = converter.next() {
            out.push(s);
        }
        assert_eq!(out.len(), 2);
        // Expect symmetrical non-clipping downmix
        assert!((out[0] - out[1]).abs() < 1e-6);
        assert!(out[0] <= 1.0);
    }

    #[test]
    fn test_rubato_resampler_upsample_44100_to_48000() {
        // 1 second of stereo 440Hz sine wave at 44100Hz
        let in_rate = 44100;
        let out_rate = 48000;
        let num_frames = 44100;
        let mut data = Vec::with_capacity(num_frames * 2);
        for i in 0..num_frames {
            let t = i as f32 / in_rate as f32;
            let val = (t * 440.0 * 2.0 * std::f32::consts::PI).sin();
            data.push(val);
            data.push(val);
        }

        let buffer = SamplesBuffer::new(NonZero::new(2).unwrap(), NonZero::new(in_rate as u32).unwrap(), data);
        let mut resampled = RubatoSource::new(buffer, NonZero::new(out_rate as u32).unwrap()).unwrap();

        let mut out = Vec::new();
        while let Some(s) = resampled.next() {
            out.push(s);
        }

        // Expected output frames: roughly 48000 frames (96000 samples)
        let out_frames = out.len() / 2;
        let expected_frames = 48000;
        let diff = (out_frames as isize - expected_frames as isize).abs();
        assert!(diff <= 128, "Expected ~{} frames, got {} (diff {})", expected_frames, out_frames, diff);

        // Verify output is not all zeros
        let max_val = out.iter().map(|x| x.abs()).fold(0.0_f32, f32::max);
        assert!(max_val > 0.8, "Max value should be preserved close to 1.0, got {}", max_val);
    }

    #[test]
    fn test_rubato_resampler_downsample_96000_to_48000() {
        let in_rate = 96000;
        let out_rate = 48000;
        let num_frames = 9600; // 0.1 second
        let mut data = Vec::with_capacity(num_frames * 2);
        for i in 0..num_frames {
            let t = i as f32 / in_rate as f32;
            let val = (t * 1000.0 * 2.0 * std::f32::consts::PI).sin();
            data.push(val);
            data.push(val);
        }

        let buffer = SamplesBuffer::new(NonZero::new(2).unwrap(), NonZero::new(in_rate as u32).unwrap(), data);
        let mut resampled = RubatoSource::new(buffer, NonZero::new(out_rate as u32).unwrap()).unwrap();

        let mut out = Vec::new();
        while let Some(s) = resampled.next() {
            out.push(s);
        }

        let out_frames = out.len() / 2;
        let expected_frames = 4800;
        let diff = (out_frames as isize - expected_frames as isize).abs();
        assert!(diff <= 64, "Expected ~{} frames, got {} (diff {})", expected_frames, out_frames, diff);
    }
}

