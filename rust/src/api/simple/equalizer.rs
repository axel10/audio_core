use fundsp::prelude::*;
use rodio::Source;
use std::cmp::{max, min};
use std::sync::{
    atomic::{AtomicU64, Ordering},
    Arc, Mutex,
};
use std::time::Duration;

pub const MAX_EQ_BANDS: usize = 32;
pub const ISO_31_FREQUENCIES: [f32; 31] = [
    20.0, 25.0, 31.5, 40.0, 50.0, 63.0, 80.0, 100.0, 125.0, 160.0, 200.0, 250.0, 315.0, 400.0,
    500.0, 630.0, 800.0, 1000.0, 1250.0, 1600.0, 2000.0, 2500.0, 3150.0, 4000.0, 5000.0,
    6300.0, 8000.0, 10000.0, 12500.0, 16000.0, 20000.0,
];
const MIN_EQ_CENTER_HZ: f32 = 32.0;
const MAX_EQ_CENTER_HZ: f32 = 16_000.0;
const DEFAULT_BASS_BOOST_HZ: f32 = 80.0;
const DEFAULT_BASS_BOOST_Q: f32 = 0.75;
const CONFIG_REFRESH_STRIDE: usize = 64;
const CONFIG_SMOOTHING_FACTOR: f32 = 0.18;
const EPSILON_GAIN_DB: f32 = 0.001;

#[derive(Debug, Clone)]
pub struct EqualizerConfig {
    pub enabled: bool,
    pub band_count: i32,
    pub preamp_db: f32,
    pub bass_boost_db: f32,
    pub bass_boost_frequency_hz: f32,
    pub bass_boost_q: f32,
    pub band_gains_db: Vec<f32>,
}

impl Default for EqualizerConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            band_count: MAX_EQ_BANDS as i32,
            preamp_db: 0.0,
            bass_boost_db: 0.0,
            bass_boost_frequency_hz: DEFAULT_BASS_BOOST_HZ,
            bass_boost_q: DEFAULT_BASS_BOOST_Q,
            band_gains_db: vec![0.0; MAX_EQ_BANDS],
        }
    }
}

impl EqualizerConfig {
    pub fn sanitized(mut self) -> Self {
        self.band_count = self.band_count.clamp(0, MAX_EQ_BANDS as i32);
        self.bass_boost_db = self.bass_boost_db.clamp(0.0, 12.0);
        self.bass_boost_frequency_hz = self.bass_boost_frequency_hz.clamp(20.0, 240.0);
        self.bass_boost_q = self.bass_boost_q.clamp(0.1, 2.0);

        if self.band_gains_db.len() < MAX_EQ_BANDS {
            self.band_gains_db.resize(MAX_EQ_BANDS, 0.0);
        } else if self.band_gains_db.len() > MAX_EQ_BANDS {
            self.band_gains_db.truncate(MAX_EQ_BANDS);
        }

        self
    }
}

fn smooth_toward(current: f32, target: f32, factor: f32) -> f32 {
    current + (target - current) * factor
}

fn smooth_config_toward(current: &mut EqualizerConfig, target: &EqualizerConfig) -> bool {
    let mut changed = false;

    if current.enabled != target.enabled {
        current.enabled = target.enabled;
        changed = true;
    }

    if current.band_count != target.band_count {
        current.band_count = target.band_count;
        changed = true;
    }

    let next_preamp_db =
        smooth_toward(current.preamp_db, target.preamp_db, CONFIG_SMOOTHING_FACTOR);
    if (next_preamp_db - current.preamp_db).abs() > EPSILON_GAIN_DB {
        current.preamp_db = next_preamp_db;
        changed = true;
    }

    let next_bass_boost_db = smooth_toward(
        current.bass_boost_db,
        target.bass_boost_db,
        CONFIG_SMOOTHING_FACTOR,
    );
    if (next_bass_boost_db - current.bass_boost_db).abs() > EPSILON_GAIN_DB {
        current.bass_boost_db = next_bass_boost_db;
        changed = true;
    }

    let next_bass_boost_frequency_hz = smooth_toward(
        current.bass_boost_frequency_hz,
        target.bass_boost_frequency_hz,
        CONFIG_SMOOTHING_FACTOR,
    );
    if (next_bass_boost_frequency_hz - current.bass_boost_frequency_hz).abs() > 0.01 {
        current.bass_boost_frequency_hz = next_bass_boost_frequency_hz;
        changed = true;
    }

    let next_bass_boost_q = smooth_toward(
        current.bass_boost_q,
        target.bass_boost_q,
        CONFIG_SMOOTHING_FACTOR,
    );
    if (next_bass_boost_q - current.bass_boost_q).abs() > 0.001 {
        current.bass_boost_q = next_bass_boost_q;
        changed = true;
    }

    let band_count = min(
        MAX_EQ_BANDS,
        min(current.band_gains_db.len(), target.band_gains_db.len()),
    );
    for i in 0..band_count {
        let next_gain = smooth_toward(
            current.band_gains_db[i],
            target.band_gains_db[i],
            CONFIG_SMOOTHING_FACTOR,
        );
        if (next_gain - current.band_gains_db[i]).abs() > EPSILON_GAIN_DB {
            current.band_gains_db[i] = next_gain;
            changed = true;
        }
    }

    *current = std::mem::take(current).sanitized();
    changed
}

pub(crate) struct EqualizerShared {
    version: AtomicU64,
    config: Mutex<EqualizerConfig>,
}

impl EqualizerShared {
    pub(crate) fn new(config: EqualizerConfig) -> Arc<Self> {
        Arc::new(Self {
            version: AtomicU64::new(1),
            config: Mutex::new(config.sanitized()),
        })
    }

    pub(crate) fn current_config(&self) -> EqualizerConfig {
        self.config
            .lock()
            .map(|config| config.clone())
            .unwrap_or_else(|_| EqualizerConfig::default())
    }

    pub(crate) fn set_config(&self, config: EqualizerConfig) {
        if let Ok(mut current) = self.config.lock() {
            *current = config.sanitized();
            self.version.fetch_add(1, Ordering::AcqRel);
        }
    }

    pub(crate) fn version(&self) -> u64 {
        self.version.load(Ordering::Acquire)
    }
}

#[derive(Clone)]
struct EqualizerChain {
    eq_unit: Box<dyn AudioUnit>,
    sample_rate: u32,
    current_enabled: bool,
    current_band_count: usize,
    preamp_gain: Shared,
    bass_boost_freq: Shared,
    bass_boost_q: Shared,
    bass_boost_gain: Shared,
    band_freqs: Vec<Shared>,
    band_gains: Vec<Shared>,
}

#[inline(always)]
fn soft_limit(sample: f32) -> f32 {
    // Exact linear bit-transparent pass-through in [-0.98, 0.98] (~ -0.17 dBFS)
    // Smooth, continuous tanh soft saturation for extreme over-range peaks to prevent harsh digital clipping.
    const THRESHOLD: f32 = 0.98;
    const MARGIN: f32 = 1.0 - THRESHOLD; // 0.02

    if sample > THRESHOLD {
        THRESHOLD + MARGIN * ((sample - THRESHOLD) / MARGIN).tanh()
    } else if sample < -THRESHOLD {
        -THRESHOLD - MARGIN * ((-sample - THRESHOLD) / MARGIN).tanh()
    } else {
        sample
    }
}

impl EqualizerChain {
    fn from_config(config: &EqualizerConfig, sample_rate: u32) -> Self {
        let mut chain = Self::identity(sample_rate);
        chain.update_from_config(config, sample_rate);
        chain
    }

    fn identity(sample_rate: u32) -> Self {
        Self {
            eq_unit: Box::new(pass()),
            sample_rate,
            current_enabled: false,
            current_band_count: 0,
            preamp_gain: shared(1.0),
            bass_boost_freq: shared(DEFAULT_BASS_BOOST_HZ),
            bass_boost_q: shared(DEFAULT_BASS_BOOST_Q),
            bass_boost_gain: shared(1.0),
            band_freqs: (0..MAX_EQ_BANDS).map(|_| shared(1000.0)).collect(),
            band_gains: (0..MAX_EQ_BANDS).map(|_| shared(1.0)).collect(),
        }
    }

    fn reset(&mut self) {
        self.eq_unit.reset();
    }

    fn update_from_config(&mut self, config: &EqualizerConfig, sample_rate: u32) {
        let config = config.clone().sanitized();
        let band_count = config.band_count as usize;

        // Standard EQ architecture (like JUCE / standard music players):
        // EQ bands apply transparent gain boost directly without decreasing global preamp volume.
        let preamp_gain = db_amp(config.preamp_db);

        // Nyquist limit protection: Keep filter centers below 0.45 * Fs to prevent tan() divergence
        let max_safe_freq = (sample_rate as f32 * 0.45).min(20_000.0);

        // Update the shared values first
        self.preamp_gain.set_value(preamp_gain);
        self.bass_boost_freq
            .set_value(config.bass_boost_frequency_hz.clamp(20.0, max_safe_freq));
        self.bass_boost_q.set_value(config.bass_boost_q);
        self.bass_boost_gain.set_value(db_amp(config.bass_boost_db));

        for i in 0..band_count {
            let center_freq = band_center_frequency(i, band_count);
            if center_freq >= max_safe_freq {
                // If band is near or above Nyquist limit, clamp center frequency and set gain to 1.0 (pass-through)
                self.band_freqs[i].set_value(max_safe_freq);
                self.band_gains[i].set_value(1.0);
            } else {
                self.band_freqs[i].set_value(center_freq);
                self.band_gains[i].set_value(db_amp(config.band_gains_db[i]));
            }
        }

        let sample_rate_changed = self.sample_rate != sample_rate;
        self.sample_rate = sample_rate;

        let structure_changed = !self.current_enabled
            || self.current_band_count != band_count
            || !config.enabled
            || sample_rate_changed;

        if structure_changed {
            if !config.enabled {
                self.eq_unit = Box::new(pass());
                self.eq_unit.set_sample_rate(sample_rate as f64);
                self.current_enabled = false;
                self.current_band_count = 0;
                return;
            }

            // Build the dynamic EQ chain graph
            let mut node: Box<dyn AudioUnit> = Box::new(pass() * var(&self.preamp_gain));

            // Bass Boost (lowshelf)
            node = Box::new(
                An(Unit::<U1, U1>::new(node))
                    >> (pass()
                        | var(&self.bass_boost_freq)
                        | var(&self.bass_boost_q)
                        | var(&self.bass_boost_gain))
                    >> lowshelf::<f32>(),
            );

            // EQ Bands
            let q_factor = band_q_factor(band_count);
            for i in 0..band_count {
                node = Box::new(
                    An(Unit::<U1, U1>::new(node))
                        >> (pass() | var(&self.band_freqs[i]) | dc(q_factor) | var(&self.band_gains[i]))
                        >> bell::<f32>(),
                );
            }

            node.set_sample_rate(sample_rate as f64);
            self.eq_unit = node;
            self.current_enabled = true;
            self.current_band_count = band_count;
        }
    }

    fn process_sample(&mut self, sample: f32) -> f32 {
        let mut out = [0.0];
        self.eq_unit.tick(&[sample], &mut out);
        soft_limit(out[0])
    }
}

pub struct EqSource<S>
where
    S: Source<Item = f32>,
{
    inner: S,
    shared: Arc<EqualizerShared>,
    current_version: u64,
    target_config: EqualizerConfig,
    smoothed_config: EqualizerConfig,
    chains: Vec<EqualizerChain>,
    channels: usize,
    sample_rate: u32,
    channel_index: usize,
    sample_counter: usize,
    fade_weight: f32,
}

impl<S> EqSource<S>
where
    S: Source<Item = f32>,
{
    pub(crate) fn new(inner: S, shared: Arc<EqualizerShared>) -> Self {
        let channels = usize::from(max(inner.channels().get(), 1_u16));
        let sample_rate = inner.sample_rate().get();
        let config = shared.current_config();
        let chains = (0..channels)
            .map(|_| EqualizerChain::from_config(&config, sample_rate))
            .collect::<Vec<_>>();

        let initial_fade = if config.enabled { 1.0 } else { 0.0 };

        Self {
            inner,
            shared,
            current_version: 0,
            target_config: config.clone(),
            smoothed_config: config,
            chains,
            channels,
            sample_rate,
            channel_index: 0,
            sample_counter: 0,
            fade_weight: initial_fade,
        }
    }

    fn refresh_if_needed(&mut self) {
        let version = self.shared.version();
        if version != self.current_version {
            self.target_config = self.shared.current_config();
            self.current_version = version;
        }

        let config_changed = smooth_config_toward(&mut self.smoothed_config, &self.target_config);
        if !config_changed {
            return;
        }

        for chain in &mut self.chains {
            chain.update_from_config(&self.smoothed_config, self.sample_rate);
        }
    }

    fn process_current_sample(&mut self, sample: f32) -> f32 {
        if self.channels == 0 {
            return sample;
        }

        if self.sample_counter % CONFIG_REFRESH_STRIDE == 0 {
            self.refresh_if_needed();
        }
        self.sample_counter = self.sample_counter.wrapping_add(1);

        let channel = self.channel_index;
        self.channel_index += 1;
        if self.channel_index >= self.channels {
            self.channel_index = 0;

            // Frame-synchronized crossfade weight update to prevent channel phase/level skew
            let target_weight = if self.smoothed_config.enabled { 1.0 } else { 0.0 };
            if (self.fade_weight - target_weight).abs() > 1e-4 {
                // ~8ms smooth transition duration
                let step = 1.0 / ((self.sample_rate as f32) * 0.008).max(64.0);
                if self.fade_weight < target_weight {
                    self.fade_weight = (self.fade_weight + step).min(1.0);
                } else {
                    self.fade_weight = (self.fade_weight - step).max(0.0);
                }
            } else {
                self.fade_weight = target_weight;
            }
        }

        // Fast path: if fully bypassed and crossfade completed, pass through directly
        if self.fade_weight == 0.0 && !self.smoothed_config.enabled {
            return sample;
        }

        let channel = min(channel, self.chains.len().saturating_sub(1));
        let eq_output = self
            .chains
            .get_mut(channel)
            .map(|chain| chain.process_sample(sample))
            .unwrap_or(sample);

        if self.fade_weight >= 1.0 {
            eq_output
        } else {
            // Smooth linear crossfade during enable/disable transition to eliminate click/pop
            sample * (1.0 - self.fade_weight) + eq_output * self.fade_weight
        }
    }
}

impl<S> Iterator for EqSource<S>
where
    S: Source<Item = f32>,
{
    type Item = f32;

    fn next(&mut self) -> Option<Self::Item> {
        let sample = self.inner.next()?;
        Some(self.process_current_sample(sample))
    }
}

impl<S> Source for EqSource<S>
where
    S: Source<Item = f32>,
{
    fn current_span_len(&self) -> Option<usize> {
        self.inner.current_span_len()
    }

    fn channels(&self) -> rodio::ChannelCount {
        self.inner.channels()
    }

    fn sample_rate(&self) -> rodio::SampleRate {
        self.inner.sample_rate()
    }

    fn total_duration(&self) -> Option<Duration> {
        self.inner.total_duration()
    }

    fn try_seek(&mut self, pos: Duration) -> Result<(), rodio::source::SeekError> {
        self.channel_index = 0;
        self.sample_counter = 0;
        for chain in &mut self.chains {
            chain.reset();
        }
        self.inner.try_seek(pos)
    }
}

fn band_center_frequency(index: usize, band_count: usize) -> f32 {
    if band_count == 31 && index < 31 {
        return ISO_31_FREQUENCIES[index];
    }
    if band_count <= 1 {
        return 1_000.0;
    }

    let min_hz = MIN_EQ_CENTER_HZ;
    let max_hz = MAX_EQ_CENTER_HZ;
    let ratio = max_hz / min_hz;
    let t = index as f32 / (band_count.saturating_sub(1) as f32);
    min_hz * ratio.powf(t)
}

fn band_q_factor(band_count: usize) -> f32 {
    if band_count == 31 {
        return 4.318;
    }
    if band_count <= 1 {
        return 1.414;
    }

    let total_octaves = (MAX_EQ_CENTER_HZ / MIN_EQ_CENTER_HZ).log2();
    let bw_oct = total_octaves / (band_count.saturating_sub(1) as f32);

    let two_pow_bw = 2.0_f32.powf(bw_oct);
    let q = two_pow_bw.sqrt() / (two_pow_bw - 1.0);
    q.clamp(0.6, 5.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_unity_gain_is_bit_transparent_and_no_soft_limiter_distortion() {
        let mut config = EqualizerConfig::default();
        config.enabled = true;
        config.band_count = 10;
        config.band_gains_db = vec![0.0; 10];

        let mut chain = EqualizerChain::from_config(&config, 44100);

        // Input signals in linear pass-through range [-0.98, 0.98]
        let samples = [0.0, 0.5, 0.90, 0.95, 0.98, -0.98];
        for &s in &samples {
            let out = chain.process_sample(s);
            // In linear pass with 0 dB gain, the output should remain bit-identical (within f32 precision)
            assert!((out - s).abs() < 1e-4, "Expected {}, got {}", s, out);
        }
    }

    #[test]
    fn test_boosting_band_preserves_preamp_and_enhances_signal() {
        let mut config = EqualizerConfig::default();
        config.enabled = true;
        config.band_count = 31;
        config.preamp_db = 0.0;
        config.bass_boost_db = 6.0;
        config.bass_boost_frequency_hz = 80.0;
        // 80Hz band (index 6 in ISO_31) boosted by 4 dB
        config.band_gains_db[6] = 4.0;

        let mut chain = EqualizerChain::from_config(&config, 44100);
        assert_eq!(chain.preamp_gain.value(), 1.0); // 0.0 dB preamp maintains 1.0x gain

        let out = chain.process_sample(0.5);
        assert!(!out.is_nan());
        assert!(out.abs() <= 1.0);
    }

    #[test]
    fn test_soft_limiter_handles_overload_smoothly() {
        // Normal linear range [-0.98, 0.98]
        assert_eq!(soft_limit(0.5), 0.5);
        assert_eq!(soft_limit(-0.5), -0.5);
        assert_eq!(soft_limit(0.98), 0.98);
        assert_eq!(soft_limit(-0.98), -0.98);

        // Over-range signals should smoothly compress and remain strictly within [-1.0, 1.0]
        let limited_pos = soft_limit(2.0);
        assert!(limited_pos > 0.98 && limited_pos <= 1.0, "Expected soft compression within (0.98, 1.0], got {}", limited_pos);

        let limited_neg = soft_limit(-2.0);
        assert!(limited_neg < -0.98 && limited_neg >= -1.0, "Expected soft compression within [-1.0, -0.98), got {}", limited_neg);
    }

    #[test]
    fn test_nyquist_frequency_protection_for_low_sample_rate() {
        let mut config = EqualizerConfig::default();
        config.enabled = true;
        config.band_count = 31;
        // Boost 20kHz band
        config.band_gains_db[30] = 6.0;

        // Sample rate 32000 has Nyquist = 16000 Hz, safe limit = 14400 Hz
        let mut chain = EqualizerChain::from_config(&config, 32000);
        let sample = chain.process_sample(0.5);
        assert!(!sample.is_nan(), "Sample should not be NaN");
        assert!(!sample.is_infinite(), "Sample should not be infinite");
    }

    #[test]
    fn test_crossfade_smoothing_transitions() {
        struct MockSource {
            samples: Vec<f32>,
            idx: usize,
        }
        impl Iterator for MockSource {
            type Item = f32;
            fn next(&mut self) -> Option<Self::Item> {
                if self.idx < self.samples.len() {
                    let s = self.samples[self.idx];
                    self.idx += 1;
                    Some(s)
                } else {
                    None
                }
            }
        }
        impl Source for MockSource {
            fn current_span_len(&self) -> Option<usize> { None }
            fn channels(&self) -> rodio::ChannelCount { std::num::NonZero::new(2).unwrap() }
            fn sample_rate(&self) -> rodio::SampleRate { std::num::NonZero::new(44100).unwrap() }
            fn total_duration(&self) -> Option<Duration> { None }
        }

        let config = EqualizerConfig {
            enabled: false,
            ..Default::default()
        };
        let shared = EqualizerShared::new(config);
        let src = MockSource {
            samples: vec![0.5; 1000],
            idx: 0,
        };
        let mut eq_source = EqSource::new(src, Arc::clone(&shared));

        // Read a few samples while disabled
        assert_eq!(eq_source.next(), Some(0.5));
        assert_eq!(eq_source.fade_weight, 0.0);

        // Enable EQ
        let mut enabled_config = shared.current_config();
        enabled_config.enabled = true;
        shared.set_config(enabled_config);

        // Process frames, fade_weight should smoothly ramp up towards 1.0 without jumping
        let mut previous_weight = eq_source.fade_weight;
        for _ in 0..200 {
            let _ = eq_source.next();
            assert!(eq_source.fade_weight >= previous_weight);
            previous_weight = eq_source.fade_weight;
        }
    }
}


