use base64::prelude::{Engine, BASE64_URL_SAFE_NO_PAD};
use rusty_chromaprint::{Configuration, FingerprintCompressor, Fingerprinter};
use std::path::Path;
use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::{DecoderOptions, CODEC_TYPE_NULL};
use symphonia::core::errors::Error as SymphoniaError;
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;

pub fn get_audio_fingerprint(path: String) -> anyhow::Result<String> {
    let path = Path::new(&path);
    let raw_fingerprint = get_raw_audio_fingerprint(path)?;
    let config = Configuration::preset_test2();
    let compressed = FingerprintCompressor::from(&config).compress(&raw_fingerprint);
    Ok(BASE64_URL_SAFE_NO_PAD.encode(compressed))
}

fn get_raw_audio_fingerprint(path: &Path) -> anyhow::Result<Vec<u32>> {
    let src = std::fs::File::open(path)?;
    let mss = MediaSourceStream::new(Box::new(src), Default::default());

    let mut hint = Hint::new();
    if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
        hint.with_extension(ext);
    }

    let meta_opts: MetadataOptions = Default::default();
    let fmt_opts: FormatOptions = Default::default();

    let probed = symphonia::default::get_probe().format(&hint, mss, &fmt_opts, &meta_opts)?;

    let mut format = probed.format;

    let track = format
        .tracks()
        .iter()
        .find(|t| t.codec_params.codec != CODEC_TYPE_NULL)
        .ok_or_else(|| anyhow::anyhow!("no supported audio tracks"))?;

    let dec_opts: DecoderOptions = Default::default();
    let mut decoder = symphonia::default::get_codecs().make(&track.codec_params, &dec_opts)?;
    let track_id = track.id;

    let mut printer = Fingerprinter::new(&Configuration::preset_test2());
    let mut is_printer_started = false;
    let mut sample_buf = None;

    let mut total_samples_processed: usize = 0;
    let mut target_samples: usize = usize::MAX;

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
                if !is_printer_started {
                    let spec = *audio_buf.spec();
                    printer
                        .start(spec.rate, spec.channels.count() as u32)
                        .map_err(|e| anyhow::anyhow!("printer start error: {:?}", e))?;

                    let duration = audio_buf.capacity() as u64;
                    sample_buf = Some(SampleBuffer::<i16>::new(duration, spec));
                    is_printer_started = true;

                    target_samples = (spec.rate as usize) * (spec.channels.count() as usize) * 20;
                }

                if let Some(buf) = &mut sample_buf {
                    buf.copy_interleaved_ref(audio_buf);
                    let samples = buf.samples();

                    let remaining = target_samples.saturating_sub(total_samples_processed);
                    if samples.len() >= remaining {
                        printer.consume(&samples[..remaining]);
                        total_samples_processed += remaining;
                        break;
                    } else {
                        printer.consume(samples);
                        total_samples_processed += samples.len();
                    }
                }
            }
            Err(SymphoniaError::DecodeError(_)) => continue,
            Err(err) => return Err(anyhow::anyhow!(err)),
        }
    }

    printer.finish();
    Ok(printer.fingerprint().to_vec())
}
