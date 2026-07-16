//! Release-friendly playback stress diagnostics.
//!
//! The monitor is deliberately outside the Flutter isolate. It observes the
//! same `Player::get_pos()` based state used by the playback API, so a UI
//! timer cannot hide an underrun or an early end-of-stream.

use crate::api::simple::{controller, PlaybackState};
use chrono::Utc;
use serde::Serialize;
use serde_json::json;
use std::collections::VecDeque;
use std::fs::{create_dir_all, File, OpenOptions};
use std::io::Write;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant};

const POLL_INTERVAL: Duration = Duration::from_millis(50);
const SAMPLE_INTERVAL: Duration = Duration::from_millis(500);
const MAX_DURATION_ERROR_MS: u128 = 100;
const STARTUP_TIMEOUT: Duration = Duration::from_secs(30);
const RING_BUFFER_DURATION: Duration = Duration::from_secs(10);
const POST_INCIDENT_DURATION: Duration = Duration::from_secs(10);
const JUMP_ERROR_MS: i64 = 1500;

static LAST_SEEK: OnceLock<Mutex<SeekMarker>> = OnceLock::new();
static STARTED: OnceLock<()> = OnceLock::new();

#[derive(Clone, Copy)]
struct SeekMarker {
    timestamp_ms: u64,
    target_ms: i64,
}

pub fn notify_seek(target_ms: i64) {
    if let Ok(duration) = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH) {
        let marker = LAST_SEEK.get_or_init(|| {
            Mutex::new(SeekMarker {
                timestamp_ms: 0,
                target_ms: 0,
            })
        });
        if let Ok(mut seek) = marker.lock() {
            seek.timestamp_ms = duration.as_millis() as u64;
            seek.target_ms = target_ms.max(0);
        }
    }
}

pub fn start() {
    if STARTED.set(()).is_err() {
        return;
    }

    thread::Builder::new()
        .name("vynody-audio-stress".to_string())
        .spawn(run)
        .expect("failed to start audio stress monitor");
}

fn run() {
    let requested_root = std::env::var_os("VYNODY_AUDIO_STRESS_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| std::env::temp_dir().join("vynody-audio-stress"));
    let fallback_root = std::env::var_os("HOME")
        .map(PathBuf::from)
        .map(|home| home.join("Library/Containers/app.vynody.player/Data/Library/Application Support/app.vynody.player/logs/audio-stress"));
    let root = match prepare_output_root(&requested_root, fallback_root.as_deref()) {
        Ok(root) => root,
        Err(error) => {
            eprintln!(
                "[AudioStress] cannot create output directory {:?}: {}",
                requested_root, error
            );
            return;
        }
    };

    let mut samples = OpenOptions::new()
        .create(true)
        .append(true)
        .open(root.join("resource_samples.csv"))
        .map_err(|error| {
            eprintln!(
                "[AudioStress] cannot open resource_samples.csv in {:?}: {}",
                root, error
            );
            error
        })
        .ok();
    if let Some(file) = samples.as_mut() {
        let _ = writeln!(
            file,
            "timestamp_ms,path,position_ms,declared_duration_ms,is_playing,cpu_percent,rss_bytes"
        );
    }
    eprintln!("[AudioStress] enabled; output={:?}", root);
    write_summary(&root, &IncidentCounts::default());

    let mut previous = Instant::now();
    let mut last_sample = Instant::now();
    let mut path: Option<String> = None;
    let mut declared_ms: u128 = 0;
    let mut active_ms: u128 = 0;
    let mut duration_checked = false;
    let mut previous_state: Option<PlaybackState> = None;
    let mut resources = ResourceUsage::new();
    let mut samples_ring = VecDeque::new();
    let mut incidents = IncidentCounts::default();
    let mut active_incident: Option<IncidentCapture> = None;
    let started_at = Instant::now();
    let mut saw_playback = false;

    let mut last_position: i64 = 0;
    let mut last_position_change = Instant::now();

    loop {
        thread::sleep(POLL_INTERVAL);
        let now = Instant::now();
        let elapsed_ms = now.duration_since(previous).as_millis();
        previous = now;
        let state = controller::snapshot_playback_state();
        let sample = MonitorSample::from_state(&state, now);
        samples_ring.push_back(sample.clone());
        while samples_ring
            .front()
            .map(|entry: &MonitorSample| now.duration_since(entry.monotonic) > RING_BUFFER_DURATION)
            .unwrap_or(false)
        {
            samples_ring.pop_front();
        }
        if let Some(incident) = active_incident.as_mut() {
            incident.samples.push(sample.clone());
            if now.duration_since(incident.started_at) >= POST_INCIDENT_DURATION {
                incident.finish(&root);
                active_incident = None;
            }
        }
        if state.is_playing && state.path.is_some() {
            saw_playback = true;
        } else if !saw_playback && now.duration_since(started_at) >= STARTUP_TIMEOUT {
            incidents.startup_timeouts += 1;
            let incident = IncidentCapture::start(
                &root,
                "playback_start_timeout",
                &state,
                samples_ring.iter().cloned().collect(),
            );
            active_incident.get_or_insert(incident);
            saw_playback = true;
            write_summary(&root, &incidents);
        }

        // Detect user seek vs unexpected position jumps
        if let Some(ref prev) = previous_state {
            if prev.path == state.path {
                let speed = if prev.is_playing {
                    controller::get_playback_speed().unwrap_or(1.0)
                } else {
                    0.0
                };
                let expected_delta = (elapsed_ms as f64 * speed as f64) as i64;
                let actual_delta = state.position_ms - prev.position_ms;
                let error = actual_delta - expected_delta;
                if is_significant_position_error(error) {
                    let is_seeking_recently = seek_matches_current_position(&state);

                    if is_seeking_recently {
                        // The seek marker is consumed only after the observed
                        // position is close to its requested target.
                    } else {
                        incidents.jumps += 1;
                        if active_incident.is_none() {
                            let incident = IncidentCapture::start(
                                &root,
                                "playback_position_jump",
                                &state,
                                samples_ring.iter().cloned().collect(),
                            );
                            active_incident = Some(incident);
                        }
                        write_summary(&root, &incidents);
                    }
                }
            }
        }

        if path.as_deref() != state.path.as_deref() {
            if path.is_some() && declared_ms > 0 && active_ms > 0 && !duration_checked {
                let reached_end = previous_state
                    .as_ref()
                    .map(|p| (p.position_ms - declared_ms as i64).abs() < 2000)
                    .unwrap_or(false);
                if reached_end {
                    check_duration(
                        &root,
                        previous_state.as_ref().unwrap_or(&state),
                        path.as_deref(),
                        declared_ms,
                        active_ms,
                        &mut incidents,
                    );
                    write_summary(&root, &incidents);
                }
            }
            path = state.path.clone();
            declared_ms = state.duration_ms.max(0) as u128;
            active_ms = 0;
            duration_checked = false;
            last_position = state.position_ms;
            last_position_change = now;
        }

        if state.is_playing && state.path.is_some() {
            let speed = controller::get_playback_speed().unwrap_or(1.0);
            let media_elapsed = (elapsed_ms as f64 * speed as f64) as u128;
            active_ms = active_ms.saturating_add(media_elapsed);

            // Stall detection: position must change while playing local files
            if state.position_ms != last_position {
                last_position = state.position_ms;
                last_position_change = now;
            } else {
                let stall_duration = now.duration_since(last_position_change);
                if stall_duration > Duration::from_secs(3) {
                    let is_near_end =
                        declared_ms > 0 && (state.position_ms - declared_ms as i64).abs() < 1000;
                    let is_seeking_recently = seek_matches_current_position(&state);

                    if !is_near_end && !is_seeking_recently {
                        incidents.stalls += 1;
                        if active_incident.is_none() {
                            let incident = IncidentCapture::start(
                                &root,
                                "playback_stalled",
                                &state,
                                samples_ring.iter().cloned().collect(),
                            );
                            active_incident = Some(incident);
                        }
                        write_summary(&root, &incidents);
                        last_position_change = now;
                    }
                }
            }
        } else {
            // Not playing, reset change time to prevent false positives when paused/loading
            last_position = state.position_ms;
            last_position_change = now;
        }

        let sample_elapsed = now.duration_since(last_sample);
        if sample_elapsed >= SAMPLE_INTERVAL {
            let usage = resources.sample(sample_elapsed.as_millis());
            if let Some(file) = samples.as_mut() {
                let _ = writeln!(
                    file,
                    "{},{},{},{},{},{:.2},{:?}",
                    Utc::now().timestamp_millis(),
                    csv(state.path.as_deref().unwrap_or("")),
                    state.position_ms,
                    state.duration_ms,
                    state.is_playing,
                    usage.cpu_percent,
                    usage.rss_bytes,
                );
                let _ = file.flush();
            }
            last_sample = now;
        }

        // ENDED is set by the decoder's end callback. This catches a source
        // ending early even when the next queue item is installed quickly.
        if state.playback_state.as_deref() == Some("ENDED") && !duration_checked {
            duration_checked = true;
            check_duration(
                &root,
                &state,
                path.as_deref(),
                declared_ms,
                active_ms,
                &mut incidents,
            );
            write_summary(&root, &incidents);
        }

        previous_state = Some(state);
    }
}

#[derive(Clone)]
struct MonitorSample {
    timestamp: String,
    monotonic: Instant,
    path: Option<String>,
    position_ms: i64,
    duration_ms: i64,
    is_playing: bool,
    playback_state: Option<String>,
}

impl MonitorSample {
    fn from_state(state: &PlaybackState, monotonic: Instant) -> Self {
        Self {
            timestamp: Utc::now().to_rfc3339(),
            monotonic,
            path: state.path.clone(),
            position_ms: state.position_ms,
            duration_ms: state.duration_ms,
            is_playing: state.is_playing,
            playback_state: state.playback_state.clone(),
        }
    }

    fn json(&self) -> serde_json::Value {
        json!({
            "timestamp": self.timestamp,
            "path": self.path,
            "position_ms": self.position_ms,
            "duration_ms": self.duration_ms,
            "is_playing": self.is_playing,
            "playback_state": self.playback_state,
        })
    }
}

#[derive(Default, Serialize)]
struct IncidentCounts {
    jumps: u64,
    stalls: u64,
    duration_mismatches: u64,
    startup_timeouts: u64,
}

struct IncidentCapture {
    directory: PathBuf,
    reason: &'static str,
    started_at: Instant,
    samples: Vec<MonitorSample>,
}

impl IncidentCapture {
    fn start(
        root: &PathBuf,
        reason: &'static str,
        state: &PlaybackState,
        samples: Vec<MonitorSample>,
    ) -> Self {
        let directory = root.join(format!(
            "incident-{}",
            Utc::now().format("%Y%m%d-%H%M%S%.3f")
        ));
        let _ = create_dir_all(&directory);
        let initial = json!({
            "captured_at": Utc::now().to_rfc3339(),
            "reason": reason,
            "state_at_detection": state,
            "audio_core": controller::stress_diagnostic_details(),
        });
        if let Ok(mut file) = File::create(directory.join("incident.json")) {
            let _ = serde_json::to_writer_pretty(&mut file, &initial);
            let _ = file.write_all(b"\n");
        }
        eprintln!(
            "[AudioStress][INCIDENT] reason={} path={} directory={:?}",
            reason,
            state.path.as_deref().unwrap_or(""),
            directory
        );
        Self {
            directory,
            reason,
            started_at: Instant::now(),
            samples,
        }
    }

    fn finish(&self, root: &PathBuf) {
        let timeline = json!({
            "reason": self.reason,
            "post_detection_duration_ms": self.started_at.elapsed().as_millis(),
            "samples": self.samples.iter().map(MonitorSample::json).collect::<Vec<_>>(),
        });
        if let Ok(mut file) = File::create(self.directory.join("timeline.json")) {
            let _ = serde_json::to_writer_pretty(&mut file, &timeline);
            let _ = file.write_all(b"\n");
        }
        if let Ok(mut file) = OpenOptions::new()
            .create(true)
            .append(true)
            .open(root.join("incidents.log"))
        {
            let _ = writeln!(
                file,
                "{} reason={} timeline={:?}",
                Utc::now().to_rfc3339(),
                self.reason,
                self.directory.join("timeline.json")
            );
        }
    }
}

fn seek_matches_current_position(state: &PlaybackState) -> bool {
    let Some(marker) = LAST_SEEK.get() else {
        return false;
    };
    let Ok(mut marker) = marker.lock() else {
        return false;
    };
    let Ok(now) = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH) else {
        return false;
    };
    let age_ms = now
        .as_millis()
        .saturating_sub(u128::from(marker.timestamp_ms));
    if age_ms > 2000 {
        return false;
    }
    let close_to_target = (state.position_ms - marker.target_ms).abs() <= 2000;
    if close_to_target || age_ms < 500 {
        marker.timestamp_ms = 0;
        return true;
    }
    false
}

fn is_significant_position_error(error_ms: i64) -> bool {
    error_ms.abs() > JUMP_ERROR_MS
}

fn write_summary(root: &PathBuf, counts: &IncidentCounts) {
    let summary = json!({
        "updated_at": Utc::now().to_rfc3339(),
        "incidents": counts,
        "output": root,
    });
    if let Ok(mut file) = File::create(root.join("stress_summary.json")) {
        let _ = serde_json::to_writer_pretty(&mut file, &summary);
        let _ = file.write_all(b"\n");
    }
}

fn prepare_output_root(
    requested: &PathBuf,
    fallback: Option<&std::path::Path>,
) -> Result<PathBuf, String> {
    if create_dir_all(requested).is_ok() {
        let write_test = requested.join(".write-test");
        if OpenOptions::new()
            .create(true)
            .append(true)
            .open(&write_test)
            .is_ok()
        {
            let _ = std::fs::remove_file(write_test);
            return Ok(requested.clone());
        }
    }

    if let Some(fallback) = fallback {
        create_dir_all(fallback).map_err(|error| error.to_string())?;
        eprintln!(
            "[AudioStress] requested output {:?} is not writable (macOS sandbox?), falling back to {:?}",
            requested, fallback
        );
        return Ok(fallback.to_path_buf());
    }

    Err("requested output is not writable and no fallback is available".to_string())
}

fn check_duration(
    root: &PathBuf,
    state: &PlaybackState,
    path: Option<&str>,
    declared_ms: u128,
    actual_ms: u128,
    incidents: &mut IncidentCounts,
) {
    if declared_ms == 0 || actual_ms == 0 {
        return;
    }
    let error_ms = declared_ms.abs_diff(actual_ms);
    if error_ms <= MAX_DURATION_ERROR_MS {
        return;
    }

    incidents.duration_mismatches += 1;
    let incident_dir = root.join(format!(
        "incident-{}",
        Utc::now().format("%Y%m%d-%H%M%S%.3f")
    ));
    let _ = create_dir_all(&incident_dir);
    let snapshot = json!({
        "captured_at": Utc::now().to_rfc3339(),
        "reason": "playback_duration_mismatch",
        "path": path,
        "declared_duration_ms": declared_ms,
        "actual_playing_elapsed_ms": actual_ms,
        "error_ms": error_ms,
        "playback_state": state,
        "audio_core": controller::stress_diagnostic_details(),
        "process": {
            "pid": std::process::id(),
            "executable": std::env::current_exe().ok(),
            "current_dir": std::env::current_dir().ok(),
            "args": std::env::args().collect::<Vec<_>>(),
            "target_os": std::env::consts::OS,
            "target_arch": std::env::consts::ARCH,
        },
        "environment": {
            "stress_output_dir": std::env::var_os("VYNODY_AUDIO_STRESS_DIR"),
            "rust_log": std::env::var_os("RUST_LOG"),
        },
    });
    if let Ok(mut file) = File::create(incident_dir.join("playback_snapshot.json")) {
        let _ = serde_json::to_writer_pretty(&mut file, &snapshot);
        let _ = file.write_all(b"\n");
    }
    if let Ok(mut file) = OpenOptions::new()
        .create(true)
        .append(true)
        .open(root.join("incidents.log"))
    {
        let _ = writeln!(
            file,
            "{} path={} declared_ms={} actual_ms={} error_ms={} snapshot={:?}",
            Utc::now().to_rfc3339(),
            path.unwrap_or(""),
            declared_ms,
            actual_ms,
            error_ms,
            incident_dir
        );
    }
    eprintln!(
        "[AudioStress][FAIL] path={} declared={}ms actual={}ms error={}ms snapshot={:?}",
        path.unwrap_or(""),
        declared_ms,
        actual_ms,
        error_ms,
        incident_dir
    );
}

#[allow(dead_code)]
fn log_unexpected_jump(
    root: &PathBuf,
    state: &PlaybackState,
    prev_position_ms: i64,
    new_position_ms: i64,
    expected_delta_ms: i64,
    incident_saved: &mut bool,
) {
    *incident_saved = true;
    let incident_dir = root.join(format!(
        "incident-{}",
        Utc::now().format("%Y%m%d-%H%M%S%.3f")
    ));
    let _ = create_dir_all(&incident_dir);
    let actual_delta_ms = new_position_ms - prev_position_ms;
    let deviation_ms = actual_delta_ms - expected_delta_ms;

    let snapshot = json!({
        "captured_at": Utc::now().to_rfc3339(),
        "reason": "playback_position_jump",
        "path": state.path,
        "prev_position_ms": prev_position_ms,
        "new_position_ms": new_position_ms,
        "expected_delta_ms": expected_delta_ms,
        "actual_delta_ms": actual_delta_ms,
        "deviation_ms": deviation_ms,
        "playback_state": state,
        "audio_core": controller::stress_diagnostic_details(),
        "process": {
            "pid": std::process::id(),
            "executable": std::env::current_exe().ok(),
            "current_dir": std::env::current_dir().ok(),
            "args": std::env::args().collect::<Vec<_>>(),
            "target_os": std::env::consts::OS,
            "target_arch": std::env::consts::ARCH,
        },
        "environment": {
            "stress_output_dir": std::env::var_os("VYNODY_AUDIO_STRESS_DIR"),
            "rust_log": std::env::var_os("RUST_LOG"),
        },
    });

    if let Ok(mut file) = File::create(incident_dir.join("playback_snapshot.json")) {
        let _ = serde_json::to_writer_pretty(&mut file, &snapshot);
        let _ = file.write_all(b"\n");
    }
    if let Ok(mut file) = OpenOptions::new()
        .create(true)
        .append(true)
        .open(root.join("incidents.log"))
    {
        let _ = writeln!(
            file,
            "{} path={} type=jump prev_pos={} new_pos={} expected_delta={} actual_delta={} deviation={} snapshot={:?}",
            Utc::now().to_rfc3339(),
            state.path.as_deref().unwrap_or(""),
            prev_position_ms,
            new_position_ms,
            expected_delta_ms,
            actual_delta_ms,
            deviation_ms,
            incident_dir
        );
    }
    eprintln!(
        "[AudioStress][FAIL] path={} type=jump prev_pos={} new_pos={} expected_delta={} actual_delta={} deviation={} snapshot={:?}",
        state.path.as_deref().unwrap_or(""),
        prev_position_ms,
        new_position_ms,
        expected_delta_ms,
        actual_delta_ms,
        deviation_ms,
        incident_dir
    );
}

#[allow(dead_code)]
fn log_playback_stall(
    root: &PathBuf,
    state: &PlaybackState,
    stall_duration: Duration,
    incident_saved: &mut bool,
) {
    *incident_saved = true;
    let incident_dir = root.join(format!(
        "incident-{}",
        Utc::now().format("%Y%m%d-%H%M%S%.3f")
    ));
    let _ = create_dir_all(&incident_dir);

    let snapshot = json!({
        "captured_at": Utc::now().to_rfc3339(),
        "reason": "playback_stalled",
        "path": state.path,
        "position_ms": state.position_ms,
        "stall_duration_ms": stall_duration.as_millis(),
        "playback_state": state,
        "audio_core": controller::stress_diagnostic_details(),
        "process": {
            "pid": std::process::id(),
            "executable": std::env::current_exe().ok(),
            "current_dir": std::env::current_dir().ok(),
            "args": std::env::args().collect::<Vec<_>>(),
            "target_os": std::env::consts::OS,
            "target_arch": std::env::consts::ARCH,
        },
        "environment": {
            "stress_output_dir": std::env::var_os("VYNODY_AUDIO_STRESS_DIR"),
            "rust_log": std::env::var_os("RUST_LOG"),
        },
    });

    if let Ok(mut file) = File::create(incident_dir.join("playback_snapshot.json")) {
        let _ = serde_json::to_writer_pretty(&mut file, &snapshot);
        let _ = file.write_all(b"\n");
    }
    if let Ok(mut file) = OpenOptions::new()
        .create(true)
        .append(true)
        .open(root.join("incidents.log"))
    {
        let _ = writeln!(
            file,
            "{} path={} type=stall pos={} stall_duration_ms={} snapshot={:?}",
            Utc::now().to_rfc3339(),
            state.path.as_deref().unwrap_or(""),
            state.position_ms,
            stall_duration.as_millis(),
            incident_dir
        );
    }
    eprintln!(
        "[AudioStress][FAIL] path={} type=stall pos={} stall_duration_ms={} snapshot={:?}",
        state.path.as_deref().unwrap_or(""),
        state.position_ms,
        stall_duration.as_millis(),
        incident_dir
    );
}

fn csv(value: &str) -> String {
    format!("\"{}\"", value.replace('"', "\"\""))
}

struct Usage {
    cpu_percent: f64,
    rss_bytes: i64,
}

struct ResourceUsage {
    last_cpu_us: u64,
}

impl ResourceUsage {
    fn new() -> Self {
        Self {
            last_cpu_us: process_cpu_us(),
        }
    }

    fn sample(&mut self, elapsed_ms: u128) -> Usage {
        let cpu_us = process_cpu_us();
        let delta = cpu_us.saturating_sub(self.last_cpu_us);
        self.last_cpu_us = cpu_us;
        let cpu_percent = if elapsed_ms == 0 {
            0.0
        } else {
            delta as f64 / (elapsed_ms as f64 * 1000.0) * 100.0
        };
        Usage {
            cpu_percent,
            rss_bytes: resident_bytes(),
        }
    }
}

#[cfg(unix)]
fn process_cpu_us() -> u64 {
    unsafe {
        let mut usage = std::mem::zeroed::<libc::rusage>();
        if libc::getrusage(libc::RUSAGE_SELF, &mut usage) != 0 {
            return 0;
        }
        let user = usage.ru_utime.tv_sec as u64 * 1_000_000 + usage.ru_utime.tv_usec as u64;
        let system = usage.ru_stime.tv_sec as u64 * 1_000_000 + usage.ru_stime.tv_usec as u64;
        user.saturating_add(system)
    }
}

#[cfg(any(target_os = "macos", target_os = "ios"))]
fn resident_bytes() -> i64 {
    #[repr(C)]
    #[derive(Default, Clone, Copy)]
    struct time_value_t {
        seconds: i32,
        microseconds: i32,
    }

    #[repr(C)]
    #[derive(Default, Clone, Copy)]
    struct mach_task_basic_info {
        virtual_size: u64,
        resident_size: u64,
        resident_size_max: u64,
        user_time: time_value_t,
        system_time: time_value_t,
        policy: i32,
        suspend_count: i32,
    }

    extern "C" {
        fn mach_task_self() -> libc::mach_port_t;
    }

    unsafe {
        let mut info = mach_task_basic_info::default();
        let mut count = (std::mem::size_of::<mach_task_basic_info>()
            / std::mem::size_of::<libc::integer_t>())
            as libc::mach_msg_type_number_t;
        let kr = libc::task_info(
            mach_task_self(),
            20, // MACH_TASK_BASIC_INFO
            &mut info as *mut mach_task_basic_info as *mut libc::integer_t,
            &mut count,
        );
        if kr == 0 {
            info.resident_size as i64
        } else {
            -1
        }
    }
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn resident_bytes() -> i64 {
    if let Ok(content) = std::fs::read_to_string("/proc/self/statm") {
        let parts: Vec<&str> = content.split_whitespace().collect();
        if parts.len() >= 2 {
            if let Ok(pages) = parts[1].parse::<i64>() {
                let page_size = unsafe { libc::sysconf(libc::_SC_PAGESIZE) };
                if page_size > 0 {
                    return pages.saturating_mul(page_size as i64);
                }
            }
        }
    }
    -1
}

#[cfg(all(
    unix,
    not(any(
        target_os = "macos",
        target_os = "ios",
        target_os = "linux",
        target_os = "android"
    ))
))]
fn resident_bytes() -> i64 {
    unsafe {
        let mut usage = std::mem::zeroed::<libc::rusage>();
        if libc::getrusage(libc::RUSAGE_SELF, &mut usage) != 0 {
            return -1;
        }
        (usage.ru_maxrss as i64).saturating_mul(1024)
    }
}

#[cfg(windows)]
fn process_cpu_us() -> u64 {
    use windows::Win32::System::Threading::{GetCurrentProcess, GetProcessTimes};
    unsafe {
        let mut creation = std::mem::zeroed();
        let mut exit = std::mem::zeroed();
        let mut kernel = std::mem::zeroed();
        let mut user = std::mem::zeroed();
        if GetProcessTimes(
            GetCurrentProcess(),
            &mut creation,
            &mut exit,
            &mut kernel,
            &mut user,
        )
        .is_err()
        {
            return 0;
        }
        let ticks = |time: windows::Win32::Foundation::FILETIME| {
            (u64::from(time.dwHighDateTime) << 32) | u64::from(time.dwLowDateTime)
        };
        ticks(kernel).saturating_add(ticks(user)) / 10
    }
}

#[cfg(windows)]
fn resident_bytes() -> i64 {
    use windows::Win32::System::ProcessStatus::{GetProcessMemoryInfo, PROCESS_MEMORY_COUNTERS};
    use windows::Win32::System::Threading::GetCurrentProcess;
    unsafe {
        let mut counters = PROCESS_MEMORY_COUNTERS::default();
        let size = std::mem::size_of::<PROCESS_MEMORY_COUNTERS>() as u32;
        if GetProcessMemoryInfo(GetCurrentProcess(), &mut counters, size).is_ok() {
            counters.WorkingSetSize as i64
        } else {
            -1
        }
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn duration_error_uses_strict_100ms_limit() {
        assert_eq!(300_000_u128.abs_diff(299_900), 100);
        assert!(300_000_u128.abs_diff(299_899) > 100);
    }

    #[test]
    fn position_jump_requires_more_than_1500ms_error() {
        assert!(!super::is_significant_position_error(1500));
        assert!(!super::is_significant_position_error(-1500));
        assert!(super::is_significant_position_error(1501));
        assert!(super::is_significant_position_error(-1501));
    }
}
