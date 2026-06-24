use base64::prelude::{Engine, BASE64_URL_SAFE_NO_PAD};
use rusty_chromaprint::{Configuration, FingerprintCompressor, Fingerprinter};
use std::path::Path;

pub fn get_audio_fingerprint(path: String) -> anyhow::Result<String> {
    let path = Path::new(&path);
    let raw_fingerprint = get_raw_audio_fingerprint(path)?;
    let config = Configuration::preset_test2();
    let compressed = FingerprintCompressor::from(&config).compress(&raw_fingerprint);
    Ok(BASE64_URL_SAFE_NO_PAD.encode(compressed))
}

fn get_raw_audio_fingerprint(path: &Path) -> anyhow::Result<Vec<u32>> {
    let mut source = ffmpeg_core::AudioSource::open(path)
        .map_err(|e| anyhow::anyhow!("failed to open audio via ffmpeg: {:?}", e))?;

    let sample_rate = source.sample_rate();
    let channels = source.channels();
    if sample_rate == 0 || channels == 0 {
        return Err(anyhow::anyhow!("invalid sample rate or channels"));
    }

    let mut printer = Fingerprinter::new(&Configuration::preset_test2());
    printer
        .start(sample_rate, channels as u32)
        .map_err(|e| anyhow::anyhow!("printer start error: {:?}", e))?;

    let target_samples = (sample_rate as usize) * (channels as usize) * 20;

    let mut samples = Vec::with_capacity(target_samples);
    for sample_f32 in (&mut source).take(target_samples) {
        let sample_i16 = (sample_f32 * 32767.0).clamp(-32768.0, 32767.0) as i16;
        samples.push(sample_i16);
    }

    printer.consume(&samples);
    printer.finish();
    Ok(printer.fingerprint().to_vec())
}
