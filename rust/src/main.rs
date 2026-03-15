use rodio::{Decoder, Source};
use std::fs::File;
use std::time::Instant;

pub fn extract_waveform_fast(
    expected_chunks: usize,
    sample_stride: usize,
) -> Result<Vec<f32>, String> {
    if expected_chunks == 0 {
        return Err("expected_chunks must be > 0".into());
    }

    let start = Instant::now();

    let file = File::open("e:/test.m4a").map_err(|e| e.to_string())?;
    let mut source = Decoder::try_from(file).map_err(|e| e.to_string())?;

    let channels = source.channels().get() as usize;

    let sample_rate = source.sample_rate().get() as f32;

    let duration = source
        .total_duration()
        .map(|d| d.as_secs_f32())
        .unwrap_or(0.0);

    println!("decoder耗时: {:?}", start.elapsed());

    let start = Instant::now();

    let total_frames = (duration * sample_rate) as usize;

    let samples_per_chunk = if total_frames > 0 {
        total_frames / expected_chunks
    } else {
        44100
    };

    let stride = sample_stride.max(1);

    let mut waveform = vec![0.0f32; expected_chunks];

    let mut frame_index = 0usize;
    let mut chunk = 0usize;

    let mut next_chunk_frame = samples_per_chunk;

    let mut skip_counter = 0usize;

    let mut iter = source.by_ref();

    loop {
        let mut frame_peak = 0.0f32;

        for _ in 0..channels {
            let sample = match iter.next() {
                Some(s) => s,
                None => return Ok(waveform),
            };

            let abs = sample.abs();
            if abs > frame_peak {
                frame_peak = abs;
            }
        }

        skip_counter += 1;
        if skip_counter < stride {
            continue;
        }
        skip_counter = 0;

        if frame_peak > waveform[chunk] {
            waveform[chunk] = frame_peak;
        }

        frame_index += 1;

        if frame_index >= next_chunk_frame {
            chunk += 1;

            if chunk >= expected_chunks {
                break;
            }

            next_chunk_frame += samples_per_chunk;
        }
    }

    println!("波形计算耗时: {:?}", start.elapsed());

    Ok(waveform)
}

fn main() {
    let start = Instant::now();

    let waveform = extract_waveform_fast(200, 10).unwrap();

    println!("总耗时: {:?}", start.elapsed());
}
