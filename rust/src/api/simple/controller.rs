use super::equalizer::{EqSource, EqualizerConfig, EqualizerShared};
use super::fft::{clear_fft_buffer, FftSource, RAW_FFT_BINS};
#[cfg(any(target_os = "windows", target_os = "linux"))]
use ffmpeg_core::AudioSource as CoreAudioSource;
use log::{error, info, warn};
use rodio::cpal::traits::{DeviceTrait, HostTrait};
use rodio::{Decoder, DeviceSinkBuilder, MixerDeviceSink, Player, Source};
use std::fs::File;
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::time::Duration;
use std::{cmp, f64};

#[cfg(any(target_os = "windows", target_os = "linux"))]
struct FfmpegAudioSource {
    inner: CoreAudioSource,
}

#[cfg(any(target_os = "windows", target_os = "linux"))]
impl FfmpegAudioSource {
    fn open(path: impl AsRef<std::path::Path>) -> Result<Self, String> {
        CoreAudioSource::open(path)
            .map(|inner| Self { inner })
            .map_err(|error| error.to_string())
    }

    fn seek_to(&mut self, position: Duration) -> Result<(), String> {
        self.inner
            .seek_to(position)
            .map_err(|error| error.to_string())
    }

    fn total_duration(&self) -> Option<Duration> {
        self.inner.total_duration()
    }
}

#[cfg(any(target_os = "windows", target_os = "linux"))]
impl Iterator for FfmpegAudioSource {
    type Item = rodio::Sample;

    fn next(&mut self) -> Option<Self::Item> {
        self.inner.next()
    }

    fn size_hint(&self) -> (usize, Option<usize>) {
        self.inner.size_hint()
    }
}

enum DecoderBackend {
    #[cfg(any(target_os = "windows", target_os = "linux"))]
    Ffmpeg(FfmpegAudioSource),
    Symphonia {
        source: Box<dyn Source<Item = f32> + Send>,
        engine: &'static str,
    },
}

impl DecoderBackend {
    #[cfg(any(target_os = "windows", target_os = "linux"))]
    fn open(path: &str, file: File) -> Result<Self, String> {
        info!("[DecoderBackend] Attempting to open audio path: {}", path);
        match FfmpegAudioSource::open(path) {
            Ok(ffmpeg_source) => {
                info!("[DecoderBackend] Successfully opened via FFmpeg backend");
                Ok(Self::Ffmpeg(ffmpeg_source))
            }
            Err(ffmpeg_error) => {
                warn!(
                    "[DecoderBackend] FFmpeg backend failed to open (error: {}). Falling back to Symphonia",
                    ffmpeg_error
                );
                match Self::open_symphonia(file) {
                    Ok(symphonia_source) => {
                        info!("[DecoderBackend] Successfully opened via Symphonia backend");
                        Ok(symphonia_source)
                    }
                    Err(symphonia_error) => {
                        error!(
                            "[DecoderBackend] Symphonia backend also failed to open (error: {})",
                            symphonia_error
                        );
                        Err(symphonia_error)
                    }
                }
            }
        }
    }

    #[cfg(not(any(target_os = "windows", target_os = "linux")))]
    fn open(_path: &str, file: File) -> Result<Self, String> {
        Self::open_symphonia(file)
    }

    fn open_symphonia(file: File) -> Result<Self, String> {
        let decoder = Decoder::try_from(file).map_err(|e| format!("decode failed: {e}"))?;
        let source: Box<dyn Source<Item = f32> + Send> = Box::new(decoder);

        Ok(Self::Symphonia {
            source,
            engine: "symphonia",
        })
    }

    fn total_duration(&self) -> Option<Duration> {
        match self {
            #[cfg(any(target_os = "windows", target_os = "linux"))]
            Self::Ffmpeg(source) => source.total_duration(),
            Self::Symphonia { source, .. } => source.total_duration(),
        }
    }

    fn engine(&self) -> &'static str {
        match self {
            #[cfg(any(target_os = "windows", target_os = "linux"))]
            Self::Ffmpeg(_) => "ffmpeg",
            Self::Symphonia { engine, .. } => engine,
        }
    }

    fn into_source(self) -> Box<dyn Source<Item = f32> + Send> {
        match self {
            #[cfg(any(target_os = "windows", target_os = "linux"))]
            Self::Ffmpeg(source) => Box::new(source),
            Self::Symphonia { source, .. } => source,
        }
    }
}

#[cfg(any(target_os = "windows", target_os = "linux"))]
impl Source for FfmpegAudioSource {
    fn current_span_len(&self) -> Option<usize> {
        self.inner.current_span_len()
    }

    fn channels(&self) -> rodio::ChannelCount {
        std::num::NonZero::new(self.inner.channels())
            .expect("ffmpeg source channels must be non-zero")
    }

    fn sample_rate(&self) -> rodio::SampleRate {
        std::num::NonZero::new(self.inner.sample_rate())
            .expect("ffmpeg source sample rate must be non-zero")
    }

    fn total_duration(&self) -> Option<Duration> {
        self.inner.total_duration()
    }

    fn try_seek(&mut self, pos: Duration) -> Result<(), rodio::source::SeekError> {
        self.seek_to(pos).map_err(|error| {
            rodio::source::SeekError::Other(std::sync::Arc::new(std::io::Error::other(error)))
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum FadeMode {
    Sequential,
    Crossfade,
}

#[derive(Debug, Clone, Copy)]
pub struct FadeSettings {
    pub fade_on_switch: bool,
    pub fade_on_pause_resume: bool,
    pub duration_ms: i64,
    pub mode: FadeMode,
}

impl Default for FadeSettings {
    fn default() -> Self {
        Self {
            fade_on_switch: false,
            fade_on_pause_resume: false,
            duration_ms: 500,
            mode: FadeMode::Sequential,
        }
    }
}

const DEFAULT_OUTPUT_POLL_INTERVAL: Duration = Duration::from_millis(1000);
const CROSSFADE_TICK_INTERVAL: Duration = Duration::from_millis(16);
const WAVEFORM_RMS_WINDOWS_PER_CHUNK: usize = 8;
const WAVEFORM_PRECISION_SCALE: f64 = 10000.0;

static PLAYER_CONTROLLER: OnceLock<Mutex<PlayerController>> = OnceLock::new();
static DEFAULT_OUTPUT_MONITOR: OnceLock<()> = OnceLock::new();

fn controller() -> &'static Mutex<PlayerController> {
    PLAYER_CONTROLLER.get_or_init(|| Mutex::new(PlayerController::new()))
}

#[derive(Debug, Clone, Default)]
pub struct PlaybackState {
    pub playback_state: Option<String>,
    pub position_ms: i64,
    pub duration_ms: i64,
    pub is_playing: bool,
    pub volume: f32,
    pub path: Option<String>,
    pub error: Option<String>,
}

struct PlaybackDeck {
    player: Arc<Player>,
    latest_fft: Arc<Mutex<Vec<f32>>>,
    loaded_path: String,
    loaded_duration: Duration,
    source_start_offset: Duration,
    gain: f32,
    decode_engine: String,
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
    equalizer: Arc<EqualizerShared>,
    volume: f32,
    transition_generation: u64,
    volume_fade_generation: u64,
    cached_path: Option<String>,
    cached_pcm: Option<Arc<Vec<f32>>>,
    cached_channels: usize,
    cached_sample_rate: u32,
    pending_edit: Option<PendingEdit>,
    pause_fade_in_progress: bool,
    pending_playback_state: Option<String>,
    last_decode_engine: Option<String>,
}

struct PendingEdit {
    path: String,
    position: Duration,
    was_playing: bool,
    gain: f32,
}

struct EndNotifySource<I, F>
where
    F: FnMut(),
{
    input: I,
    callback: F,
    signal_sent: bool,
}

impl<I, F> EndNotifySource<I, F>
where
    F: FnMut(),
{
    fn new(input: I, callback: F) -> Self {
        Self {
            input,
            callback,
            signal_sent: false,
        }
    }
}

impl<I, F> Iterator for EndNotifySource<I, F>
where
    I: Iterator,
    F: FnMut(),
{
    type Item = I::Item;

    fn next(&mut self) -> Option<Self::Item> {
        let next = self.input.next();
        if !self.signal_sent && next.is_none() {
            self.signal_sent = true;
            (self.callback)();
        }
        next
    }
}

impl<I, F> Source for EndNotifySource<I, F>
where
    I: Source,
    F: FnMut(),
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

    fn try_seek(&mut self, pos: Duration) -> Result<(), rodio::source::SeekError> {
        self.input.try_seek(pos)
    }
}

impl PlayerController {
    fn new() -> Self {
        Self {
            sink: None,
            active_output_device_name: None,
            current_deck: None,
            incoming_deck: None,
            equalizer: EqualizerShared::new(EqualizerConfig::default()),
            volume: 1.0,
            transition_generation: 0,
            volume_fade_generation: 0,
            cached_path: None,
            cached_pcm: None,
            cached_channels: 0,
            cached_sample_rate: 0,
            pending_edit: None,
            pause_fade_in_progress: false,
            pending_playback_state: None,
            last_decode_engine: None,
        }
    }

    fn ensure_audio_output(&mut self) -> Result<(), String> {
        if self.sink.is_some() {
            return Ok(());
        }

        info!("[AudioDeviceMonitor] ensure_audio_output: opening new default output");
        let (sink, device_name) = Self::open_current_default_output()?;
        info!(
            "[AudioDeviceMonitor] ensure_audio_output: opened device '{}'",
            device_name
        );
        self.sink = Some(sink);
        self.active_output_device_name = Some(device_name);
        Ok(())
    }

    fn open_current_default_output() -> Result<(MixerDeviceSink, String), String> {
        let device = rodio::cpal::default_host()
            .default_output_device()
            .ok_or_else(|| "no default audio output device available".to_string())?;
        let device_name = describe_output_device(&device);
        let sink = DeviceSinkBuilder::from_device(device)
            .map_err(|e| format!("open default audio device failed: {e}"))?
            .with_buffer_size(rodio::cpal::BufferSize::Fixed(2048))
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

    pub(super) fn public_path(&self) -> Option<&str> {
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
            let _ = get_audio_pcm(Some(path), 0);
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

        // 先把播放器挂载到系统混音器上 (制造时间差，让后台音频流消耗 Empty 缓冲区，彻底消除底层 Bug 隐患)
        let player = self.create_player()?;
        let latest_fft = Arc::new(Mutex::new(vec![0.0; RAW_FFT_BINS]));
        clear_fft_buffer(&latest_fft);

        // 耗时操作：打开文件、构建系统层级组件 (大约耗时几十毫秒以上)
        let file = File::open(path).map_err(|e| format!("open file failed: {e}"))?;

        let backend = DecoderBackend::open(path, file)?;
        let total = backend.total_duration().unwrap_or(Duration::ZERO);
        let clamped_offset = if total.is_zero() {
            start_offset
        } else {
            start_offset.min(total)
        };
        player.set_volume((self.volume * gain).clamp(0.0, 1.0));
        let decode_engine = backend.engine().to_string();
        let eq_source = EqSource::new(backend.into_source(), Arc::clone(&self.equalizer));
        let audio_source: Box<dyn Source<Item = f32> + Send> = if clamped_offset > Duration::ZERO {
            Box::new(eq_source.skip_duration(clamped_offset))
        } else {
            Box::new(eq_source)
        };
        let end_path = path.to_string();
        let notifying_source = EndNotifySource::new(
            FftSource::new(audio_source, Arc::clone(&latest_fft)),
            move || {
                if let Ok(mut c) = controller().lock() {
                    c.mark_track_ended(&end_path);
                }
            },
        );
        player.append(notifying_source);
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
            decode_engine,
        })
    }

    fn replace_current_from_path(
        &mut self,
        path: &str,
        start_offset: Duration,
        auto_play: bool,
    ) -> Result<(), String> {
        self.pause_fade_in_progress = false;
        self.clear_pending_playback_state();
        let previous_public_path = self.public_path().map(str::to_string);
        let deck = self.open_deck_from_path(path, start_offset, auto_play, 1.0)?;
        self.last_decode_engine = Some(deck.decode_engine.clone());

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

    fn playback_state_snapshot(&self) -> PlaybackState {
        let public_deck = self.public_deck();
        let is_playing = public_deck.map(PlaybackDeck::is_playing).unwrap_or(false)
            && !self.pause_fade_in_progress;

        PlaybackState {
            playback_state: self.pending_playback_state.clone(),
            position_ms: self.public_position().as_millis().min(i64::MAX as u128) as i64,
            duration_ms: public_deck
                .map(|deck| deck.loaded_duration.as_millis().min(i64::MAX as u128) as i64)
                .unwrap_or(0),
            is_playing,
            volume: self.volume,
            path: public_deck.map(|deck| deck.loaded_path.clone()),
            error: None,
        }
    }

    fn clear_pending_playback_state(&mut self) {
        self.pending_playback_state = None;
        super::notify_playback_state_changed();
    }

    fn mark_track_ended(&mut self, path: &str) {
        if self.public_path() == Some(path) {
            self.pending_playback_state = Some("ENDED".to_string());
            super::notify_playback_state_changed();
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
        // Only apply immediately if no volume fade is active
        // (In a more complex impl, we'd adjust the target of the active fade)
        if let Some(current) = self.current_deck.as_ref() {
            current.apply_master_volume(self.volume);
        }
        if let Some(incoming) = self.incoming_deck.as_ref() {
            incoming.apply_master_volume(self.volume);
        }
    }

    fn start_volume_fade(&mut self, from: f32, to: f32, duration: Duration, on_complete: bool) {
        self.volume_fade_generation = self.volume_fade_generation.wrapping_add(1);
        let generation = self.volume_fade_generation;
        let master_volume_on_start = self.volume;

        thread::spawn(move || {
            drive_volume_fade(
                generation,
                from,
                to,
                duration,
                master_volume_on_start,
                on_complete,
            );
        });
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

    fn poll_output_device(&mut self) {
        let current_default_device = rodio::cpal::default_host().default_output_device();
        let current_name = current_default_device.as_ref().map(describe_output_device);

        if self.active_output_device_name == current_name && self.sink.is_some() {
            return;
        }

        info!(
            "[AudioDeviceMonitor] Output device change detected: {:?} -> {:?}",
            self.active_output_device_name, current_name
        );

        let was_playing = self.any_deck_playing();
        let pos = self.public_position();
        let path = self.public_path().map(str::to_string);

        // Clear current output
        self.sink = None;
        self.active_output_device_name = None;
        if let Some(d) = self.current_deck.take() {
            d.clear();
        }
        if let Some(d) = self.incoming_deck.take() {
            d.clear();
        }

        // Attempt to open new output
        if current_name.is_some() {
            if let Ok((new_sink, name)) = Self::open_current_default_output() {
                self.sink = Some(new_sink);
                self.active_output_device_name = Some(name);
                if let Some(p) = path {
                    info!("[AudioDeviceMonitor] Restoring playback to {}", p);
                    let _ = self.replace_current_from_path(&p, pos, was_playing);
                }
            }
        }
    }

    fn dispose_audio(&mut self) {
        self.transition_generation = self.transition_generation.wrapping_add(1);
        self.pause_fade_in_progress = false;
        self.clear_pending_playback_state();
        if let Some(incoming) = self.incoming_deck.take() {
            incoming.clear();
        }
        if let Some(current) = self.current_deck.take() {
            current.clear();
        }
        self.active_output_device_name = None;
        self.sink = None;
        self.cached_path = None;
        self.cached_pcm = None;
        self.cached_channels = 0;
        self.cached_sample_rate = 0;
        self.pending_edit = None;
        self.equalizer = EqualizerShared::new(EqualizerConfig::default());
        self.last_decode_engine = None;
    }

    fn prepare_for_file_write(&mut self) -> Result<(), String> {
        let (path, pos, was_playing, gain) = {
            let deck = self
                .public_deck()
                .ok_or_else(|| "no audio is currently loaded".to_string())?;
            (
                deck.loaded_path.clone(),
                self.public_position(),
                deck.is_playing(),
                deck.gain,
            )
        };

        self.pending_edit = Some(PendingEdit {
            path: path.clone(),
            position: pos,
            was_playing,
            gain,
        });

        info!(
            "[PlayerController] Preparing for file write. Releasing handle for: {}",
            path
        );

        self.transition_generation = self.transition_generation.wrapping_add(1);
        if let Some(incoming) = self.incoming_deck.take() {
            incoming.clear();
        }
        if let Some(current) = self.current_deck.take() {
            current.clear();
        }

        Ok(())
    }

    fn finish_file_write(&mut self) -> Result<(), String> {
        let edit = self
            .pending_edit
            .take()
            .ok_or_else(|| "no pending edit state found".to_string())?;

        info!(
            "[PlayerController] File write finished. Restoring playback for: {}",
            edit.path
        );

        let deck =
            self.open_deck_from_path(&edit.path, edit.position, edit.was_playing, edit.gain)?;
        self.current_deck = Some(deck);
        self.clear_pending_playback_state();

        if self.public_path() != Some(&edit.path) {
            self.warm_waveform_cache_for_public_path();
        }

        Ok(())
    }
}

fn describe_output_device(device: &rodio::cpal::Device) -> String {
    format!("{:?}", device.id())
}

fn start_default_output_monitor() {
    DEFAULT_OUTPUT_MONITOR.get_or_init(|| {
        thread::spawn(|| loop {
            thread::sleep(DEFAULT_OUTPUT_POLL_INTERVAL);

            if let Ok(mut c) = controller().lock() {
                c.poll_output_device();
            }
        });
    });
}

pub(crate) fn snapshot_playback_state() -> PlaybackState {
    controller()
        .lock()
        .map(|c| c.playback_state_snapshot())
        .unwrap_or(PlaybackState {
            playback_state: None,
            position_ms: 0,
            duration_ms: 0,
            is_playing: false,
            volume: 1.0,
            path: None,
            error: None,
        })
}

pub(super) fn _snapshot_loaded_path() -> Option<String> {
    controller()
        .lock()
        .ok()
        .and_then(|c| c.public_path().map(str::to_string))
}

pub fn get_audio_pcm(path: Option<String>, sample_stride: usize) -> Result<Vec<f32>, String> {
    let use_cache = sample_stride == 0;
    let (target_path, verify_loaded_path) = {
        let c = controller()
            .lock()
            .map_err(|_| "player lock poisoned".to_string())?;

        match path {
            Some(ref explicit_path) if explicit_path.trim().is_empty() => {
                return Err("path is empty".to_string());
            }
            Some(explicit_path) => {
                if use_cache && c.cached_path.as_deref() == Some(explicit_path.as_str()) {
                    if let Some(cached) = c.cached_pcm.as_ref() {
                        return Ok((**cached).clone());
                    }
                }
                (explicit_path, false)
            }
            None => {
                let Some(public_path) = c.public_path().map(str::to_string) else {
                    return Err("no audio is currently loaded".to_string());
                };

                if use_cache && c.cached_path.as_deref() == Some(public_path.as_str()) {
                    if let Some(cached) = c.cached_pcm.as_ref() {
                        return Ok((**cached).clone());
                    }
                }

                (public_path, true)
            }
        }
    };

    let mut source = CoreAudioSource::open(&target_path)
        .map_err(|e| format!("open audio source failed: {}", e))?;
    let channels = source.channels() as usize;
    let sample_rate = source.sample_rate();
    let mut pcm = Vec::new();
    let sample_stride = sample_stride.max(1);
    if sample_stride <= 1 {
        for sample in source {
            pcm.push(sample);
        }
    } else {
        let frame_size = 1024;
        let mut count = 0;
        'outer: loop {
            let should_read = count % sample_stride == 0;
            count += 1;
            if should_read {
                for _ in 0..frame_size {
                    for _ in 0..channels {
                        if let Some(s) = source.next() {
                            pcm.push(s);
                        } else {
                            break 'outer;
                        }
                    }
                }
            } else {
                for _ in 0..frame_size {
                    for _ in 0..channels {
                        if source.next().is_none() {
                            break 'outer;
                        }
                    }
                }
            }
        }
    }

    if verify_loaded_path {
        let current_loaded_path = controller()
            .lock()
            .map_err(|_| "player lock poisoned".to_string())?
            .public_path()
            .map(str::to_string);

        if current_loaded_path.as_deref() != Some(target_path.as_str()) {
            return Err("loaded audio changed during PCM extraction, please retry".to_string());
        }
    }

    if use_cache {
        if let Ok(mut c) = controller().lock() {
            if c.public_path() == Some(target_path.as_str()) {
                c.cached_path = Some(target_path);
                c.cached_pcm = Some(Arc::new(pcm.clone()));
                c.cached_channels = channels;
                c.cached_sample_rate = sample_rate;
            }
        }
    }

    Ok(pcm)
}

pub fn get_audio_waveform(
    path: Option<String>,
    expected_chunks: usize,
    sample_stride: usize,
) -> Result<Vec<f64>, String> {
    if expected_chunks == 0 {
        return Ok(Vec::new());
    }

    let pcm = get_audio_pcm(path.clone(), sample_stride)?;
    if pcm.is_empty() {
        return Ok(Vec::new());
    }

    let channels = get_audio_pcm_channel_count(path)? as usize;
    let mono = mix_to_mono_samples(&pcm, channels);
    if mono.is_empty() {
        return Ok(vec![0.0; expected_chunks]);
    }

    Ok(reduce_waveform_chunks(&mono, expected_chunks)
        .into_iter()
        .map(round_waveform_precision)
        .collect())
}

fn mix_to_mono_samples(pcm: &[f32], channels: usize) -> Vec<f64> {
    let safe_channels = channels.max(1);
    if safe_channels == 1 {
        return pcm.iter().map(|sample| *sample as f64).collect();
    }

    let frame_count = pcm.len() / safe_channels;
    let mut out = vec![0.0; frame_count];

    for frame in 0..frame_count {
        let base = frame * safe_channels;
        let mut sum = 0.0;
        for channel in 0..safe_channels {
            sum += pcm[base + channel] as f64;
        }
        out[frame] = sum / safe_channels as f64;
    }

    out
}

fn reduce_waveform_chunks(samples: &[f64], expected_chunks: usize) -> Vec<f64> {
    let mut out = vec![0.0; expected_chunks];
    if samples.is_empty() {
        return out;
    }

    let window_count = cmp::max(
        expected_chunks,
        cmp::min(
            samples.len(),
            expected_chunks.saturating_mul(WAVEFORM_RMS_WINDOWS_PER_CHUNK),
        ),
    );
    let mut envelope = vec![0.0; window_count];

    for window in 0..window_count {
        let start = (window * samples.len()) / window_count;
        let end = ((window + 1) * samples.len()) / window_count;
        if end <= start {
            continue;
        }
        envelope[window] = compute_rms(samples, start, end);
    }

    for chunk in 0..expected_chunks {
        let start = (chunk * window_count) / expected_chunks;
        let end = ((chunk + 1) * window_count) / expected_chunks;
        let mut max_value = 0.0;
        for value in &envelope[start..end] {
            if *value > max_value {
                max_value = *value;
            }
        }
        out[chunk] = max_value.clamp(0.0, 1.0);
    }

    out
}

fn compute_rms(samples: &[f64], start: usize, end: usize) -> f64 {
    let mut sum = 0.0;
    for sample in &samples[start..end] {
        sum += sample * sample;
    }
    (sum / (end - start) as f64).sqrt()
}

fn round_waveform_precision(value: f64) -> f64 {
    (value * WAVEFORM_PRECISION_SCALE).round() / WAVEFORM_PRECISION_SCALE
}

pub fn get_audio_pcm_channel_count(path: Option<String>) -> Result<i32, String> {
    let target_path = {
        let c = controller()
            .lock()
            .map_err(|_| "player lock poisoned".to_string())?;

        match path {
            Some(ref explicit_path) if explicit_path.trim().is_empty() => {
                return Err("path is empty".to_string());
            }
            Some(explicit_path) => {
                if c.cached_path.as_deref() == Some(explicit_path.as_str()) && c.cached_channels > 0
                {
                    return Ok(c.cached_channels as i32);
                }
                explicit_path
            }
            None => {
                let Some(public_path) = c.public_path().map(str::to_string) else {
                    return Err("no audio is currently loaded".to_string());
                };

                if c.cached_path.as_deref() == Some(public_path.as_str()) && c.cached_channels > 0 {
                    return Ok(c.cached_channels as i32);
                }

                public_path
            }
        }
    };

    let source = CoreAudioSource::open(&target_path)
        .map_err(|e| format!("open audio source failed: {}", e))?;
    Ok(source.channels() as i32)
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

fn drive_volume_fade(
    generation: u64,
    from: f32,
    to: f32,
    duration: Duration,
    _base_volume: f32,
    pause_on_complete: bool,
) {
    let steps =
        ((duration.as_millis() / CROSSFADE_TICK_INTERVAL.as_millis().max(1)).max(1)) as usize;

    for step in 1..=steps {
        thread::sleep(CROSSFADE_TICK_INTERVAL);

        let Ok(mut c) = controller().lock() else {
            return;
        };
        if c.volume_fade_generation != generation {
            return;
        }

        let progress = step as f32 / steps as f32;
        let current_gain = from + (to - from) * progress;
        let master_volume = c.volume;

        if let Some(deck) = c.current_deck.as_mut() {
            deck.gain = current_gain;
            deck.apply_master_volume(master_volume);
        }
    }

    if pause_on_complete {
        if let Ok(mut c) = controller().lock() {
            if c.volume_fade_generation == generation {
                let master_volume = c.volume;
                c.pause_all();
                c.pause_fade_in_progress = false;
                if let Some(deck) = c.current_deck.as_mut() {
                    deck.gain = 1.0;
                    deck.apply_master_volume(master_volume);
                }
            }
        }
    }
}

pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
    info!("[AudioDeviceMonitor] init_app called, starting monitor thread...");
    start_default_output_monitor();

    if let Ok(mut c) = controller().lock() {
        let _ = c.ensure_audio_output();
        info!(
            "[AudioDeviceMonitor] initial audio output ensured, sink={}",
            c.sink.is_some()
        );
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
    c.clear_pending_playback_state();
    let duration = Duration::from_millis(duration_ms.max(0) as u64);
    c.start_crossfade(&path, duration)
}

pub fn play_audio(fade_duration_ms: i64) -> Result<(), String> {
    let mut c = controller()
        .lock()
        .map_err(|_| "player lock poisoned".to_string())?;
    if c.public_deck().is_none() {
        return Err("player is not initialized".to_string());
    }

    c.pause_fade_in_progress = false;
    c.clear_pending_playback_state();
    let duration = Duration::from_millis(fade_duration_ms.max(0) as u64);
    if !duration.is_zero() {
        let master_volume = c.volume;
        c.play_all();
        if let Some(deck) = c.current_deck.as_mut() {
            deck.gain = 0.0;
            deck.apply_master_volume(master_volume);
        }
        c.start_volume_fade(0.0, 1.0, duration, false);
    } else {
        c.play_all();
    }
    Ok(())
}

pub fn pause_audio(fade_duration_ms: i64) -> Result<(), String> {
    let mut c = controller()
        .lock()
        .map_err(|_| "player lock poisoned".to_string())?;
    if c.public_deck().is_none() {
        return Err("player is not initialized".to_string());
    }

    let duration = Duration::from_millis(fade_duration_ms.max(0) as u64);
    if !duration.is_zero() {
        c.pause_fade_in_progress = true;
        c.start_volume_fade(1.0, 0.0, duration, true);
    } else {
        c.pause_fade_in_progress = false;
        c.pause_all();
    }
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
    c.clear_pending_playback_state();

    let target_ms = position_ms.max(0) as u64;
    let mut target = Duration::from_millis(target_ms);
    let Some(current) = c.current_deck.as_mut() else {
        return Err("audio is not loaded".to_string());
    };

    if !current.loaded_duration.is_zero() {
        target = target.min(current.loaded_duration);
    }

    let seek_result = current.player.try_seek(target);
    if seek_result.is_ok() {
        current.source_start_offset = Duration::ZERO;
        clear_fft_buffer(&current.latest_fft);
        return Ok(());
    }

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

pub fn get_audio_equalizer_config() -> EqualizerConfig {
    controller()
        .lock()
        .map(|c| c.equalizer.current_config())
        .unwrap_or_default()
}

pub fn set_audio_equalizer_config(config: EqualizerConfig) -> Result<(), String> {
    let c = controller()
        .lock()
        .map_err(|_| "player lock poisoned".to_string())?;

    c.equalizer.set_config(config);
    Ok(())
}

pub fn dispose_audio() -> Result<(), String> {
    let mut c = controller()
        .lock()
        .map_err(|_| "player lock poisoned".to_string())?;

    c.dispose_audio();
    Ok(())
}

pub fn is_audio_playing() -> bool {
    if let Ok(c) = controller().lock() {
        return c.any_deck_playing();
    }
    false
}

pub fn get_audio_duration_ms() -> i64 {
    if let Ok(c) = controller().lock() {
        if let Some(deck) = c.public_deck() {
            return deck.loaded_duration.as_millis().min(i64::MAX as u128) as i64;
        }
    }
    0
}

pub fn get_audio_position_ms() -> i64 {
    if let Ok(c) = controller().lock() {
        return c.public_position().as_millis().min(i64::MAX as u128) as i64;
    }
    0
}

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

pub fn get_loaded_audio_path() -> Option<String> {
    if let Ok(c) = controller().lock() {
        return c.public_path().map(str::to_string);
    }
    None
}

pub fn get_audio_decode_engine() -> String {
    if let Ok(c) = controller().lock() {
        if let Some(deck) = c.public_deck() {
            return deck.decode_engine.clone();
        }
        if let Some(engine) = c.last_decode_engine.as_ref() {
            return engine.clone();
        }
    }
    "unknown".to_string()
}

pub fn handle_device_changed() -> Result<(), String> {
    // Legacy stub: device switching is now fully handled by internal periodic polling in Rust.
    Ok(())
}

pub fn prepare_for_file_write() -> Result<(), String> {
    let mut c = controller()
        .lock()
        .map_err(|_| "player lock poisoned".to_string())?;
    c.prepare_for_file_write()
}

pub fn finish_file_write() -> Result<(), String> {
    let mut c = controller()
        .lock()
        .map_err(|_| "player lock poisoned".to_string())?;
    c.finish_file_write()
}
