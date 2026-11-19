use crate::api::simple::reverb::{ReverbAlgorithm, ReverbConfig};
use fundsp::prelude::*;
#[cfg(any(
    target_os = "windows",
    target_os = "linux",
    target_os = "macos",
    target_os = "ios"
))]
use rodio::Source;
use std::sync::{
    atomic::{AtomicU64, Ordering},
    Arc, Mutex,
};
#[cfg(any(
    target_os = "windows",
    target_os = "linux",
    target_os = "macos",
    target_os = "ios"
))]
use std::time::Duration;

pub struct ReverbShared {
    config: Mutex<ReverbConfig>,
    version: AtomicU64,
}

impl ReverbShared {
    pub fn new(config: ReverbConfig) -> Arc<Self> {
        Arc::new(Self {
            config: Mutex::new(config.sanitized()),
            version: AtomicU64::new(1),
        })
    }

    pub fn current_config(&self) -> ReverbConfig {
        self.config
            .lock()
            .map(|guard| guard.clone())
            .unwrap_or_default()
    }

    pub fn set_config(&self, config: ReverbConfig) {
        if let Ok(mut guard) = self.config.lock() {
            *guard = config.sanitized();
            self.version.fetch_add(1, Ordering::Release);
        }
    }

    pub fn version(&self) -> u64 {
        self.version.load(Ordering::Acquire)
    }
}

/// Jezar Freeverb DSP ported from `freeverb-rs` (f32, sample-rate scaled).
mod freeverb_dsp {
    const FIXED_GAIN: f32 = 0.015;
    const SCALE_WET: f32 = 3.0;
    const SCALE_DAMPENING: f32 = 0.4;
    const SCALE_ROOM: f32 = 0.28;
    const OFFSET_ROOM: f32 = 0.7;
    const STEREO_SPREAD: usize = 23;

    const COMB_TUNING_L: [usize; 8] = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617];
    const ALLPASS_TUNING_L: [usize; 4] = [556, 441, 341, 225];

    struct DelayLine {
        buffer: Vec<f32>,
        index: usize,
    }

    impl DelayLine {
        fn new(length: usize) -> Self {
            Self {
                buffer: vec![0.0; length.max(1)],
                index: 0,
            }
        }

        #[inline]
        fn read(&self) -> f32 {
            self.buffer[self.index]
        }

        #[inline]
        fn write_and_advance(&mut self, value: f32) {
            self.buffer[self.index] = if value.abs() < 1.0e-20 { 0.0 } else { value };
            self.index += 1;
            if self.index >= self.buffer.len() {
                self.index = 0;
            }
        }
    }

    struct Comb {
        delay_line: DelayLine,
        feedback: f32,
        filter_state: f32,
        dampening: f32,
        dampening_inverse: f32,
    }

    impl Comb {
        fn new(delay_length: usize) -> Self {
            Self {
                delay_line: DelayLine::new(delay_length),
                feedback: 0.5,
                filter_state: 0.0,
                dampening: 0.5,
                dampening_inverse: 0.5,
            }
        }

        fn set_dampening(&mut self, value: f32) {
            self.dampening = value;
            self.dampening_inverse = 1.0 - value;
        }

        fn set_feedback(&mut self, value: f32) {
            self.feedback = value;
        }

        #[inline]
        fn tick(&mut self, input: f32) -> f32 {
            let output = self.delay_line.read();
            let next_filter =
                output * self.dampening_inverse + self.filter_state * self.dampening;
            self.filter_state = if next_filter.abs() < 1.0e-20 {
                0.0
            } else {
                next_filter
            };
            self.delay_line
                .write_and_advance(input + self.filter_state * self.feedback);
            output
        }
    }

    struct AllPass {
        delay_line: DelayLine,
    }

    impl AllPass {
        fn new(delay_length: usize) -> Self {
            Self {
                delay_line: DelayLine::new(delay_length),
            }
        }

        #[inline]
        fn tick(&mut self, input: f32) -> f32 {
            let delayed = self.delay_line.read();
            let output = -input + delayed;
            self.delay_line.write_and_advance(input + delayed * 0.5);
            output
        }
    }

    pub(super) struct FreeverbDsp {
        combs: Vec<(Comb, Comb)>,
        allpasses: Vec<(AllPass, AllPass)>,
        wet_gains: (f32, f32),
        wet: f32,
        width: f32,
        dry: f32,
        input_gain: f32,
        dampening: f32,
        room_size: f32,
        frozen: bool,
    }

    impl FreeverbDsp {
        pub fn new(sample_rate: u32) -> Self {
            let sr = sample_rate.max(8000);
            let combs = COMB_TUNING_L
                .iter()
                .map(|&len| {
                    (
                        Comb::new(adjust_length(len, sr)),
                        Comb::new(adjust_length(len + STEREO_SPREAD, sr)),
                    )
                })
                .collect();
            let allpasses = ALLPASS_TUNING_L
                .iter()
                .map(|&len| {
                    (
                        AllPass::new(adjust_length(len, sr)),
                        AllPass::new(adjust_length(len + STEREO_SPREAD, sr)),
                    )
                })
                .collect();

            let mut fv = Self {
                combs,
                allpasses,
                wet_gains: (0.0, 0.0),
                wet: 0.0,
                width: 0.75,
                dry: 0.85,
                input_gain: 1.0,
                dampening: 0.4 * SCALE_DAMPENING,
                room_size: 0.9 * SCALE_ROOM + OFFSET_ROOM,
                frozen: false,
            };
            fv.set_wet(0.75);
            fv.set_dry(0.85);
            fv.set_width(0.75);
            fv.set_dampening(0.4);
            fv.set_room_size(0.9);
            fv.set_freeze(false);
            fv
        }

        #[inline]
        pub fn tick(&mut self, left: f32, right: f32) -> (f32, f32) {
            let input_mixed = (left + right) * FIXED_GAIN * self.input_gain;
            let mut out_l = 0.0f32;
            let mut out_r = 0.0f32;

            for (comb_l, comb_r) in self.combs.iter_mut() {
                out_l += comb_l.tick(input_mixed);
                out_r += comb_r.tick(input_mixed);
            }

            for (ap_l, ap_r) in self.allpasses.iter_mut() {
                out_l = ap_l.tick(out_l);
                out_r = ap_r.tick(out_r);
            }

            (
                out_l * self.wet_gains.0 + out_r * self.wet_gains.1 + left * self.dry,
                out_r * self.wet_gains.0 + out_l * self.wet_gains.1 + right * self.dry,
            )
        }

        pub fn set_dampening(&mut self, value: f32) {
            self.dampening = value * SCALE_DAMPENING;
            self.update_combs();
        }

        pub fn set_freeze(&mut self, frozen: bool) {
            self.frozen = frozen;
            self.input_gain = if frozen { 0.0 } else { 1.0 };
            self.update_combs();
        }

        pub fn set_dry(&mut self, value: f32) {
            self.dry = value;
        }

        pub fn set_wet(&mut self, value: f32) {
            self.wet = value * SCALE_WET;
            self.update_wet_gains();
        }

        pub fn set_width(&mut self, value: f32) {
            self.width = value;
            self.update_wet_gains();
        }

        pub fn set_room_size(&mut self, value: f32) {
            self.room_size = value * SCALE_ROOM + OFFSET_ROOM;
            self.update_combs();
        }

        fn update_wet_gains(&mut self) {
            self.wet_gains = (
                self.wet * (self.width * 0.5 + 0.5),
                self.wet * ((1.0 - self.width) * 0.5),
            );
        }

        fn update_combs(&mut self) {
            let (feedback, dampening) = if self.frozen {
                (1.0, 0.0)
            } else {
                (self.room_size, self.dampening)
            };

            for (comb_l, comb_r) in self.combs.iter_mut() {
                comb_l.set_feedback(feedback);
                comb_r.set_feedback(feedback);
                comb_l.set_dampening(dampening);
                comb_r.set_dampening(dampening);
            }
        }
    }

    #[inline]
    fn adjust_length(length: usize, sr: u32) -> usize {
        ((length as f64 * sr as f64 / 44100.0).round() as usize).max(1)
    }
}

pub struct ReverbProcessor {
    shared: Arc<ReverbShared>,
    last_version: u64,
    config: ReverbConfig,
    channels: usize,
    sample_rate: u32,
    fade_weight: f32,
    freeverb: freeverb_dsp::FreeverbDsp,
    fundsp_unit: Option<Box<dyn AudioUnit>>,
    fundsp_built_for: Option<(ReverbAlgorithm, u32, u32, u32, u32)>,
}

impl ReverbProcessor {
    pub fn new(shared: Arc<ReverbShared>, channels: usize, sample_rate: u32) -> Self {
        let config = shared.current_config();
        let last_version = shared.version();
        let safe_sr = std::cmp::max(sample_rate, 8000);
        let safe_ch = std::cmp::max(channels, 1);
        let fade_weight = if config.enabled { 1.0 } else { 0.0 };

        let mut processor = Self {
            shared,
            last_version,
            config,
            channels: safe_ch,
            sample_rate: safe_sr,
            fade_weight,
            freeverb: freeverb_dsp::FreeverbDsp::new(safe_sr),
            fundsp_unit: None,
            fundsp_built_for: None,
        };
        processor.apply_config_to_dsp(true);
        processor
    }

    pub fn set_format(&mut self, channels: usize, sample_rate: u32) {
        let safe_ch = std::cmp::max(channels, 1);
        let safe_sr = std::cmp::max(sample_rate, 8000);
        if self.channels == safe_ch && self.sample_rate == safe_sr {
            return;
        }
        self.channels = safe_ch;
        let sr_changed = self.sample_rate != safe_sr;
        self.sample_rate = safe_sr;
        if sr_changed {
            self.freeverb = freeverb_dsp::FreeverbDsp::new(safe_sr);
            self.fundsp_built_for = None;
        }
        self.apply_config_to_dsp(sr_changed);
    }

    fn sync_config_if_needed(&mut self) {
        let current_version = self.shared.version();
        if current_version != self.last_version {
            self.last_version = current_version;
            self.config = self.shared.current_config();
            self.apply_config_to_dsp(false);
        }
    }

    fn apply_config_to_dsp(&mut self, force_rebuild: bool) {
        self.freeverb.set_dry(self.config.dry_mix);
        self.freeverb.set_wet(self.config.wet_mix);
        self.freeverb.set_room_size(self.config.room_size);
        self.freeverb.set_dampening(self.config.damping);
        self.freeverb.set_width(self.config.width);
        self.freeverb.set_freeze(self.config.freeze);

        match self.config.algorithm {
            ReverbAlgorithm::Freeverb => {
                self.fundsp_unit = None;
                self.fundsp_built_for = None;
            }
            ReverbAlgorithm::FundspStereo | ReverbAlgorithm::FundspHall => {
                let key = (
                    self.config.algorithm,
                    self.sample_rate,
                    (self.config.room_size * 100.0).round() as u32,
                    (self.config.damping * 100.0).round() as u32,
                    (self.config.time_seconds * 20.0).round() as u32,
                );
                if force_rebuild || self.fundsp_built_for != Some(key) || self.fundsp_unit.is_none()
                {
                    let mut unit: Box<dyn AudioUnit> = match self.config.algorithm {
                        ReverbAlgorithm::FundspStereo => {
                            let meters = 10.0 + self.config.room_size as f64 * 22.0;
                            Box::new(reverb_stereo(
                                meters,
                                self.config.time_seconds as f64,
                                self.config.damping as f64,
                            ))
                        }
                        ReverbAlgorithm::FundspHall => {
                            let meters = 15.0 + self.config.room_size as f64 * 25.0;
                            Box::new(reverb4_stereo(meters, self.config.time_seconds as f64))
                        }
                        ReverbAlgorithm::Freeverb => unreachable!(),
                    };
                    unit.set_sample_rate(self.sample_rate as f64);
                    self.fundsp_unit = Some(unit);
                    self.fundsp_built_for = Some(key);
                }
            }
        }
    }

    #[inline]
    pub fn process_stereo_frame(&mut self, left: f32, right: f32) -> (f32, f32) {
        let target_weight = if self.config.enabled { 1.0 } else { 0.0 };
        let step = 1.0 / (std::cmp::max(self.sample_rate, 8000) as f32 * 0.02);
        if (self.fade_weight - target_weight).abs() <= step {
            self.fade_weight = target_weight;
        } else if self.fade_weight < target_weight {
            self.fade_weight += step;
        } else {
            self.fade_weight -= step;
        }

        if self.fade_weight <= 0.0 && !self.config.enabled {
            return (left, right);
        }

        let (wet_l, wet_r) = match self.config.algorithm {
            ReverbAlgorithm::Freeverb => self.freeverb.tick(left, right),
            ReverbAlgorithm::FundspStereo | ReverbAlgorithm::FundspHall => {
                if let Some(unit) = self.fundsp_unit.as_mut() {
                    let mut out = [0.0f32; 2];
                    unit.tick(&[left, right], &mut out);
                    (
                        left * self.config.dry_mix + out[0] * self.config.wet_mix,
                        right * self.config.dry_mix + out[1] * self.config.wet_mix,
                    )
                } else {
                    (left, right)
                }
            }
        };

        let w = self.fade_weight;
        (
            left * (1.0 - w) + wet_l * w,
            right * (1.0 - w) + wet_r * w,
        )
    }

    pub fn process_interleaved(&mut self, samples: &mut [f32], num_frames: usize) {
        self.sync_config_if_needed();

        if self.channels == 0 || num_frames == 0 {
            return;
        }

        if !self.config.enabled && self.fade_weight <= 0.0 {
            return;
        }

        let ch = self.channels;
        for frame_idx in 0..num_frames {
            let base = frame_idx * ch;
            if base + ch > samples.len() {
                break;
            }
            if ch == 1 {
                let s = samples[base];
                let (l, r) = self.process_stereo_frame(s, s);
                samples[base] = (l + r) * 0.5;
            } else {
                let l_in = samples[base];
                let r_in = samples[base + 1];
                let (l_out, r_out) = self.process_stereo_frame(l_in, r_in);
                samples[base] = l_out;
                samples[base + 1] = r_out;
            }
        }
    }
}

#[cfg(any(
    target_os = "windows",
    target_os = "linux",
    target_os = "macos",
    target_os = "ios"
))]
pub struct ReverbSource<I> {
    input: I,
    processor: ReverbProcessor,
    channels: usize,
    pending_samples: Vec<f32>,
    pending_idx: usize,
}

#[cfg(any(
    target_os = "windows",
    target_os = "linux",
    target_os = "macos",
    target_os = "ios"
))]
impl<I> ReverbSource<I>
where
    I: Source<Item = f32>,
{
    pub fn new(input: I, shared: Arc<ReverbShared>) -> Self {
        let channels = input.channels().get() as usize;
        let sample_rate = input.sample_rate().get();
        let processor = ReverbProcessor::new(shared, channels, sample_rate);
        Self {
            input,
            processor,
            channels: std::cmp::max(channels, 1),
            pending_samples: Vec::with_capacity(8),
            pending_idx: 0,
        }
    }
}

#[cfg(any(
    target_os = "windows",
    target_os = "linux",
    target_os = "macos",
    target_os = "ios"
))]
impl<I> Iterator for ReverbSource<I>
where
    I: Source<Item = f32>,
{
    type Item = f32;

    fn next(&mut self) -> Option<Self::Item> {
        if self.pending_idx < self.pending_samples.len() {
            let sample = self.pending_samples[self.pending_idx];
            self.pending_idx += 1;
            return Some(sample);
        }

        self.pending_samples.clear();
        self.pending_idx = 0;

        let ch = self.input.channels().get() as usize;
        let sr = self.input.sample_rate().get();
        if ch != self.channels || sr != self.processor.sample_rate {
            self.channels = std::cmp::max(ch, 1);
            self.processor.set_format(self.channels, sr);
        }

        for _ in 0..self.channels {
            match self.input.next() {
                Some(sample) => self.pending_samples.push(sample),
                None => break,
            }
        }

        if self.pending_samples.is_empty() {
            return None;
        }

        if self.pending_samples.len() == self.channels {
            self.processor
                .process_interleaved(&mut self.pending_samples, 1);
        }

        let first = self.pending_samples[0];
        self.pending_idx = 1;
        Some(first)
    }
}

#[cfg(any(
    target_os = "windows",
    target_os = "linux",
    target_os = "macos",
    target_os = "ios"
))]
impl<I> Source for ReverbSource<I>
where
    I: Source<Item = f32>,
{
    fn current_span_len(&self) -> Option<usize> {
        self.input.current_span_len()
    }

    fn channels(&self) -> rodio::ChannelCount {
        self.input.channels()
    }

    fn sample_rate(&self) -> rodio::SampleRate {
        self.input.sample_rate()
    }

    fn total_duration(&self) -> Option<Duration> {
        self.input.total_duration()
    }
}

#[cfg(target_os = "android")]
pub mod android_jni {
    use super::*;
    use jni::objects::{JByteBuffer, JClass};
    use jni::sys::{jboolean, jfloat, jint, jlong};
    use jni::JNIEnv;

    pub struct AndroidReverb {
        pub shared: Arc<ReverbShared>,
        pub processor: ReverbProcessor,
    }

    #[no_mangle]
    pub unsafe extern "system" fn Java_com_flutter_1rust_1bridge_audio_1core_RustReverbProcessor_nativeCreate(
        _env: JNIEnv,
        _class: JClass,
    ) -> jlong {
        let config = ReverbConfig::default();
        let shared = ReverbShared::new(config);
        let processor = ReverbProcessor::new(Arc::clone(&shared), 2, 44100);
        let boxed = Box::new(AndroidReverb { shared, processor });
        Box::into_raw(boxed) as jlong
    }

    #[no_mangle]
    pub unsafe extern "system" fn Java_com_flutter_1rust_1bridge_audio_1core_RustReverbProcessor_nativeDestroy(
        _env: JNIEnv,
        _class: JClass,
        handle: jlong,
    ) {
        if handle != 0 {
            drop(Box::from_raw(handle as *mut AndroidReverb));
        }
    }

    #[no_mangle]
    pub unsafe extern "system" fn Java_com_flutter_1rust_1bridge_audio_1core_RustReverbProcessor_nativeInit(
        _env: JNIEnv,
        _class: JClass,
        handle: jlong,
        sample_rate: jfloat,
        channels: jint,
    ) {
        if handle != 0 {
            let reverb = &mut *(handle as *mut AndroidReverb);
            let safe_channels = if channels > 1 { channels as usize } else { 1 };
            let safe_sr = if sample_rate > 1.0 {
                sample_rate as u32
            } else {
                44100
            };
            reverb.processor.set_format(safe_channels, safe_sr);
        }
    }

    #[no_mangle]
    pub unsafe extern "system" fn Java_com_flutter_1rust_1bridge_audio_1core_RustReverbProcessor_nativeProcess(
        env: JNIEnv,
        _class: JClass,
        handle: jlong,
        buffer: JByteBuffer,
        num_frames: jint,
        channels: jint,
    ) {
        if handle == 0 || num_frames <= 0 || channels <= 0 {
            return;
        }
        let reverb = &mut *(handle as *mut AndroidReverb);
        if let Ok(addr) = env.get_direct_buffer_address(&buffer) {
            if !addr.is_null() {
                let total_samples = (num_frames as usize) * (channels as usize);
                if let Ok(capacity) = env.get_direct_buffer_capacity(&buffer) {
                    if capacity < total_samples * std::mem::size_of::<f32>() {
                        return;
                    }
                }
                let slice = std::slice::from_raw_parts_mut(addr as *mut f32, total_samples);
                reverb.processor.process_interleaved(slice, num_frames as usize);
            }
        }
    }

    #[no_mangle]
    pub unsafe extern "system" fn Java_com_flutter_1rust_1bridge_audio_1core_RustReverbProcessor_nativeSetConfig(
        _env: JNIEnv,
        _class: JClass,
        handle: jlong,
        enabled: jboolean,
        algorithm: jint,
        dry_mix: jfloat,
        wet_mix: jfloat,
        room_size: jfloat,
        damping: jfloat,
        width: jfloat,
        time_seconds: jfloat,
        freeze: jboolean,
    ) {
        if handle == 0 {
            return;
        }
        let reverb = &*(handle as *mut AndroidReverb);
        reverb.shared.set_config(ReverbConfig {
            enabled: enabled != 0,
            algorithm: ReverbAlgorithm::from_i32(algorithm),
            dry_mix,
            wet_mix,
            room_size,
            damping,
            width,
            time_seconds,
            freeze: freeze != 0,
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_freeverb_and_fundsp_reverb_produce_tail() {
        for algo in [
            ReverbAlgorithm::Freeverb,
            ReverbAlgorithm::FundspStereo,
            ReverbAlgorithm::FundspHall,
        ] {
            let config = ReverbConfig {
                enabled: true,
                algorithm: algo,
                ..Default::default()
            };
            let shared = ReverbShared::new(config);
            let mut proc = ReverbProcessor::new(shared, 2, 44100);

            let frames = 16384;
            let mut buf = vec![0.0f32; frames * 2];
            buf[0] = 1.0;
            buf[1] = 1.0;
            proc.process_interleaved(&mut buf, frames);

            let tail_energy: f32 = buf[2000..].iter().map(|s| s * s).sum();
            assert!(
                tail_energy > 1.0e-6,
                "Expected non-zero reverb tail for {:?}, got {}",
                algo,
                tail_energy
            );
        }
    }
}
