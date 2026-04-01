use std::error::Error;
use std::path::Path;

use base64::prelude::{Engine, BASE64_URL_SAFE_NO_PAD};
use rusty_chromaprint::{Configuration, FingerprintCompressor, Fingerprinter};
use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::{DecoderOptions, CODEC_TYPE_NULL};
use symphonia::core::errors::Error as SymphoniaError;
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;

fn main() {
    match get_audio_fingerprint(Path::new("test.mp3")) {
        Ok(fp) => println!("{fp}"),
        Err(err) => eprintln!("Error: {err}"),
    }
}

/// 使用 `symphonia` 解码音频，并生成可提交给 AcoustID 的 Chromaprint 指纹字符串。
///
/// 返回值是 `fpcalc` / AcoustID 兼容的压缩指纹，而不是原始 `Vec<u32>`。
pub fn get_audio_fingerprint(path: &Path) -> Result<String, Box<dyn Error>> {
    let raw_fingerprint = get_raw_audio_fingerprint(path)?;
    let config = Configuration::preset_test2();
    let compressed = FingerprintCompressor::from(&config).compress(&raw_fingerprint);
    Ok(BASE64_URL_SAFE_NO_PAD.encode(compressed))
}

fn get_raw_audio_fingerprint(path: &Path) -> Result<Vec<u32>, Box<dyn Error>> {
    let src = std::fs::File::open(path)?;
    let mss = MediaSourceStream::new(Box::new(src), Default::default());

    let mut hint = Hint::new();
    if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
        hint.with_extension(ext);
    }

    let meta_opts: MetadataOptions = Default::default();
    let fmt_opts: FormatOptions = Default::default();

    let probed = symphonia::default::get_probe()
        .format(&hint, mss, &fmt_opts, &meta_opts)?;

    let mut format = probed.format;

    let track = format
        .tracks()
        .iter()
        .find(|t| t.codec_params.codec != CODEC_TYPE_NULL)
        .ok_or_else(|| std::io::Error::other("no supported audio tracks"))?;

    let dec_opts: DecoderOptions = Default::default();
    let mut decoder = symphonia::default::get_codecs().make(&track.codec_params, &dec_opts)?;
    let track_id = track.id;

    let mut printer = Fingerprinter::new(&Configuration::preset_test2());
    let sample_rate = track
        .codec_params
        .sample_rate
        .ok_or_else(|| std::io::Error::other("missing sample rate"))?;
    let channels = track
        .codec_params
        .channels
        .or_else(|| track.codec_params.channel_layout.map(|v| v.into_channels()))
        .ok_or_else(|| std::io::Error::other("missing audio channels"))?
        .count() as u32;
    printer.start(sample_rate, channels)?;

    let mut sample_buf = None;

    loop {
        let packet = match format.next_packet() {
            Ok(packet) => packet,
            Err(_) => break,
        };

        if packet.track_id() != track_id {
            continue;
        }

        match decoder.decode(&packet) {
            Ok(audio_buf) => {
                if sample_buf.is_none() {
                    let spec = *audio_buf.spec();
                    let duration = audio_buf.capacity() as u64;
                    sample_buf = Some(SampleBuffer::<i16>::new(duration, spec));
                }

                if let Some(buf) = &mut sample_buf {
                    buf.copy_interleaved_ref(audio_buf);
                    printer.consume(buf.samples());
                }
            }
            Err(SymphoniaError::DecodeError(_)) => continue,
            Err(err) => return Err(Box::new(err)),
        }
    }

    printer.finish();
    Ok(printer.fingerprint().to_vec())
}
