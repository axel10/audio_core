use fundsp::prelude::*;
use rodio::Source;
use std::cmp::{max, min};
use std::sync::{
    atomic::{AtomicU64, Ordering},
    Arc, Mutex,
};
use std::time::Duration;

pub const MAX_EQ_BANDS: usize = 20;
const MIN_EQ_CENTER_HZ: f32 = 32.0;
const MAX_EQ_CENTER_HZ: f32 = 16_000.0;
const DEFAULT_BASS_BOOST_HZ: f32 = 80.0;
const DEFAULT_BASS_BOOST_Q: f32 = 0.75;
const CONFIG_REFRESH_STRIDE: usize = 64;
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
    protection_unit: Box<dyn AudioUnit>,
    sample_rate: u32,
}

impl EqualizerChain {
    fn from_config(config: &EqualizerConfig, sample_rate: u32) -> Self {
        let mut chain = Self::identity(sample_rate);
        chain.update_from_config(config, sample_rate);
        chain
    }

    fn identity(sample_rate: u32) -> Self {
        let mut protection = Box::new(
            shape(ShapeFn(|x| {
                let abs = x.abs();
                if abs <= 0.95 {
                    return x;
                }
                let sign = x.signum();
                let normalized = ((abs - 0.95) / 0.05).clamp(0.0, 1.0);
                let eased = normalized * normalized * (3.0 - 2.0 * normalized);
                let limited = 0.95 + 0.05 * eased;
                sign * limited.min(1.0)
            }))
        );
        protection.set_sample_rate(sample_rate as f64);

        Self {
            eq_unit: Box::new(pass()),
            protection_unit: protection,
            sample_rate,
        }
    }

    fn reset(&mut self) {
        self.eq_unit.reset();
        self.protection_unit.reset();
    }

    fn update_from_config(&mut self, config: &EqualizerConfig, sample_rate: u32) {
        let config = config.clone().sanitized();

        // Update protection unit if sample rate changed
        if self.sample_rate != sample_rate {
            let mut protection = Box::new(
                shape(ShapeFn(|x| {
                    let abs = x.abs();
                    if abs <= 0.95 {
                        return x;
                    }
                    let sign = x.signum();
                    let normalized = ((abs - 0.95) / 0.05).clamp(0.0, 1.0);
                    let eased = normalized * normalized * (3.0 - 2.0 * normalized);
                    let limited = 0.95 + 0.05 * eased;
                    sign * limited.min(1.0)
                }))
            );
            protection.set_sample_rate(sample_rate as f64);
            self.protection_unit = protection;
            self.sample_rate = sample_rate;
        }

        if !config.enabled {
            self.eq_unit = Box::new(pass());
            self.eq_unit.set_sample_rate(sample_rate as f64);
            return;
        }

        // Build the EQ part (excluding limiter to prevent constant resets)
        // Auto gain compensation: Calculate the maximum boost to create headroom
        let mut max_boost_db = 0.0_f32;
        if config.bass_boost_db > 0.0 {
            max_boost_db = config.bass_boost_db;
        }
        for i in 0..config.band_count as usize {
            if let Some(&gain) = config.band_gains_db.get(i) {
                if gain > max_boost_db {
                    max_boost_db = gain;
                }
            }
        }
        
        // Reduce preamp by `max_boost_db` to prevent digital clipping
        let actual_preamp_db = config.preamp_db - max_boost_db;
        let preamp_gain: f32 = db_amp(actual_preamp_db);
        let mut node: Box<dyn AudioUnit> = Box::new(mul(preamp_gain));

        // Bass Boost
        if config.bass_boost_db.abs() > EPSILON_GAIN_DB {
            node = Box::new(An(Unit::<U1, U1>::new(node)) >> lowshelf_hz(
                config.bass_boost_frequency_hz,
                config.bass_boost_q,
                db_amp(config.bass_boost_db),
            ));
        }

        // EQ Bands
        let band_count = config.band_count as usize;
        for i in 0..band_count {
            let freq = band_center_frequency(i, band_count);
            let gain_db = config.band_gains_db.get(i).copied().unwrap_or(0.0);
            if gain_db.abs() > EPSILON_GAIN_DB {
                node = Box::new(An(Unit::<U1, U1>::new(node)) >> bell_hz(freq, 1.0, db_amp(gain_db)));
            }
        }

        node.set_sample_rate(sample_rate as f64);
        self.eq_unit = node;
    }

    fn process_sample(&mut self, sample: f32) -> f32 {
        let mut temp = [0.0];
        self.eq_unit.tick(&[sample], &mut temp);
        let mut out = [0.0];
        self.protection_unit.tick(&temp, &mut out);
        out[0]
    }
}

pub struct EqSource<S>
where
    S: Source<Item = f32>,
{
    inner: S,
    shared: Arc<EqualizerShared>,
    current_version: u64,
    chains: Vec<EqualizerChain>,
    channels: usize,
    sample_rate: u32,
    channel_index: usize,
    sample_counter: usize,
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

        Self {
            inner,
            shared,
            current_version: 0,
            chains,
            channels,
            sample_rate,
            channel_index: 0,
            sample_counter: 0,
        }
    }

    fn refresh_if_needed(&mut self) {
        let version = self.shared.version();
        if version == self.current_version {
            return;
        }

        let config = self.shared.current_config();
        for chain in &mut self.chains {
            chain.update_from_config(&config, self.sample_rate);
        }
        self.current_version = version;
    }

    fn process_current_sample(&mut self, sample: f32) -> f32 {
        if self.channels == 0 {
            return sample;
        }

        if self.sample_counter % CONFIG_REFRESH_STRIDE == 0 {
            self.refresh_if_needed();
        }
        self.sample_counter = self.sample_counter.wrapping_add(1);

        let channel = min(self.channel_index, self.chains.len().saturating_sub(1));
        let output = self
            .chains
            .get_mut(channel)
            .map(|chain| chain.process_sample(sample))
            .unwrap_or(sample);

        self.channel_index += 1;
        if self.channel_index >= self.channels {
            self.channel_index = 0;
        }
        output
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
    if band_count <= 1 {
        return 1_000.0;
    }

    let min_hz = MIN_EQ_CENTER_HZ;
    let max_hz = MAX_EQ_CENTER_HZ;
    let ratio = max_hz / min_hz;
    let t = index as f32 / (band_count.saturating_sub(1) as f32);
    min_hz * ratio.powf(t)
}
