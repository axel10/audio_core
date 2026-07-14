pub mod audio_fingerprint;
#[cfg(any(target_os = "windows", target_os = "linux"))]
pub mod controller;
#[cfg(any(target_os = "windows", target_os = "linux"))]
pub mod equalizer;
#[cfg(any(target_os = "windows", target_os = "linux"))]
pub mod fft;

pub mod metadata;
pub mod palette;

use super::audio_converter;
use std::path::Path;

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
    use ffmpeg_core::AudioSource;
    use std::cmp;
    use std::path::Path;

    const WAVEFORM_RMS_WINDOWS_PER_CHUNK: usize = 8;
    const WAVEFORM_PRECISION_SCALE: f64 = 10000.0;

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
                fade_on_switch: true,
                fade_on_pause_resume: true,
                duration_ms: 250,
                mode: FadeMode::Crossfade,
            }
        }
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
    pub fn play_audio(_fade_duration_ms: i64) -> Result<(), String> {
        Ok(())
    }
    pub fn pause_audio(_fade_duration_ms: i64) -> Result<(), String> {
        Ok(())
    }
    pub fn toggle_audio() -> Result<bool, String> {
        Ok(false)
    }
    pub fn seek_audio_ms(_position_ms: i64) -> Result<(), String> {
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
    pub fn get_audio_pcm_channel_count(_path: Option<String>) -> Result<i32, String> {
        let target_path = parse_target_path(_path, "path is required for channel count")?;
        let source = AudioSource::open(Path::new(&target_path))
            .map_err(|e| format!("open audio source failed: {e}"))?;
        Ok(source.channels() as i32)
    }
    pub fn is_audio_playing() -> bool {
        false
    }
    pub fn get_loaded_audio_path() -> Option<String> {
        None
    }
    pub fn get_audio_decode_engine() -> String {
        "unknown".to_string()
    }
    pub fn get_latest_fft() -> Vec<f32> {
        vec![]
    }
    pub fn get_audio_pcm(path: Option<String>, sample_stride: usize) -> Result<Vec<f32>, String> {
        let target_path = parse_target_path(path, "path is required for PCM extraction")?;
        read_audio_pcm(&target_path, sample_stride)
    }
    fn get_audio_waveform_fallback_with_pcm(
        pcm: Vec<f32>,
        channels: usize,
        expected_chunks: usize,
    ) -> Result<Vec<f64>, String> {
        if pcm.is_empty() {
            return Ok(Vec::new());
        }
        let mono = mix_to_mono_samples(&pcm, channels);
        if mono.is_empty() {
            return Ok(vec![0.0; expected_chunks]);
        }
        Ok(reduce_waveform_chunks(&mono, expected_chunks)
            .into_iter()
            .map(round_waveform_precision)
            .collect())
    }

    pub fn get_audio_waveform(
        path: Option<String>,
        expected_chunks: usize,
        sample_stride: usize,
    ) -> Result<Vec<f64>, String> {
        if expected_chunks == 0 {
            return Ok(Vec::new());
        }

        let target_path = match path {
            Some(path) if path.trim().is_empty() => {
                return Err("path is empty".to_string());
            }
            Some(path) => path,
            None => return Err("path is required when no audio is loaded".to_string()),
        };

        let mut source = AudioSource::open(Path::new(&target_path))
            .map_err(|e| format!("open audio source failed: {}", e))?;
        let channels = source.channels() as usize;
        let sample_rate = source.sample_rate();
        if channels == 0 || sample_rate == 0 {
            return Err("invalid audio source".to_string());
        }

        let duration_secs = source.total_duration().map(|d| d.as_secs_f64()).unwrap_or(0.0);
        if duration_secs <= 0.0 {
            // Fallback: decode everything from source
            let mut pcm = Vec::new();
            let stride = sample_stride.max(1);
            if stride <= 1 {
                for sample in source {
                    pcm.push(sample);
                }
            } else {
                let frames_per_window = 1024usize;
                let mut window_index = 0usize;
                let mut done = false;
                while !done {
                    let keep_window = window_index % stride == 0;
                    window_index = window_index.saturating_add(1);
                    for _ in 0..frames_per_window {
                        for _ in 0..channels {
                            match source.next() {
                                Some(sample) if keep_window => pcm.push(sample),
                                Some(_) => {}
                                None => {
                                    done = true;
                                    break;
                                }
                            }
                        }
                        if done {
                            break;
                        }
                    }
                }
            }
            return get_audio_waveform_fallback_with_pcm(pcm, channels, expected_chunks);
        }

        let estimated_total_frames = (duration_secs * sample_rate as f64).round() as usize;
        let stride = sample_stride.max(1);

        let estimated_total_mono_samples = if stride <= 1 {
            estimated_total_frames
        } else {
            let total_blocks = estimated_total_frames / 1024;
            let kept_blocks = (total_blocks + stride - 1) / stride;
            kept_blocks * 1024
        };

        if estimated_total_mono_samples == 0 {
            return Ok(vec![0.0; expected_chunks]);
        }

        let mut window_count = expected_chunks.saturating_mul(WAVEFORM_RMS_WINDOWS_PER_CHUNK);
        if estimated_total_mono_samples < window_count {
            window_count = expected_chunks.max(estimated_total_mono_samples);
        }

        let mut window_sum_sq = vec![0.0; window_count];
        let mut window_sample_counts = vec![0; window_count];

        let mut mono_sample_idx = 0;
        let mut frame_buf = vec![0.0f32; channels];

        if stride <= 1 {
            loop {
                let mut got_frame = true;
                for c in 0..channels {
                    if let Some(s) = source.next() {
                        frame_buf[c] = s;
                    } else {
                        got_frame = false;
                        break;
                    }
                }
                if !got_frame {
                    break;
                }

                let mut sum = 0.0;
                for &s in &frame_buf {
                    sum += s as f64;
                }
                let mono = sum / channels as f64;

                let w = (mono_sample_idx * window_count) / estimated_total_mono_samples;
                let w = w.min(window_count - 1);

                window_sum_sq[w] += mono * mono;
                window_sample_counts[w] += 1;

                mono_sample_idx += 1;
            }
        } else {
            let mut block_idx = 0usize;
            let mut done = false;
            while !done {
                let keep_block = block_idx % stride == 0;
                block_idx += 1;

                for _ in 0..1024 {
                    let mut got_frame = true;
                    for c in 0..channels {
                        if let Some(s) = source.next() {
                            frame_buf[c] = s;
                        } else {
                            got_frame = false;
                            break;
                        }
                    }
                    if !got_frame {
                        done = true;
                        break;
                    }

                    if keep_block {
                        let mut sum = 0.0;
                        for &s in &frame_buf {
                            sum += s as f64;
                        }
                        let mono = sum / channels as f64;

                        let w = (mono_sample_idx * window_count) / estimated_total_mono_samples;
                        let w = w.min(window_count - 1);

                        window_sum_sq[w] += mono * mono;
                        window_sample_counts[w] += 1;

                        mono_sample_idx += 1;
                    }
                }
            }
        }

        let mut envelope = vec![0.0; window_count];
        for w in 0..window_count {
            let count = window_sample_counts[w];
            if count > 0 {
                envelope[w] = (window_sum_sq[w] / count as f64).sqrt();
            }
        }

        let mut out = vec![0.0; expected_chunks];
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

        Ok(out.into_iter().map(round_waveform_precision).collect())
    }
    pub fn set_audio_equalizer_config(_config: EqualizerConfig) -> Result<(), String> {
        Ok(())
    }
    pub fn get_audio_equalizer_config() -> EqualizerConfig {
        EqualizerConfig::default()
    }
    pub fn set_playback_speed(_speed: f32) -> Result<(), String> {
        Ok(())
    }
    pub fn get_playback_speed() -> Result<f32, String> {
        Ok(1.0)
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

    fn parse_target_path(path: Option<String>, empty_error: &str) -> Result<String, String> {
        match path {
            Some(path) if path.trim().is_empty() => Err("path is empty".to_string()),
            Some(path) => Ok(path),
            None => Err(empty_error.to_string()),
        }
    }

    fn read_audio_pcm(path: &str, sample_stride: usize) -> Result<Vec<f32>, String> {
        let mut source =
            AudioSource::open(Path::new(path)).map_err(|e| format!("open audio source failed: {e}"))?;
        let channels = source.channels() as usize;
        let sample_rate = source.sample_rate();
        if channels == 0 || sample_rate == 0 {
            return Err("invalid audio source".to_string());
        }

        let stride = sample_stride.max(1);
        let mut pcm = Vec::new();
        if stride <= 1 {
            for sample in &mut source {
                pcm.push(sample);
            }
            return Ok(pcm);
        }

        let frames_per_window = 1024usize;
        let mut window_index = 0usize;
        let mut done = false;
        while !done {
            let keep_window = window_index.is_multiple_of(stride);
            window_index = window_index.saturating_add(1);
            for _ in 0..frames_per_window {
                for _ in 0..channels {
                    match source.next() {
                        Some(sample) if keep_window => pcm.push(sample),
                        Some(_) => {}
                        None => {
                            done = true;
                            break;
                        }
                    }
                }
                if done {
                    break;
                }
            }
        }

        Ok(pcm)
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
    crossfade_to_audio_file, dispose_audio, get_audio_decode_engine, get_audio_duration_ms,
    get_audio_equalizer_config, get_audio_pcm, get_audio_position_ms, get_audio_waveform,
    get_latest_fft, get_loaded_audio_path, init_app, is_audio_playing, load_audio_file,
    pause_audio, play_audio, seek_audio_ms, set_audio_equalizer_config, set_audio_volume,
    set_playback_speed, get_playback_speed, toggle_audio, FadeMode, FadeSettings, PlaybackState,
};
pub use metadata::{
    generate_track_artwork, get_audio_details, get_track_metadata, remove_all_tags,
    update_track_metadata, AudioDetails, TrackArtworkResult, TrackMetadataUpdate, TrackPicture,
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

#[flutter_rust_bridge::frb(sync)]
pub fn get_capabilities() -> String {
    audio_converter::simple::get_capabilities()
}

#[flutter_rust_bridge::frb]
pub fn convert_file_with_progress(request_json: String, progress_sink: StreamSink<String>) {
    audio_converter::simple::convert_file_with_progress(request_json, progress_sink)
}

fn push_state() -> PlaybackState {
    controller::snapshot_playback_state()
}

fn trigger_state_push(
    sink: &StreamSink<PlaybackState, flutter_rust_bridge::for_generated::SseCodec>,
) -> bool {
    sink.add(push_state()).is_ok()
}

#[allow(dead_code)]
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
