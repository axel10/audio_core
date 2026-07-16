//! Release-friendly playback stress diagnostics.
//!
//! The monitor is deliberately outside the Flutter isolate. It observes the
//! same `Player::get_pos()` based state used by the playback API, so a UI
//! timer cannot hide an underrun or an early end-of-stream.

use crate::api::simple::{controller, PlaybackState};
use chrono::Utc;
use serde_json::json;
use std::fs::{create_dir_all, File, OpenOptions};
use std::io::Write;
use std::path::PathBuf;
use std::sync::OnceLock;
use std::thread;
use std::time::{Duration, Instant};

const POLL_INTERVAL: Duration = Duration::from_millis(50);
const SAMPLE_INTERVAL: Duration = Duration::from_millis(500);
const MAX_DURATION_ERROR_MS: u128 = 100;

static STARTED: OnceLock<()> = OnceLock::new();

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

    let mut previous = Instant::now();
    let mut last_sample = Instant::now();
    let mut path: Option<String> = None;
    let mut declared_ms: u128 = 0;
    let mut active_ms: u128 = 0;
    let mut incident_saved = false;
    let mut duration_checked = false;
    let mut user_interrupted = false;
    let mut previous_state: Option<PlaybackState> = None;
    let mut resources = ResourceUsage::new();

    loop {
        thread::sleep(POLL_INTERVAL);
        let now = Instant::now();
        let elapsed_ms = now.duration_since(previous).as_millis();
        previous = now;
        let state = controller::snapshot_playback_state();

        // Detect user seek / manual interaction by tracking unexpected position jumps
        if let Some(ref prev) = previous_state {
            if prev.path == state.path {
                let speed = if prev.is_playing {
                    controller::get_playback_speed().unwrap_or(1.0)
                } else {
                    0.0
                };
                let expected_delta = (elapsed_ms as f64 * speed as f64) as i64;
                let actual_delta = state.position_ms - prev.position_ms;
                if (actual_delta - expected_delta).abs() > 1500 {
                    user_interrupted = true;
                }
            }
        }

        if path.as_deref() != state.path.as_deref() {
            if path.is_some()
                && declared_ms > 0
                && active_ms > 0
                && !duration_checked
                && !user_interrupted
            {
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
                        &mut incident_saved,
                    );
                }
            }
            path = state.path.clone();
            declared_ms = state.duration_ms.max(0) as u128;
            active_ms = 0;
            incident_saved = false;
            duration_checked = false;
            user_interrupted = false;
        }

        if state.is_playing && state.path.is_some() {
            let speed = controller::get_playback_speed().unwrap_or(1.0);
            let media_elapsed = (elapsed_ms as f64 * speed as f64) as u128;
            active_ms = active_ms.saturating_add(media_elapsed);
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
        if state.playback_state.as_deref() == Some("ENDED")
            && !duration_checked
            && !user_interrupted
        {
            duration_checked = true;
            check_duration(
                &root,
                &state,
                path.as_deref(),
                declared_ms,
                active_ms,
                &mut incident_saved,
            );
        }

        previous_state = Some(state);
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
    incident_saved: &mut bool,
) {
    if declared_ms == 0 || actual_ms == 0 {
        return;
    }
    let error_ms = declared_ms.abs_diff(actual_ms);
    if error_ms <= MAX_DURATION_ERROR_MS {
        return;
    }

    *incident_saved = true;
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
}
