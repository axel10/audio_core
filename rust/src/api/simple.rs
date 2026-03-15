use crate::frb_generated::StreamSink;
use cpal::traits::{DeviceTrait, HostTrait};
use realfft::{num_complex::Complex, RealFftPlanner, RealToComplex};
use rodio::{Decoder, DeviceSinkBuilder, MixerDeviceSink, Player, Source};
use std::fs::File;
use std::path::Path;
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::time::Duration;
use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::{DecoderOptions, CODEC_TYPE_NULL};
use symphonia::core::errors::Error as SymphoniaError;
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;

const FFT_SIZE: usize = 1024;
const RAW_FFT_BINS: usize = FFT_SIZE / 2;
const PLAYBACK_STATE_PUSH_INTERVAL: Duration = Duration::from_millis(500);
const DEFAULT_OUTPUT_POLL_INTERVAL: Duration = Duration::from_millis(1000);
const CROSSFADE_TICK_INTERVAL: Duration = Duration::from_millis(16);

static PLAYER_CONTROLLER: OnceLock<Mutex<PlayerController>> = OnceLock::new();
static DEFAULT_OUTPUT_MONITOR: OnceLock<()> = OnceLock::new();

fn controller() -> &'static Mutex<PlayerController> {
    PLAYER_CONTROLLER.get_or_init(|| Mutex::new(PlayerController::new()))
}

#[derive(Debug, Clone)]
pub struct PlaybackState {
    pub position_ms: i64,
    pub duration_ms: i64,
    pub is_playing: bool,
    pub volume: f32,
    pub path: Option<String>,
}

struct PlaybackDeck {
    player: Arc<Player>,
    latest_fft: Arc<Mutex<Vec<f32>>>,
    loaded_path: String,
    loaded_duration: Duration,
    source_start_offset: Duration,
    gain: f32,
}

impl PlaybackDeck {
    fn playback_position(&self) -> Duration {
        let mut pos = self
            .source_start_offset
            .saturating_add(self.player.get_pos());
        if !self.loaded_duration.is_zero() {
            pos = pos.min(self.loaded_duration);
        }
        pos
    }

    fn is_playing(&self) -> bool {
        !self.player.is_paused() && !self.player.empty()
    }

    fn apply_master_volume(&self, master_volume: f32) {
        self.player
            .set_volume((master_volume * self.gain).clamp(0.0, 1.0));
    }

    fn clear(&self) {
        self.player.clear();
        self.player.pause();
        clear_fft_buffer(&self.latest_fft);
    }
}

struct PlayerController {
    sink: Option<MixerDeviceSink>,
    active_output_device_name: Option<String>,
    current_deck: Option<PlaybackDeck>,
    incoming_deck: Option<PlaybackDeck>,
    volume: f32,
    transition_generation: u64,
    cached_path: Option<String>,
    cached_pcm: Option<Arc<Vec<f32>>>,
    cached_channels: usize,
    cached_sample_rate: u32,
}

impl PlayerController {
    fn new() -> Self {
        Self {
            sink: None,
            active_output_device_name: None,
            current_deck: None,
            incoming_deck: None,
            volume: 1.0,
            transition_generation: 0,
            cached_path: None,
            cached_pcm: None,
            cached_channels: 0,
            cached_sample_rate: 0,
        }
    }

    fn ensure_audio_output(&mut self) -> Result<(), String> {
        if self.sink.is_some() {
            return Ok(());
        }

        let (sink, device_name) = Self::open_current_default_output()?;

        self.sink = Some(sink);
        self.active_output_device_name = Some(device_name);
        Ok(())
    }

    fn open_current_default_output() -> Result<(MixerDeviceSink, String), String> {
        let device = cpal::default_host()
            .default_output_device()
            .ok_or_else(|| "no default audio output device available".to_string())?;
        let device_name = describe_output_device(&device);
        let sink = DeviceSinkBuilder::from_device(device)
            .map_err(|e| format!("open default audio device failed: {e}"))?
            .open_stream()
            .map_err(|e| format!("open default audio device failed: {e}"))?;
        Ok((sink, device_name))
    }

    fn create_player(&self) -> Result<Arc<Player>, String> {
        let sink = self
            .sink
            .as_ref()
            .ok_or_else(|| "audio output is not initialized".to_string())?;
        Ok(Arc::new(Player::connect_new(&sink.mixer())))
    }

    fn public_deck(&self) -> Option<&PlaybackDeck> {
        self.incoming_deck.as_ref().or(self.current_deck.as_ref())
    }

    fn public_path(&self) -> Option<&str> {
        self.public_deck().map(|deck| deck.loaded_path.as_str())
    }

    fn public_position(&self) -> Duration {
        self.public_deck()
            .map(PlaybackDeck::playback_position)
            .unwrap_or(Duration::ZERO)
    }

    fn any_deck_playing(&self) -> bool {
        self.current_deck
            .as_ref()
            .map(PlaybackDeck::is_playing)
            .unwrap_or(false)
            || self
                .incoming_deck
                .as_ref()
                .map(PlaybackDeck::is_playing)
                .unwrap_or(false)
    }

    fn invalidate_waveform_cache(&mut self) {
        self.cached_path = None;
        self.cached_pcm = None;
        self.cached_channels = 0;
        self.cached_sample_rate = 0;
    }

    fn warm_waveform_cache_for_public_path(&mut self) {
        let Some(path) = self.public_path().map(str::to_string) else {
            return;
        };

        if self.cached_path.as_deref() == Some(path.as_str()) && self.cached_pcm.is_some() {
            return;
        }

        self.invalidate_waveform_cache();

        thread::spawn(move || {
            if let Ok(file) = File::open(&path) {
                if let Ok(source) = Decoder::try_from(file) {
                    let channels = source.channels().get() as usize;
                    let sample_rate = source.sample_rate().get();
                    let pcm: Vec<f32> = source.collect();
                    if let Ok(mut c) = controller().lock() {
                        if c.public_path() == Some(path.as_str()) {
                            c.cached_path = Some(path.clone());
                            c.cached_pcm = Some(Arc::new(pcm));
                            c.cached_channels = channels;
                            c.cached_sample_rate = sample_rate;
                        }
                    }
                }
            }
        });
    }

    fn open_deck_from_path(
        &mut self,
        path: &str,
        start_offset: Duration,
        auto_play: bool,
        gain: f32,
    ) -> Result<PlaybackDeck, String> {
        self.ensure_audio_output()?;

        let file = File::open(path).map_err(|e| format!("open file failed: {e}"))?;
        let source = Decoder::try_from(file).map_err(|e| format!("decode failed: {e}"))?;

        let total = source.total_duration().unwrap_or(Duration::ZERO);
        let clamped_offset = if total.is_zero() {
            start_offset
        } else {
            start_offset.min(total)
        };

        let latest_fft = Arc::new(Mutex::new(vec![0.0; RAW_FFT_BINS]));
        clear_fft_buffer(&latest_fft);
        let player = self.create_player()?;
        player.set_volume((self.volume * gain).clamp(0.0, 1.0));
        if clamped_offset > Duration::ZERO {
            player.append(FftSource::new(
                source.skip_duration(clamped_offset),
                Arc::clone(&latest_fft),
            ));
        } else {
            player.append(FftSource::new(source, Arc::clone(&latest_fft)));
        }
        if auto_play {
            player.play();
        } else {
            player.pause();
        }

        Ok(PlaybackDeck {
            player,
            latest_fft,
            loaded_path: path.to_string(),
            loaded_duration: total,
            source_start_offset: clamped_offset,
            gain,
        })
    }

    fn replace_current_from_path(
        &mut self,
        path: &str,
        start_offset: Duration,
        auto_play: bool,
    ) -> Result<(), String> {
        let previous_public_path = self.public_path().map(str::to_string);
        let deck = self.open_deck_from_path(path, start_offset, auto_play, 1.0)?;

        self.transition_generation = self.transition_generation.wrapping_add(1);
        if let Some(incoming) = self.incoming_deck.take() {
            incoming.clear();
        }
        if let Some(current) = self.current_deck.replace(deck) {
            current.clear();
        }
        if previous_public_path.as_deref() != Some(path) {
            self.warm_waveform_cache_for_public_path();
        }
        Ok(())
    }

    fn settle_to_public_deck(&mut self) {
        if self.incoming_deck.is_none() {
            return;
        }

        let previous_public_path = self.public_path().map(str::to_string);
        self.transition_generation = self.transition_generation.wrapping_add(1);
        if let Some(mut incoming) = self.incoming_deck.take() {
            incoming.gain = 1.0;
            incoming.apply_master_volume(self.volume);
            if let Some(current) = self.current_deck.take() {
                current.clear();
            }
            self.current_deck = Some(incoming);
        }
        if previous_public_path.as_deref() != self.public_path() {
            self.warm_waveform_cache_for_public_path();
        }
    }

    fn playback_state(&self) -> PlaybackState {
        let public_deck = self.public_deck();
        let is_playing = public_deck.map(PlaybackDeck::is_playing).unwrap_or(false);

        PlaybackState {
            position_ms: self.public_position().as_millis().min(i64::MAX as u128) as i64,
            duration_ms: public_deck
                .map(|deck| deck.loaded_duration.as_millis().min(i64::MAX as u128) as i64)
                .unwrap_or(0),
            is_playing,
            volume: self.volume,
            path: public_deck.map(|deck| deck.loaded_path.clone()),
        }
    }

    fn play_all(&self) {
        if let Some(current) = self.current_deck.as_ref() {
            current.player.play();
        }
        if let Some(incoming) = self.incoming_deck.as_ref() {
            incoming.player.play();
        }
    }

    fn pause_all(&self) {
        if let Some(current) = self.current_deck.as_ref() {
            current.player.pause();
        }
        if let Some(incoming) = self.incoming_deck.as_ref() {
            incoming.player.pause();
        }
    }

    fn toggle_all(&self) -> Result<bool, String> {
        let public_deck = self
            .public_deck()
            .ok_or_else(|| "player is not initialized".to_string())?;
        if public_deck.player.is_paused() {
            self.play_all();
            Ok(true)
        } else {
            self.pause_all();
            Ok(false)
        }
    }

    fn set_master_volume(&mut self, volume: f32) {
        self.volume = volume.clamp(0.0, 1.0);
        if let Some(current) = self.current_deck.as_ref() {
            current.apply_master_volume(self.volume);
        }
        if let Some(incoming) = self.incoming_deck.as_ref() {
            incoming.apply_master_volume(self.volume);
        }
    }

    fn start_crossfade(&mut self, path: &str, duration: Duration) -> Result<(), String> {
        if self.current_deck.is_none() || !self.any_deck_playing() || duration.is_zero() {
            return self.replace_current_from_path(path, Duration::ZERO, true);
        }

        let mut incoming = self.open_deck_from_path(path, Duration::ZERO, true, 0.0)?;
        incoming.gain = 0.0;
        incoming.apply_master_volume(self.volume);

        self.transition_generation = self.transition_generation.wrapping_add(1);
        let generation = self.transition_generation;

        if let Some(previous_incoming) = self.incoming_deck.replace(incoming) {
            previous_incoming.clear();
        }
        if let Some(current) = self.current_deck.as_mut() {
            current.gain = 1.0;
            current.apply_master_volume(self.volume);
        }
        self.warm_waveform_cache_for_public_path();

        thread::spawn(move || {
            drive_crossfade(generation, duration);
        });

        Ok(())
    }

    fn maybe_switch_to_new_default_output(&mut self) -> Result<(), String> {
        if self.sink.is_none() {
            return Ok(());
        }

        let Some(current_default_device) = cpal::default_host().default_output_device() else {
            return Ok(());
        };
        let current_default_name = describe_output_device(&current_default_device);

        if self.active_output_device_name.as_deref() == Some(current_default_name.as_str()) {
            return Ok(());
        }

        let playback_position = self.public_position();
        let loaded_path = self.public_path().map(str::to_string);
        let was_playing = self.any_deck_playing();

        self.transition_generation = self.transition_generation.wrapping_add(1);
        if let Some(incoming) = self.incoming_deck.take() {
            incoming.clear();
        }
        if let Some(current) = self.current_deck.take() {
            current.clear();
        }

        let (sink, device_name) = Self::open_current_default_output()?;
        self.sink = Some(sink);
        self.active_output_device_name = Some(device_name);

        if let Some(path) = loaded_path {
            self.replace_current_from_path(&path, playback_position, was_playing)?;
        }

        Ok(())
    }
}

fn clear_fft_buffer(latest_fft: &Arc<Mutex<Vec<f32>>>) {
    if let Ok(mut shared) = latest_fft.lock() {
        shared.fill(0.0);
    }
}

fn drive_crossfade(generation: u64, duration: Duration) {
    let steps =
        ((duration.as_millis() / CROSSFADE_TICK_INTERVAL.as_millis().max(1)).max(1)) as usize;

    for step in 1..=steps {
        thread::sleep(CROSSFADE_TICK_INTERVAL);

        let Ok(mut c) = controller().lock() else {
            return;
        };
        if c.transition_generation != generation {
            return;
        }

        let progress = step as f32 / steps as f32;
        let master_volume = c.volume;
        if let Some(current) = c.current_deck.as_mut() {
            current.gain = (1.0 - progress).clamp(0.0, 1.0);
            current.apply_master_volume(master_volume);
        }
        if let Some(incoming) = c.incoming_deck.as_mut() {
            incoming.gain = progress.clamp(0.0, 1.0);
            incoming.apply_master_volume(master_volume);
        }
    }

    if let Ok(mut c) = controller().lock() {
        if c.transition_generation != generation {
            return;
        }
        c.settle_to_public_deck();
    }
}

fn describe_output_device(device: &cpal::Device) -> String {
    format!("{:?}", device.id())
}

fn start_default_output_monitor() {
    DEFAULT_OUTPUT_MONITOR.get_or_init(|| {
        thread::spawn(|| loop {
            thread::sleep(DEFAULT_OUTPUT_POLL_INTERVAL);

            if let Ok(mut c) = controller().lock() {
                let _ = c.maybe_switch_to_new_default_output();
            }
        });
    });
}

fn push_state() -> PlaybackState {
    controller()
        .lock()
        .map(|c| c.playback_state())
        .unwrap_or(PlaybackState {
            position_ms: 0,
            duration_ms: 0,
            is_playing: false,
            volume: 1.0,
            path: None,
        })
}

fn trigger_state_push(
    sink: &StreamSink<PlaybackState, flutter_rust_bridge::for_generated::SseCodec>,
) -> bool {
    sink.add(push_state()).is_ok()
}

struct FftSource<S>
where
    S: Source<Item = f32>,
{
    inner: S,
    channels: usize,
    frame_accum: f32,
    frame_pos: usize,
    fft: Arc<dyn RealToComplex<f32>>,
    hann_window: Vec<f32>,
    window_sum: f32,
    input_buffer: Vec<f32>,
    output_buffer: Vec<Complex<f32>>,
    index: usize,
    latest_fft: Arc<Mutex<Vec<f32>>>,
}

impl<S> FftSource<S>
where
    S: Source<Item = f32>,
{
    fn new(inner: S, latest_fft: Arc<Mutex<Vec<f32>>>) -> Self {
        let mut planner = RealFftPlanner::<f32>::new();
        let fft = planner.plan_fft_forward(FFT_SIZE);
        let channels = usize::from(inner.channels().get().max(1));

        let mut hann_window = Vec::with_capacity(FFT_SIZE);
        for i in 0..FFT_SIZE {
            let phase = (2.0_f32 * std::f32::consts::PI * i as f32) / (FFT_SIZE as f32 - 1.0);
            hann_window.push(0.5 - 0.5 * phase.cos());
        }
        let window_sum = hann_window.iter().sum::<f32>().max(1e-9);

        Self {
            inner,
            channels,
            frame_accum: 0.0,
            frame_pos: 0,
            input_buffer: fft.make_input_vec(),
            output_buffer: fft.make_output_vec(),
            fft,
            hann_window,
            window_sum,
            index: 0,
            latest_fft,
        }
    }

    fn push_mono_sample(&mut self, sample: f32) {
        self.input_buffer[self.index] = sample;
        self.index += 1;

        if self.index == FFT_SIZE {
            self.compute_fft();
            self.index = 0;
        }
    }

    fn compute_fft(&mut self) {
        for (s, w) in self.input_buffer.iter_mut().zip(self.hann_window.iter()) {
            *s *= *w;
        }

        if self
            .fft
            .process(&mut self.input_buffer, &mut self.output_buffer)
            .is_err()
        {
            return;
        }

        let magnitudes: Vec<f32> = self
            .output_buffer
            .iter()
            .take(RAW_FFT_BINS)
            .enumerate()
            .map(|(i, c)| {
                let mag = (c.re * c.re + c.im * c.im).sqrt();
                let one_sided_scale = if i == 0 { 1.0 } else { 2.0 };
                (mag * one_sided_scale) / self.window_sum
            })
            .collect();

        if let Ok(mut shared) = self.latest_fft.lock() {
            *shared = magnitudes;
        }
    }
}

impl<S> Iterator for FftSource<S>
where
    S: Source<Item = f32>,
{
    type Item = f32;

    fn next(&mut self) -> Option<Self::Item> {
        let sample = self.inner.next()?;

        if self.channels <= 1 {
            self.push_mono_sample(sample);
        } else {
            self.frame_accum += sample;
            self.frame_pos += 1;
            if self.frame_pos == self.channels {
                let mono = self.frame_accum / self.channels as f32;
                self.frame_accum = 0.0;
                self.frame_pos = 0;
                self.push_mono_sample(mono);
            }
        }

        Some(sample)
    }
}

impl<S> Source for FftSource<S>
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
        self.index = 0;
        self.frame_accum = 0.0;
        self.frame_pos = 0;
        self.input_buffer.fill(0.0);
        self.output_buffer.fill(Complex { re: 0.0, im: 0.0 });
        self.inner.try_seek(pos)
    }
}

#[flutter_rust_bridge::frb(sync)] // Synchronous mode for simplicity of the demo
pub fn greet(name: String) -> String {
    format!("Hello, {name}!")
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
    start_default_output_monitor();

    if let Ok(mut c) = controller().lock() {
        let _ = c.ensure_audio_output();
    }
}

pub fn load_audio_file(path: String) -> Result<(), String> {
    let mut c = controller()
        .lock()
        .map_err(|_| "player lock poisoned".to_string())?;
    c.replace_current_from_path(&path, Duration::ZERO, false)
}

pub fn crossfade_to_audio_file(path: String, duration_ms: i64) -> Result<(), String> {
    let mut c = controller()
        .lock()
        .map_err(|_| "player lock poisoned".to_string())?;
    let duration = Duration::from_millis(duration_ms.max(0) as u64);
    c.start_crossfade(&path, duration)
}

pub fn subscribe_playback_state(
    sink: StreamSink<PlaybackState, flutter_rust_bridge::for_generated::SseCodec>,
) {
    thread::spawn(move || {
        if !trigger_state_push(&sink) {
            return;
        }

        loop {
            thread::sleep(PLAYBACK_STATE_PUSH_INTERVAL);
            if !trigger_state_push(&sink) {
                break;
            }
        }
    });
}

pub fn play_audio() -> Result<(), String> {
    let c = controller()
        .lock()
        .map_err(|_| "player lock poisoned".to_string())?;
    if c.public_deck().is_none() {
        return Err("player is not initialized".to_string());
    }
    c.play_all();
    Ok(())
}

pub fn pause_audio() -> Result<(), String> {
    let c = controller()
        .lock()
        .map_err(|_| "player lock poisoned".to_string())?;
    if c.public_deck().is_none() {
        return Err("player is not initialized".to_string());
    }
    c.pause_all();
    Ok(())
}

pub fn toggle_audio() -> Result<bool, String> {
    let c = controller()
        .lock()
        .map_err(|_| "player lock poisoned".to_string())?;
    c.toggle_all()
}

pub fn seek_audio_ms(position_ms: i64) -> Result<(), String> {
    let mut c = controller()
        .lock()
        .map_err(|_| "player lock poisoned".to_string())?;

    c.settle_to_public_deck();

    let target_ms = position_ms.max(0) as u64;
    let mut target = Duration::from_millis(target_ms);
    let Some(current) = c.current_deck.as_mut() else {
        return Err("audio is not loaded".to_string());
    };

    if !current.loaded_duration.is_zero() {
        target = target.min(current.loaded_duration);
    }

    // Fast path: seek the currently loaded source in-place.
    let seek_result = current.player.try_seek(target);
    if seek_result.is_ok() {
        current.source_start_offset = Duration::ZERO;
        clear_fft_buffer(&current.latest_fft);
        return Ok(());
    }

    // Fallback for non-seekable decoders/sources: rebuild source at target offset.
    let path = current.loaded_path.clone();
    let was_playing = current.is_playing();
    c.replace_current_from_path(&path, target, was_playing)
}

pub fn set_audio_volume(volume: f32) -> Result<(), String> {
    let mut c = controller()
        .lock()
        .map_err(|_| "player lock poisoned".to_string())?;

    c.set_master_volume(volume);
    Ok(())
}

pub fn dispose_audio() -> Result<(), String> {
    let mut c = controller()
        .lock()
        .map_err(|_| "player lock poisoned".to_string())?;

    c.transition_generation = c.transition_generation.wrapping_add(1);
    if let Some(incoming) = c.incoming_deck.take() {
        incoming.clear();
    }
    if let Some(current) = c.current_deck.take() {
        current.clear();
    }
    c.active_output_device_name = None;
    c.sink = None;
    c.cached_path = None;
    c.cached_pcm = None;
    c.cached_channels = 0;
    c.cached_sample_rate = 0;
    Ok(())
}

#[flutter_rust_bridge::frb(sync)]
pub fn is_audio_playing() -> bool {
    if let Ok(c) = controller().lock() {
        return c.any_deck_playing();
    }
    false
}

#[flutter_rust_bridge::frb(sync)]
pub fn get_audio_duration_ms() -> i64 {
    if let Ok(c) = controller().lock() {
        if let Some(deck) = c.public_deck() {
            return deck.loaded_duration.as_millis().min(i64::MAX as u128) as i64;
        }
    }
    0
}

#[flutter_rust_bridge::frb(sync)]
pub fn get_audio_position_ms() -> i64 {
    if let Ok(c) = controller().lock() {
        return c.public_position().as_millis().min(i64::MAX as u128) as i64;
    }
    0
}

#[flutter_rust_bridge::frb(sync)]
pub fn get_latest_fft() -> Vec<f32> {
    if let Ok(c) = controller().lock() {
        if let Some(deck) = c.public_deck() {
            if let Ok(fft) = deck.latest_fft.lock() {
                return fft.clone();
            }
        }
    }
    vec![0.0; RAW_FFT_BINS]
}

#[flutter_rust_bridge::frb(sync)]
pub fn get_loaded_audio_path() -> Option<String> {
    if let Ok(c) = controller().lock() {
        return c.public_path().map(str::to_string);
    }
    None
}

#[derive(Debug, Clone)]
pub struct WaveformChunk {
    pub index: usize,
    pub peak: f32, // absolute max peak
}

fn fold_packet_peaks_to_chunks(
    packet_peaks: &[(u64, f32)],
    expected_chunks: usize,
    total_ts: Option<u64>,
) -> Vec<f32> {
    let mut waveform = vec![0.0f32; expected_chunks];
    if packet_peaks.is_empty() {
        return waveform;
    }

    if let Some(ts_end) = total_ts.filter(|v| *v > 0) {
        for (packet_end_ts, peak) in packet_peaks {
            let ts = packet_end_ts.saturating_sub(1);
            let idx = ((ts as u128 * expected_chunks as u128) / ts_end as u128) as usize;
            let chunk = idx.min(expected_chunks.saturating_sub(1));
            if *peak > waveform[chunk] {
                waveform[chunk] = *peak;
            }
        }
        return waveform;
    }

    let packet_count = packet_peaks.len().max(1);
    for (i, (_, peak)) in packet_peaks.iter().enumerate() {
        let idx = (i * expected_chunks) / packet_count;
        let chunk = idx.min(expected_chunks.saturating_sub(1));
        if *peak > waveform[chunk] {
            waveform[chunk] = *peak;
        }
    }
    waveform
}

fn extract_waveform_from_path(
    path: &str,
    expected_chunks: usize,
    sample_stride: usize,
) -> Result<Vec<f32>, String> {
    if expected_chunks == 0 {
        return Err("expected_chunks must be > 0".to_string());
    }

    let sample_stride = sample_stride.max(1);

    // Stream decode with Symphonia and aggregate per-packet peaks.
    let file = File::open(path).map_err(|e| format!("open file failed: {} - {}", path, e))?;
    let mut hint = Hint::new();
    if let Some(ext) = Path::new(path).extension().and_then(|e| e.to_str()) {
        hint.with_extension(ext);
    }

    let mss = MediaSourceStream::new(Box::new(file), Default::default());
    let mut format = symphonia::default::get_probe()
        .format(
            &hint,
            mss,
            &FormatOptions::default(),
            &MetadataOptions::default(),
        )
        .map_err(|e| format!("probe format failed: {}", e))?
        .format;

    let track = format
        .tracks()
        .iter()
        .find(|t| t.codec_params.codec != CODEC_TYPE_NULL)
        .or_else(|| format.default_track())
        .ok_or_else(|| "No audio track found in loaded file".to_string())?;

    let track_id = track.id;
    let total_ts = track.codec_params.n_frames.filter(|v| *v > 0);
    let mut decoder = symphonia::default::get_codecs()
        .make(&track.codec_params, &DecoderOptions::default())
        .map_err(|e| format!("create decoder failed: {}", e))?;

    let mut sample_buf: Option<SampleBuffer<f32>> = None;
    let mut packet_peaks: Vec<(u64, f32)> = Vec::new();
    let mut packet_index = 0usize;
    let mut max_packet_end_ts = 0u64;

    loop {
        let packet = match format.next_packet() {
            Ok(packet) => packet,
            Err(SymphoniaError::IoError(_)) => break,
            Err(SymphoniaError::ResetRequired) => {
                return Err("stream reset required during waveform decode".to_string());
            }
            Err(err) => return Err(format!("read packet failed: {}", err)),
        };

        if packet.track_id() != track_id {
            continue;
        }

        let packet_dur = packet.dur();
        let packet_ts = packet.ts();

        let process_this_packet = packet_index % sample_stride == 0;
        packet_index = packet_index.saturating_add(1);

        if !process_this_packet {
            // Updated: Just update the timestamp and skip decoding/processing
            let packet_end_ts = packet_ts.saturating_add(packet_dur.max(1));
            if packet_end_ts > max_packet_end_ts {
                max_packet_end_ts = packet_end_ts;
            }
            continue;
        }

        let packet_end_ts = packet_ts.saturating_add(packet_dur.max(1));
        if packet_end_ts > max_packet_end_ts {
            max_packet_end_ts = packet_end_ts;
        }

        let decoded = match decoder.decode(&packet) {
            Ok(decoded) => decoded,
            Err(SymphoniaError::DecodeError(_)) => continue,
            Err(SymphoniaError::IoError(_)) => continue,
            Err(err) => return Err(format!("decode packet failed: {}", err)),
        };

        if sample_buf.is_none() {
            sample_buf = Some(SampleBuffer::<f32>::new(
                decoded.capacity() as u64,
                *decoded.spec(),
            ));
        }

        if let Some(buf) = sample_buf.as_mut() {
            buf.copy_interleaved_ref(decoded);
            let mut peak = 0.0f32;
            for sample in buf.samples() {
                let abs_sample = sample.abs();
                if abs_sample > peak {
                    peak = abs_sample;
                }
            }
            packet_peaks.push((packet_end_ts, peak.min(1.0)));
        }
    }

    let effective_total_ts = total_ts.or(Some(max_packet_end_ts.max(1)));
    Ok(fold_packet_peaks_to_chunks(
        &packet_peaks,
        expected_chunks,
        effective_total_ts,
    ))
}

pub fn extract_loaded_waveform(
    expected_chunks: usize,
    sample_stride: usize,
) -> Result<Vec<f32>, String> {
    // Snapshot the currently loaded file path.
    let path = {
        let c = controller()
            .lock()
            .map_err(|_| "player lock poisoned".to_string())?;
        c.public_path()
            .map(str::to_string)
            .ok_or_else(|| "No loaded audio file to extract waveform from".to_string())?
    };

    let waveform = extract_waveform_from_path(&path, expected_chunks, sample_stride)?;

    {
        // Ensure the decoded result still matches the active loaded file.
        let c = controller()
            .lock()
            .map_err(|_| "player lock poisoned".to_string())?;
        if c.public_path() != Some(path.as_str()) {
            return Err(
                "loaded audio changed during waveform extraction, please retry".to_string(),
            );
        }
    }

    Ok(waveform)
}

pub fn extract_waveform_for_path(
    path: String,
    expected_chunks: usize,
    sample_stride: usize,
) -> Result<Vec<f32>, String> {
    if path.trim().is_empty() {
        return Err("path is empty".to_string());
    }
    extract_waveform_from_path(&path, expected_chunks, sample_stride)
}
