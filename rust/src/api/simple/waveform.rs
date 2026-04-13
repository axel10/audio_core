use super::controller;
use std::fs::File;
use std::path::Path;
use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::{DecoderOptions, CODEC_TYPE_NULL};
use symphonia::core::errors::Error as SymphoniaError;
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;

#[derive(Debug, Clone)]
pub struct WaveformChunk {
    pub index: usize,
    pub peak: f32,
}

// A slightly contrasty curve keeps very loud songs from turning into a flat block.
const DISPLAY_GAMMA: f32 = 1.08;
const DISPLAY_FLOOR: f32 = 0.04;
const EPSILON: f32 = 1.0e-6;
const DISPLAY_SCALE_QUANTILE: f32 = 0.92;

fn time_to_chunk(ts: u64, total_ts: u64, expected_chunks: usize) -> usize {
    if expected_chunks == 0 || total_ts == 0 {
        return 0;
    }

    let idx = ((ts as u128 * expected_chunks as u128) / total_ts as u128) as usize;
    idx.min(expected_chunks.saturating_sub(1))
}

fn chunk_bounds(chunk: usize, total_ts: u64, expected_chunks: usize) -> (u64, u64) {
    if expected_chunks == 0 || total_ts == 0 {
        return (0, 0);
    }

    let start = ((chunk as u128 * total_ts as u128) / expected_chunks as u128) as u64;
    let end =
        (((chunk.saturating_add(1)) as u128 * total_ts as u128) / expected_chunks as u128) as u64;
    (start, end)
}

fn normalize_waveform_levels(waveform: &mut [f32]) {
    let mut positive_values: Vec<f32> = waveform
        .iter()
        .copied()
        .filter(|value| *value > EPSILON)
        .collect();
    if positive_values.is_empty() {
        return;
    }

    positive_values.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let scale_index =
        ((positive_values.len() as f32 * DISPLAY_SCALE_QUANTILE).floor() as usize)
            .min(positive_values.len().saturating_sub(1));
    let scale = positive_values[scale_index].max(EPSILON);

    for value in waveform.iter_mut() {
        if *value <= 0.0 {
            continue;
        }

        let normalized = (*value / scale).clamp(0.0, 1.0);
        let compressed = normalized.powf(DISPLAY_GAMMA);
        *value = (DISPLAY_FLOOR + (1.0 - DISPLAY_FLOOR) * compressed).min(1.0);
    }
}

fn fold_packet_energy_to_chunks(
    packet_energies: &[(u64, u64, f32)],
    expected_chunks: usize,
    total_ts: Option<u64>,
) -> Vec<f32> {
    let mut waveform = vec![0.0f32; expected_chunks];
    if packet_energies.is_empty() {
        return waveform;
    }

    if let Some(ts_end) = total_ts.filter(|v| *v > 0) {
        for (packet_start_ts, packet_end_ts, energy) in packet_energies {
            let packet_start = (*packet_start_ts).min(ts_end);
            let packet_end = (*packet_end_ts).min(ts_end).max(packet_start);
            if packet_end <= packet_start {
                continue;
            }

            let first_chunk = time_to_chunk(packet_start, ts_end, expected_chunks);
            let last_chunk = time_to_chunk(packet_end.saturating_sub(1), ts_end, expected_chunks);

            for chunk in first_chunk..=last_chunk {
                let (chunk_start, chunk_end) = chunk_bounds(chunk, ts_end, expected_chunks);
                let overlap_start = packet_start.max(chunk_start);
                let overlap_end = packet_end.min(chunk_end);

                if overlap_end > overlap_start {
                    waveform[chunk] = waveform[chunk].max(*energy);
                }
            }
        }
    } else {
        let packet_count = packet_energies.len().max(1);
        for (i, (_, _, energy)) in packet_energies.iter().enumerate() {
            let idx = (i * expected_chunks) / packet_count;
            let chunk = idx.min(expected_chunks.saturating_sub(1));
            waveform[chunk] = waveform[chunk].max(*energy);
        }
    }

    normalize_waveform_levels(&mut waveform);
    waveform
}

fn compute_packet_envelope(samples: &[f32], sample_stride: usize) -> f32 {
    let sample_stride = sample_stride.max(1);
    let mut sum = 0.0f64;
    let mut count = 0usize;
    let mut peak = 0.0f32;

    for sample in samples.iter().step_by(sample_stride) {
        let abs_sample = sample.abs();
        if abs_sample > peak {
            peak = abs_sample;
        }
        let value = *sample as f64;
        sum += value * value;
        count = count.saturating_add(1);
    }

    if count == 0 {
        0.0
    } else {
        let rms = (sum / count as f64).sqrt() as f32;
        // Blend RMS with the local peak so loud compressed tracks still show shape.
        (rms * 0.45 + peak * 0.55).clamp(0.0, 1.0)
    }
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
    let mut packet_energies: Vec<(u64, u64, f32)> = Vec::new();
    let mut max_packet_end_ts = 0u64;
    let mut track_packet_index = 0usize;
    let mut previous_sampled_packet_ts: Option<u64> = None;
    let mut previous_sampled_energy: Option<f32> = None;

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

        let packet_end_ts = packet_ts.saturating_add(packet_dur.max(1));
        if packet_end_ts > max_packet_end_ts {
            max_packet_end_ts = packet_end_ts;
        }

        let should_sample = track_packet_index % sample_stride == 0;
        track_packet_index = track_packet_index.saturating_add(1);
        if !should_sample {
            continue;
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
            let energy = compute_packet_envelope(buf.samples(), sample_stride);

            if let (Some(start_ts), Some(previous_energy)) =
                (previous_sampled_packet_ts.take(), previous_sampled_energy.take())
            {
                let span_end = packet_ts.max(start_ts.saturating_add(1));
                packet_energies.push((start_ts, span_end, previous_energy));
            }

            previous_sampled_packet_ts = Some(packet_ts);
            previous_sampled_energy = Some(energy);
        }
    }

    if let (Some(start_ts), Some(energy)) =
        (previous_sampled_packet_ts.take(), previous_sampled_energy.take())
    {
        let span_end = max_packet_end_ts.max(start_ts.saturating_add(1));
        packet_energies.push((start_ts, span_end, energy));
    }

    let effective_total_ts = total_ts.or(Some(max_packet_end_ts.max(1)));
    Ok(fold_packet_energy_to_chunks(
        &packet_energies,
        expected_chunks,
        effective_total_ts,
    ))
}

pub fn extract_loaded_waveform(
    expected_chunks: usize,
    sample_stride: usize,
) -> Result<Vec<f32>, String> {
    let path = controller::snapshot_loaded_path()
        .ok_or_else(|| "No loaded audio file to extract waveform from".to_string())?;

    let waveform = extract_waveform_from_path(&path, expected_chunks, sample_stride)?;

    if controller::snapshot_loaded_path().as_deref() != Some(path.as_str()) {
        return Err("loaded audio changed during waveform extraction, please retry".to_string());
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn compute_packet_envelope_uses_sample_stride() {
        let samples = [1.0, 0.0, 1.0, 0.0];

        let envelope_full = compute_packet_envelope(&samples, 1);
        let envelope_sparse = compute_packet_envelope(&samples, 2);

        assert!((envelope_full - 0.868_2).abs() < 1e-3);
        assert!((envelope_sparse - 1.0).abs() < 1e-5);
        assert!(envelope_sparse > envelope_full);
    }

    #[test]
    fn normalize_waveform_levels_spreads_loud_values() {
        let mut waveform = vec![0.82, 0.86, 0.91, 0.95];

        normalize_waveform_levels(&mut waveform);

        assert!(waveform[0] <= waveform[1]);
        assert!(waveform[1] <= waveform[2]);
        assert!(waveform[2] <= waveform[3]);
        assert!(waveform[0] > 0.0);
        assert!(waveform[3] <= 1.0);
    }

    #[test]
    fn fold_packet_energy_to_chunks_prefers_louder_half() {
        let packets = vec![(0, 50, 0.2), (50, 100, 0.8)];

        let waveform = fold_packet_energy_to_chunks(&packets, 4, Some(100));

        assert_eq!(waveform.len(), 4);
        assert!(waveform[0] <= waveform[1]);
        assert!(waveform[1] <= waveform[2]);
        assert!(waveform[2] <= waveform[3]);
        assert!(waveform[0] < waveform[3]);
    }
}
