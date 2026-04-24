#[cfg(any(target_os = "windows", target_os = "linux"))]
pub mod audio_fingerprint;
#[cfg(any(target_os = "windows", target_os = "linux"))]
pub mod controller;
#[cfg(any(target_os = "windows", target_os = "linux"))]
pub mod equalizer;
#[cfg(any(target_os = "windows", target_os = "linux"))]
pub mod fft;

pub mod metadata;

#[cfg(any(target_os = "ios", target_os = "macos", target_os = "android"))]
pub mod audio_fingerprint {
    pub fn get_audio_fingerprint(_path: String) -> anyhow::Result<String> {
        Err(anyhow::anyhow!(
            "Audio fingerprinting is not supported on this platform"
        ))
    }
}

#[cfg(any(target_os = "ios", target_os = "macos", target_os = "android"))]
pub mod equalizer {
    #[derive(Debug, Clone, Default)]
    pub struct EqualizerConfig {
        pub enabled: bool,
        pub band_count: i32,
        pub preamp_db: f32,
        pub bass_boost_db: f32,
        pub bass_boost_frequency_hz: f32,
        pub bass_boost_q: f32,
        pub band_gains_db: Vec<f32>,
    }
}

#[cfg(any(target_os = "ios", target_os = "macos", target_os = "android"))]
pub mod controller {
    use super::equalizer::EqualizerConfig;

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

    pub fn init_app() {}
    pub fn load_audio_file(_path: String) -> Result<(), String> {
        Ok(())
    }
    pub fn crossfade_to_audio_file(_path: String, _duration_ms: i64) -> Result<(), String> {
        Ok(())
    }
    pub fn play_audio(_fade_ms: i64) -> Result<(), String> {
        Ok(())
    }
    pub fn pause_audio(_fade_ms: i64) -> Result<(), String> {
        Ok(())
    }
    pub fn toggle_audio() -> Result<bool, String> {
        Ok(false)
    }
    pub fn seek_audio_ms(_ms: i64) -> Result<(), String> {
        Ok(())
    }
    pub fn set_audio_volume(_volume: f32) -> Result<(), String> {
        Ok(())
    }
    pub fn get_audio_position_ms() -> i64 {
        0
    }
    pub fn get_audio_duration_ms() -> i64 {
        0
    }
    pub fn is_audio_playing() -> bool {
        false
    }
    pub fn get_loaded_audio_path() -> Option<String> {
        None
    }
    pub fn get_latest_fft() -> Vec<f32> {
        vec![]
    }
    pub fn get_audio_pcm(_path: Option<String>, _stride: usize) -> Result<Vec<f32>, String> {
        Err("Not supported".to_string())
    }
    pub fn set_audio_equalizer_config(_config: EqualizerConfig) -> Result<(), String> {
        Ok(())
    }
    pub fn get_audio_equalizer_config() -> EqualizerConfig {
        EqualizerConfig::default()
    }
    pub fn dispose_audio() -> Result<(), String> {
        Ok(())
    }
    pub fn snapshot_playback_state() -> PlaybackState {
        PlaybackState::default()
    }
    pub fn prepare_for_file_write() -> Result<(), String> {
        Ok(())
    }
    pub fn finish_file_write() -> Result<(), String> {
        Ok(())
    }
    pub fn handle_device_changed() -> Result<(), String> {
        Ok(())
    }
}

#[cfg(any(target_os = "ios", target_os = "macos", target_os = "android"))]
pub mod fft {
    pub const RAW_FFT_BINS: usize = 0;
}

use crate::frb_generated::StreamSink;
use std::sync::{Condvar, Mutex, OnceLock};
use std::thread;
use std::time::Duration;

pub use audio_fingerprint::get_audio_fingerprint;
pub use controller::{
    crossfade_to_audio_file, dispose_audio, get_audio_duration_ms, get_audio_equalizer_config,
    get_audio_pcm, get_audio_position_ms, get_latest_fft, get_loaded_audio_path, init_app,
    is_audio_playing, load_audio_file, pause_audio, play_audio, seek_audio_ms,
    set_audio_equalizer_config, set_audio_volume, toggle_audio, FadeMode, FadeSettings,
    PlaybackState,
};
pub use metadata::{
    generate_track_artwork, get_track_metadata, remove_all_tags, update_track_metadata,
    TrackArtworkResult, TrackMetadataUpdate, TrackPicture,
};

const PLAYBACK_STATE_PUSH_INTERVAL: Duration = Duration::from_millis(500);
static PLAYBACK_STATE_NOTIFY: OnceLock<(Mutex<()>, Condvar)> = OnceLock::new();

fn playback_state_notify_pair() -> &'static (Mutex<()>, Condvar) {
    PLAYBACK_STATE_NOTIFY.get_or_init(|| (Mutex::new(()), Condvar::new()))
}

#[flutter_rust_bridge::frb(sync)]
pub fn greet(name: String) -> String {
    format!("Hello, {name}!")
}

fn push_state() -> PlaybackState {
    controller::snapshot_playback_state()
}

fn trigger_state_push(
    sink: &StreamSink<PlaybackState, flutter_rust_bridge::for_generated::SseCodec>,
) -> bool {
    sink.add(push_state()).is_ok()
}

pub(super) fn notify_playback_state_changed() {
    let (_, cvar) = playback_state_notify_pair();
    cvar.notify_all();
}

#[flutter_rust_bridge::frb(sync)]
pub fn subscribe_playback_state(
    sink: StreamSink<PlaybackState, flutter_rust_bridge::for_generated::SseCodec>,
) {
    thread::spawn(move || {
        let (lock, cvar) = playback_state_notify_pair();
        let mut guard = lock.lock().expect("playback state notify mutex poisoned");

        if !trigger_state_push(&sink) {
            return;
        }

        loop {
            let (next_guard, _) = cvar
                .wait_timeout(guard, PLAYBACK_STATE_PUSH_INTERVAL)
                .expect("playback state notify wait failed");
            guard = next_guard;
            if !trigger_state_push(&sink) {
                break;
            }
        }
    });
}
