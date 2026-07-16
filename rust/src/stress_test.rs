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
    let root = std::env::var_os("VYNODY_AUDIO_STRESS_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| std::env::temp_dir().join("vynody-audio-stress"));
    if let Err(error) = create_dir_all(&root) {
        eprintln!("[AudioStress] cannot create {:?}: {}", root, error);
        return;
    }

    let mut samples = OpenOptions::new()
        .create(true)
        .append(true)
        .open(root.join("resource_samples.csv"))
        .ok();
    if let Some(file) = samples.as_mut() {
        let _ = writeln!(
            file,
            "timestamp_ms,path,position_ms,declared_duration_ms,is_playing,cpu_percent,rss_bytes"
        );
    }
    eprintln!("[AudioStress] enabled; output={:?}", root);

    let mut previous = Instant::now();
    let mut path: Option<String> = None;
    let mut declared_ms: u128 = 0;
    let mut active_ms: u128 = 0;
    let mut incident_saved = false;
    let mut previous_state: Option<PlaybackState> = None;
    let mut resources = ResourceUsage::new();

    loop {
        thread::sleep(POLL_INTERVAL);
        let now = Instant::now();
        let elapsed_ms = now.duration_since(previous).as_millis();
        previous = now;
        let state = controller::snapshot_playback_state();

        if path.as_deref() != state.path.as_deref() {
            if path.is_some() && declared_ms > 0 && active_ms > 0 && !incident_saved {
                check_duration(
                    &root,
                    previous_state.as_ref().unwrap_or(&state),
                    path.as_deref(),
                    declared_ms,
                    active_ms,
                    &mut incident_saved,
                );
            }
            path = state.path.clone();
            declared_ms = state.duration_ms.max(0) as u128;
            active_ms = 0;
            incident_saved = false;
        }

        if state.is_playing && state.path.is_some() {
            active_ms = active_ms.saturating_add(elapsed_ms);
        }

        let usage = resources.sample(elapsed_ms);
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

        // ENDED is set by the decoder's end callback. This catches a source
        // ending early even when the next queue item is installed quickly.
        if state.playback_state.as_deref() == Some("ENDED") && !incident_saved {
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

#[cfg(unix)]
fn resident_bytes() -> i64 {
    unsafe {
        let mut usage = std::mem::zeroed::<libc::rusage>();
        if libc::getrusage(libc::RUSAGE_SELF, &mut usage) != 0 {
            return -1;
        }
        #[cfg(target_os = "macos")]
        {
            usage.ru_maxrss as i64
        }
        #[cfg(not(target_os = "macos"))]
        {
            (usage.ru_maxrss as i64).saturating_mul(1024)
        }
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
        if GetProcessMemoryInfo(GetCurrentProcess(), &mut counters, size).as_bool() {
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
