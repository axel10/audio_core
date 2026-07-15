use std::fs::File;
use std::io::{BufWriter, Write};
use ffmpeg::{codec, filter, format, frame, media};
use ffmpeg_core::ffmpeg;
use super::common::ensure_ffmpeg_initialized;
use crate::frb_generated::StreamSink;
use crate::api::audio_converter::models::{emit_conversion_event, ConversionEvent};
use super::formats::{normalize_path, output_channel_layout, output_sample_rate};

pub(crate) fn decode_to_pcm(
    input_path: &str,
    output_pcm_path: &str,
    target_sample_rate: Option<u32>,
    target_channels: Option<u32>,
    progress_sink: Option<&StreamSink<String>>,
) -> Result<(), String> {
    ensure_ffmpeg_initialized()?;

    let input_path = normalize_path(input_path);
    let output_pcm_path = normalize_path(output_pcm_path);

    // 1. Open input
    let mut ictx = format::input(&input_path)
        .map_err(|e| format!("Failed to open input file: {}", e))?;

    let input_stream = ictx
        .streams()
        .best(media::Type::Audio)
        .ok_or_else(|| "Could not find an audio stream in the input file".to_string())?;

    let context = codec::context::Context::from_parameters(input_stream.parameters())
        .map_err(|e| e.to_string())?;
    let mut decoder = context
        .decoder()
        .audio()
        .map_err(|e| e.to_string())?;
    decoder
        .set_parameters(input_stream.parameters())
        .map_err(|e| e.to_string())?;

    // Determine target parameters
    let sample_rate = output_sample_rate("wav", target_sample_rate, decoder.rate());
    let channel_layout = output_channel_layout(
        target_channels.map(|c| c as u16),
        decoder.channel_layout(),
        decoder.channels(),
    );
    let sample_format = ffmpeg::util::format::Sample::I16(ffmpeg::util::format::sample::Type::Packed);

    // 2. Build filter graph to convert to S16 Packed
    let mut filter_graph = build_pcm_filter_graph(&decoder, sample_rate, channel_layout, sample_format)?;

    // Emit initial format event so Dart/Swift knows the PCM configuration before opening FIFO
    emit_conversion_event(
        progress_sink,
        &ConversionEvent::progress(
            0,
            1,
            input_path.clone(),
            Some(0.0),
            Some(0),
            None,
            Some(format!(
                "FORMAT:channels={},sampleRate={}",
                channel_layout.channels(),
                sample_rate
            )),
        ),
    );

    // 3. Open output file (e.g. named pipe FIFO)
    let out_file = File::create(&output_pcm_path)
        .map_err(|e| format!("Failed to create output file/FIFO: {}", e))?;
    let mut writer = BufWriter::new(out_file);

    // Setup progress reporting variables
    let input_duration_us = match ictx.duration() {
        duration if duration > 0 => Some(duration),
        _ => match input_stream.duration() {
            duration if duration > 0 => {
                use ffmpeg::util::mathematics::rescale::{TIME_BASE, Rescale};
                Some(input_stream.duration().rescale(input_stream.time_base(), TIME_BASE))
            }
            _ => None,
        },
    };
    let input_sample_rate = decoder.rate();
    let mut decoded_sample_count = 0u64;
    let mut last_reported_position_us = None;
    let mut last_reported_fraction = -1.0;

    let stream_index = input_stream.index();
    let decoder_time_base = decoder.time_base();
    decoder.set_packet_time_base(decoder_time_base);

    // 4. Decode loop
    let mut decoded = frame::Audio::empty();
    let mut filtered = frame::Audio::empty();

    macro_rules! process_frames {
        () => {
            loop {
                match decoder.receive_frame(&mut decoded) {
                    Ok(()) => {
                        let frame_timestamp = decoded.timestamp();
                        let frame_position_us = frame_timestamp
                            .map(|value| {
                                use ffmpeg::util::mathematics::rescale::{TIME_BASE, Rescale};
                                value.rescale(decoder_time_base, TIME_BASE)
                            });
                        
                        let sample_position_us = if input_sample_rate > 0 {
                            let micros = (decoded_sample_count as i128).saturating_mul(1_000_000_i128) / i128::from(input_sample_rate);
                            Some(micros as i64)
                        } else {
                            None
                        };

                        let current_position_us = match (frame_position_us, sample_position_us) {
                            (Some(frame), Some(sample)) if frame >= 0 => Some(frame.max(sample)),
                            (Some(frame), _) if frame >= 0 => Some(frame),
                            (_, Some(sample)) => Some(sample),
                            _ => None,
                        };

                        if let Some(pos) = current_position_us {
                            if let Some(total) = input_duration_us {
                                let fraction = (pos as f64 / total as f64).clamp(0.0, 1.0);
                                let should_report = last_reported_position_us.map(|l| pos - l >= 100_000).unwrap_or(true)
                                    || (fraction - last_reported_fraction).abs() >= 0.005;

                                if should_report {
                                    last_reported_position_us = Some(pos);
                                    last_reported_fraction = fraction;
                                    emit_conversion_event(
                                        progress_sink,
                                        &ConversionEvent::progress(
                                            0,
                                            1,
                                            input_path.clone(),
                                            Some(fraction),
                                            Some(pos),
                                            Some(total),
                                            Some("Decoding audio".to_string()),
                                        ),
                                    );
                                }
                            }
                        }

                        decoded_sample_count = decoded_sample_count.saturating_add(decoded.samples() as u64);

                        // Feed frame to filter
                        filter_graph
                            .get("in")
                            .ok_or_else(|| "missing filter source".to_string())?
                            .source()
                            .add(&decoded)
                            .map_err(|e| e.to_string())?;

                        // Pull filtered frames and write to output
                        loop {
                            match filter_graph
                                .get("out")
                                .ok_or_else(|| "missing filter sink".to_string())?
                                .sink()
                                .frame(&mut filtered)
                            {
                                Ok(()) => {
                                    // Packed format -> all interleaved channels are in plane 0
                                    let pcm_data = filtered.data(0);
                                    if !pcm_data.is_empty() {
                                        writer.write_all(pcm_data)
                                            .map_err(|e| format!("Failed to write to FIFO: {}", e))?;
                                    }
                                }
                                Err(ffmpeg::Error::Other { errno }) if errno == ffmpeg::util::error::EAGAIN => {
                                    break;
                                }
                                Err(ffmpeg::Error::Eof) => {
                                    break;
                                }
                                Err(e) => return Err(e.to_string()),
                            }
                        }
                    }
                    Err(ffmpeg::Error::Other { errno }) if errno == ffmpeg::util::error::EAGAIN => {
                        break;
                    }
                    Err(ffmpeg::Error::Eof) => {
                        break;
                    }
                    Err(e) => {
                        if decoded_sample_count > 0 {
                            // Ignore mid-stream decoder errors near EOF if we've successfully decoded some data
                            break;
                        } else {
                            return Err(e.to_string());
                        }
                    }
                }
            }
        };
    }

    // Pull packets from input context
    for (stream, mut packet) in ictx.packets() {
        if stream.index() == stream_index {
            use ffmpeg::util::mathematics::rescale::Rescale;
            packet.rescale_ts(stream.time_base(), decoder_time_base);
            decoder.send_packet(&packet).map_err(|e| e.to_string())?;
            process_frames!();
        }
    }

    // Flush decoder
    let _ = decoder.send_eof();
    process_frames!();

    // Flush filter
    let _ = filter_graph
        .get("in")
        .ok_or_else(|| "missing filter source".to_string())?
        .source()
        .flush();

    // Pull remaining frames from filter
    loop {
        match filter_graph
            .get("out")
            .ok_or_else(|| "missing filter sink".to_string())?
            .sink()
            .frame(&mut filtered)
        {
            Ok(()) => {
                let pcm_data = filtered.data(0);
                if !pcm_data.is_empty() {
                    writer.write_all(pcm_data)
                        .map_err(|e| format!("Failed to write remaining PCM data: {}", e))?;
                }
            }
            Err(_) => break,
        }
    }

    // Flush BufWriter to ensure all bytes are written to FIFO
    writer.flush().map_err(|e| format!("Failed to flush output PCM writer: {}", e))?;

    Ok(())
}

fn build_pcm_filter_graph(
    decoder: &codec::decoder::Audio,
    target_sample_rate: u32,
    target_channel_layout: ffmpeg::ChannelLayout,
    target_sample_format: ffmpeg::util::format::Sample,
) -> Result<filter::Graph, String> {
    let decoder_channel_layout = if decoder.channel_layout().is_empty() {
        ffmpeg::ChannelLayout::default(i32::from(decoder.channels()))
    } else {
        decoder.channel_layout()
    };
    let mut graph = filter::Graph::new();
    let args = format!(
        "time_base={}:sample_rate={}:sample_fmt={}:channel_layout=0x{:x}",
        decoder.time_base(),
        decoder.rate(),
        decoder.format().name(),
        decoder_channel_layout.bits()
    );

    graph
        .add(
            &filter::find("abuffer").ok_or_else(|| "abuffer filter not available".to_string())?,
            "in",
            &args,
        )
        .map_err(|error| error.to_string())?;
    graph
        .add(
            &filter::find("abuffersink")
                .ok_or_else(|| "abuffersink filter not available".to_string())?,
            "out",
            "",
        )
        .map_err(|error| error.to_string())?;

    graph
        .output("in", 0)
        .map_err(|error| error.to_string())?
        .input("out", 0)
        .map_err(|error| error.to_string())?
        .parse(&format!(
            "aformat=sample_fmts={}:sample_rates={}:channel_layouts=0x{:x}",
            target_sample_format.name(),
            target_sample_rate,
            target_channel_layout.bits()
        ))
        .map_err(|error| error.to_string())?;
    graph.validate().map_err(|error| error.to_string())?;

    Ok(graph)
}
