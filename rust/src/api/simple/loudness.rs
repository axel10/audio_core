use std::path::Path;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Mutex;
use std::time::Instant;

use ebur128::{EbuR128, Mode};
use ffmpeg_core::AudioSource;

const CHUNK_FRAMES: usize = 4096;
const MIN_FINITE_LUFS: f64 = -70.0;
const MIN_FINITE_DBTP: f64 = -120.0;

#[derive(Debug, Clone)]
pub struct TrackLoudnessResult {
    pub path: String,
    pub loudness_lufs: f64,
    pub true_peak: f64,
    pub true_peak_dbtp: f64,
    pub sample_rate: u32,
    pub channels: u16,
    pub duration_ms: u64,
    pub elapsed_ms: u64,
}

#[derive(Debug, Clone)]
pub struct AlbumLoudnessResult {
    pub tracks: Vec<TrackLoudnessResult>,
    pub album_lufs: f64,
    pub album_true_peak: f64,
    pub album_true_peak_dbtp: f64,
    pub total_elapsed_ms: u64,
}

/// Analyzes integrated loudness (LUFS) and true peak for a single audio file.
pub fn analyze_track_loudness(path: String) -> anyhow::Result<TrackLoudnessResult> {
    let (result, _) = analyze_track_internal(&path)?;
    Ok(result)
}

/// Analyzes each track individually and computes the combined album loudness
/// via `EbuR128::loudness_global_multiple`.
///
/// `threads` controls the maximum number of worker threads used to decode and
/// analyze tracks concurrently (defaults to `1` when `None` or `<= 1`).
pub fn analyze_album_loudness(
    paths: Vec<String>,
    threads: Option<u32>,
) -> anyhow::Result<AlbumLoudnessResult> {
    if paths.is_empty() {
        return Err(anyhow::anyhow!("paths must not be empty"));
    }

    let started = Instant::now();
    let worker_count = threads.unwrap_or(1).max(1).min(paths.len() as u32) as usize;
    let mut tracks = Vec::with_capacity(paths.len());
    let mut analyzers = Vec::with_capacity(paths.len());
    let mut album_true_peak = 0.0_f64;

    if worker_count <= 1 {
        for path in &paths {
            let (track, analyzer) = analyze_track_internal(path)?;
            if track.true_peak > album_true_peak {
                album_true_peak = track.true_peak;
            }
            tracks.push(track);
            analyzers.push(analyzer);
        }
    } else {
        let slots: Vec<Mutex<Option<anyhow::Result<(TrackLoudnessResult, EbuR128)>>>> =
            (0..paths.len()).map(|_| Mutex::new(None)).collect();
        let next_index = AtomicUsize::new(0);

        std::thread::scope(|scope| {
            for _ in 0..worker_count {
                scope.spawn(|| loop {
                    let idx = next_index.fetch_add(1, Ordering::Relaxed);
                    if idx >= paths.len() {
                        break;
                    }
                    let res = analyze_track_internal(&paths[idx]);
                    if let Ok(mut guard) = slots[idx].lock() {
                        *guard = Some(res);
                    }
                });
            }
        });

        for slot in slots {
            let res = slot
                .into_inner()
                .map_err(|_| anyhow::anyhow!("loudness worker mutex poisoned"))?
                .ok_or_else(|| anyhow::anyhow!("loudness worker missed track result"))?;
            let (track, analyzer) = res?;
            if track.true_peak > album_true_peak {
                album_true_peak = track.true_peak;
            }
            tracks.push(track);
            analyzers.push(analyzer);
        }
    }

    let raw_album_lufs = EbuR128::loudness_global_multiple(analyzers.iter())
        .map_err(|e| anyhow::anyhow!("ebur128 album loudness failed: {e}"))?;
    let album_lufs = sanitize_lufs(raw_album_lufs);

    Ok(AlbumLoudnessResult {
        tracks,
        album_lufs,
        album_true_peak,
        album_true_peak_dbtp: linear_to_dbtp(album_true_peak),
        total_elapsed_ms: started.elapsed().as_millis() as u64,
    })
}

fn analyze_track_internal(path: &str) -> anyhow::Result<(TrackLoudnessResult, EbuR128)> {
    let started = Instant::now();
    let mut source = AudioSource::open(Path::new(path))
        .map_err(|e| anyhow::anyhow!("failed to open audio '{path}': {e:?}"))?;

    let sample_rate = source.sample_rate();
    let channels = source.channels();
    if sample_rate == 0 || channels == 0 {
        return Err(anyhow::anyhow!(
            "invalid audio format for '{path}': sample_rate={sample_rate}, channels={channels}"
        ));
    }

    let mut analyzer = EbuR128::new(channels as u32, sample_rate, Mode::I | Mode::TRUE_PEAK)
        .map_err(|e| anyhow::anyhow!("ebur128 init failed for '{path}': {e}"))?;

    let channels_usize = channels as usize;
    let chunk_capacity = CHUNK_FRAMES * channels_usize;
    let mut buffer = Vec::with_capacity(chunk_capacity);
    let mut total_samples: u64 = 0;

    for sample in &mut source {
        buffer.push(sample);
        if buffer.len() == chunk_capacity {
            analyzer
                .add_frames_f32(&buffer)
                .map_err(|e| anyhow::anyhow!("ebur128 add_frames_f32 failed: {e}"))?;
            total_samples += buffer.len() as u64;
            buffer.clear();
        }
    }

    if !buffer.is_empty() {
        let usable_len = (buffer.len() / channels_usize) * channels_usize;
        if usable_len > 0 {
            analyzer
                .add_frames_f32(&buffer[..usable_len])
                .map_err(|e| anyhow::anyhow!("ebur128 add_frames_f32 failed: {e}"))?;
            total_samples += usable_len as u64;
        }
    }

    let raw_lufs = analyzer
        .loudness_global()
        .map_err(|e| anyhow::anyhow!("ebur128 loudness_global failed for '{path}': {e}"))?;
    let loudness_lufs = sanitize_lufs(raw_lufs);

    let mut true_peak = 0.0_f64;
    for ch in 0..channels as u32 {
        let ch_peak = analyzer
            .true_peak(ch)
            .map_err(|e| anyhow::anyhow!("ebur128 true_peak({ch}) failed: {e}"))?;
        if ch_peak > true_peak {
            true_peak = ch_peak;
        }
    }

    let total_frames = total_samples / channels as u64;
    let duration_ms = total_frames.saturating_mul(1000) / sample_rate as u64;

    let result = TrackLoudnessResult {
        path: path.to_string(),
        loudness_lufs,
        true_peak,
        true_peak_dbtp: linear_to_dbtp(true_peak),
        sample_rate,
        channels,
        duration_ms,
        elapsed_ms: started.elapsed().as_millis() as u64,
    };

    Ok((result, analyzer))
}

fn sanitize_lufs(value: f64) -> f64 {
    if value.is_finite() {
        value.max(MIN_FINITE_LUFS)
    } else {
        MIN_FINITE_LUFS
    }
}

fn linear_to_dbtp(peak: f64) -> f64 {
    if peak > 0.0 && peak.is_finite() {
        (20.0 * peak.log10()).max(MIN_FINITE_DBTP)
    } else {
        MIN_FINITE_DBTP
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sanitize_handles_non_finite_and_silence() {
        assert_eq!(sanitize_lufs(f64::NEG_INFINITY), MIN_FINITE_LUFS);
        assert_eq!(sanitize_lufs(f64::NAN), MIN_FINITE_LUFS);
        assert_eq!(sanitize_lufs(-14.25), -14.25);
        assert_eq!(linear_to_dbtp(0.0), MIN_FINITE_DBTP);
        assert!((linear_to_dbtp(1.0) - 0.0).abs() < 1e-9);
    }

    #[test]
    fn empty_album_returns_error() {
        assert!(analyze_album_loudness(Vec::new(), None).is_err());
        assert!(analyze_album_loudness(Vec::new(), Some(4)).is_err());
    }

    #[test]
    fn verify_human_album_against_rsgain_benchmark() {
        let dir = Path::new("/Volumes/Untitled/music/human");
        if !dir.exists() {
            return;
        }

        let mut paths: Vec<String> = std::fs::read_dir(dir)
            .expect("read human album dir")
            .filter_map(|entry| entry.ok())
            .map(|entry| entry.path())
            .filter(|p| {
                p.extension().and_then(|e| e.to_str()) == Some("flac")
                    && !p
                        .file_name()
                        .and_then(|n| n.to_str())
                        .unwrap_or("")
                        .starts_with("._")
            })
            .map(|p| p.to_string_lossy().to_string())
            .collect();
        paths.sort();
        assert_eq!(paths.len(), 15);

        let album = analyze_album_loudness(paths, Some(4)).expect("analyze human album");
        for t in &album.tracks {
            let name = Path::new(&t.path)
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or(&t.path);
            println!(
                "Track: {:<48} | LUFS: {:>6.2} | TruePeak: {:.6} ({:>6.2} dBTP) | {} ms",
                name, t.loudness_lufs, t.true_peak, t.true_peak_dbtp, t.elapsed_ms
            );
        }
        println!(
            "Album: LUFS: {:>6.2} | TruePeak: {:.6} ({:>6.2} dBTP) | total {} ms",
            album.album_lufs, album.album_true_peak, album.album_true_peak_dbtp, album.total_elapsed_ms
        );

        // rsgain reference: Album = -8.68 LUFS, TruePeak = 1.235053
        assert!(
            (album.album_lufs - (-8.68)).abs() <= 0.05,
            "album_lufs={} expected ~ -8.68",
            album.album_lufs
        );
        assert!(
            (album.album_true_peak - 1.235053).abs() <= 0.02,
            "album_true_peak={} expected ~ 1.235053",
            album.album_true_peak
        );
    }
}
