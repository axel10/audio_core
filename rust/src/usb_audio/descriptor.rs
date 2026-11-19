//! UAC 1.0 / UAC 2.0 descriptor discovery and stream candidate selection.

use rusb::{
    ConfigDescriptor, Context, DeviceHandle, Direction, Speed, TransferType, UsageType,
};
use serde::Serialize;
use std::time::Duration;

pub const USB_CLASS_AUDIO: u8 = 0x01;
pub const USB_SUBCLASS_AUDIOCONTROL: u8 = 0x01;
pub const USB_SUBCLASS_AUDIOSTREAMING: u8 = 0x02;

const USB_DT_CS_INTERFACE: u8 = 0x24;
const UAC2_PROTOCOL: u8 = 0x20;

const UAC_AC_FEATURE_UNIT: u8 = 0x06;
const UAC2_AC_CLOCK_SOURCE: u8 = 0x0a;

const UAC_AS_GENERAL: u8 = 0x01;
const UAC_AS_FORMAT_TYPE: u8 = 0x02;
const UAC_FORMAT_TYPE_I: u8 = 0x01;

const UAC1_FORMAT_TAG_PCM: u16 = 0x0001;
const UAC2_FORMAT_TYPE_I_PCM: u32 = 0x0000_0001;

const USB_DIR_IN: u8 = 0x80;
const USB_TYPE_CLASS: u8 = 0x20;
const USB_RECIP_INTERFACE: u8 = 0x01;
const UAC2_REQUEST_GET_RANGE: u8 = 0x02;
const UAC2_CLOCK_SOURCE_SAM_FREQ_CONTROL: u16 = 0x0100;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub enum UacVersion {
    Uac1,
    Uac2,
}

#[derive(Debug, Clone, Serialize)]
pub struct AudioStreamCandidate {
    pub uac_version: UacVersion,
    pub control_interface: u8,
    pub streaming_interface: u8,
    pub alt_setting: u8,
    pub out_endpoint: u8,
    pub max_packet_size: u16,
    pub service_interval_us: u32,
    pub is_high_speed: bool,
    pub feedback_endpoint: Option<u8>,
    pub feedback_max_packet_size: u16,
    pub channels: u16,
    /// Container size in bytes per sample (2 = 16-bit, 3 = 24-bit packed, 4 = 24/32-bit padded).
    pub subslot_size: u8,
    /// Effective bit resolution (16, 24, 32).
    pub bit_resolution: u8,
    /// Discrete sample rates discovered from descriptors or UAC2 clock range.
    pub sample_rates: Vec<u32>,
    /// Clock Source ID (UAC 2.0 only).
    pub clock_source_id: Option<u8>,
    /// Feature Unit ID for hardware volume (optional).
    pub feature_unit_id: Option<u8>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ParsedUsbAudioDevice {
    pub uac_version: UacVersion,
    pub control_interface: u8,
    pub all_audio_interfaces: Vec<u8>,
    pub clock_source_id: Option<u8>,
    pub feature_unit_id: Option<u8>,
    pub candidates: Vec<AudioStreamCandidate>,
}

/// Iterate standard `(length, descriptor_type, raw_bytes)` chunks inside `extra()`.
fn iter_extra_descriptors(extra: &[u8]) -> impl Iterator<Item = &[u8]> {
    let mut offset = 0usize;
    std::iter::from_fn(move || {
        if offset + 2 > extra.len() {
            return None;
        }
        let len = extra[offset] as usize;
        if len < 2 || offset + len > extra.len() {
            return None;
        }
        let slice = &extra[offset..offset + len];
        offset += len;
        Some(slice)
    })
}

fn compute_service_interval_us(speed: Speed, b_interval: u8) -> (u32, bool) {
    let is_high_speed = matches!(speed, Speed::High | Speed::Super | Speed::SuperPlus);
    if is_high_speed {
        let exp = b_interval.clamp(1, 16).saturating_sub(1);
        let microframes = 1u32.checked_shl(exp as u32).unwrap_or(1);
        (microframes.saturating_mul(125), true)
    } else {
        let exp = b_interval.clamp(1, 16).saturating_sub(1);
        let frames = 1u32.checked_shl(exp as u32).unwrap_or(1);
        (frames.saturating_mul(1_000), false)
    }
}

/// Query discrete sample rates from a UAC 2.0 Clock Source via `RANGE` control transfer.
fn query_uac2_clock_rates(
    handle: &DeviceHandle<Context>,
    control_interface: u8,
    clock_source_id: u8,
) -> Vec<u32> {
    let mut buf = [0u8; 256];
    let request_type = USB_DIR_IN | USB_TYPE_CLASS | USB_RECIP_INTERFACE;
    let w_index = ((clock_source_id as u16) << 8) | (control_interface as u16);

    let read_len = match handle.read_control(
        request_type,
        UAC2_REQUEST_GET_RANGE,
        UAC2_CLOCK_SOURCE_SAM_FREQ_CONTROL,
        w_index,
        &mut buf,
        Duration::from_millis(500),
    ) {
        Ok(n) => n,
        Err(err) => {
            log::warn!(
                "[UsbAudio] UAC2 clock RANGE query failed (cs_id={}): {}",
                clock_source_id,
                err
            );
            return Vec::new();
        }
    };

    if read_len < 2 {
        return Vec::new();
    }

    let num_subranges = u16::from_le_bytes([buf[0], buf[1]]) as usize;
    let mut rates = Vec::new();
    let standard_rates: &[u32] = &[
        44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000, 705_600, 768_000,
    ];

    let mut offset = 2usize;
    for _ in 0..num_subranges {
        if offset + 12 > read_len {
            break;
        }
        let min_hz = u32::from_le_bytes([
            buf[offset],
            buf[offset + 1],
            buf[offset + 2],
            buf[offset + 3],
        ]);
        let max_hz = u32::from_le_bytes([
            buf[offset + 4],
            buf[offset + 5],
            buf[offset + 6],
            buf[offset + 7],
        ]);
        let res_hz = u32::from_le_bytes([
            buf[offset + 8],
            buf[offset + 9],
            buf[offset + 10],
            buf[offset + 11],
        ]);
        offset += 12;

        if min_hz == max_hz && min_hz > 0 {
            rates.push(min_hz);
        } else if max_hz > min_hz {
            for &sr in standard_rates {
                if sr >= min_hz && sr <= max_hz && (res_hz == 0 || (sr - min_hz) % res_hz == 0) {
                    rates.push(sr);
                }
            }
        }
    }

    rates.sort_unstable();
    rates.dedup();
    rates
}

/// Inspect active USB configuration descriptor and collect all PCM playback candidates.
pub fn parse_usb_audio_device(
    handle: &DeviceHandle<Context>,
    config: &ConfigDescriptor,
    speed: Speed,
) -> Result<ParsedUsbAudioDevice, String> {
    let mut uac_version = UacVersion::Uac1;
    let mut control_interface: Option<u8> = None;
    let mut clock_source_id: Option<u8> = None;
    let mut feature_unit_id: Option<u8> = None;
    let mut all_audio_interfaces: Vec<u8> = Vec::new();

    // Pass 1: find AudioControl interface, UAC version, Clock Source and Feature Unit.
    for interface in config.interfaces() {
        let iface_num = interface.number();
        for desc in interface.descriptors() {
            if desc.class_code() != USB_CLASS_AUDIO {
                continue;
            }
            if !all_audio_interfaces.contains(&iface_num) {
                all_audio_interfaces.push(iface_num);
            }
            if desc.sub_class_code() == USB_SUBCLASS_AUDIOCONTROL && control_interface.is_none() {
                control_interface = Some(iface_num);
                if desc.protocol_code() == UAC2_PROTOCOL {
                    uac_version = UacVersion::Uac2;
                }
                for cs in iter_extra_descriptors(desc.extra()) {
                    if cs.len() < 4 || cs[1] != USB_DT_CS_INTERFACE {
                        continue;
                    }
                    let subtype = cs[2];
                    if uac_version == UacVersion::Uac2
                        && subtype == UAC2_AC_CLOCK_SOURCE
                        && clock_source_id.is_none()
                    {
                        clock_source_id = Some(cs[3]);
                    } else if subtype == UAC_AC_FEATURE_UNIT && feature_unit_id.is_none() {
                        feature_unit_id = Some(cs[3]);
                    }
                }
            }
        }
    }

    let control_interface =
        control_interface.ok_or_else(|| "No USB AudioControl interface found".to_string())?;

    let uac2_clock_rates = if uac_version == UacVersion::Uac2 {
        clock_source_id
            .map(|cs_id| query_uac2_clock_rates(handle, control_interface, cs_id))
            .unwrap_or_default()
    } else {
        Vec::new()
    };

    // Pass 2: enumerate AudioStreaming OUT alt-settings.
    let mut candidates = Vec::new();

    for interface in config.interfaces() {
        let iface_num = interface.number();
        for desc in interface.descriptors() {
            if desc.class_code() != USB_CLASS_AUDIO
                || desc.sub_class_code() != USB_SUBCLASS_AUDIOSTREAMING
            {
                continue;
            }
            if desc.setting_number() == 0 {
                continue;
            }

            let iface_uac = if desc.protocol_code() == UAC2_PROTOCOL {
                UacVersion::Uac2
            } else {
                uac_version
            };

            // Find Isochronous OUT endpoint and optional Explicit Feedback IN endpoint.
            let mut out_ep = None;
            let mut feedback_ep = None;
            for ep in desc.endpoint_descriptors() {
                if ep.transfer_type() != TransferType::Isochronous {
                    continue;
                }
                match ep.direction() {
                    Direction::Out => {
                        if out_ep.is_none() {
                            out_ep = Some((
                                ep.address(),
                                ep.max_packet_size(),
                                ep.interval(),
                                ep.sync_type(),
                            ));
                        }
                    }
                    Direction::In => {
                        if ep.usage_type() == UsageType::Feedback
                            || ep.usage_type() == UsageType::FeedbackData
                        {
                            feedback_ep = Some((ep.address(), ep.max_packet_size()));
                        }
                    }
                }
            }

            let Some((out_addr, max_packet_size, b_interval, _sync_type)) = out_ep else {
                continue;
            };

            let (service_interval_us, is_high_speed) =
                compute_service_interval_us(speed, b_interval);

            // Parse class-specific AS_GENERAL and FORMAT_TYPE descriptors.
            let mut is_pcm = false;
            let mut channels = 2u16;
            let mut subslot_size = 0u8;
            let mut bit_resolution = 0u8;
            let mut sample_rates = Vec::new();

            for cs in iter_extra_descriptors(desc.extra()) {
                if cs.len() < 4 || cs[1] != USB_DT_CS_INTERFACE {
                    continue;
                }
                let subtype = cs[2];
                match (iface_uac, subtype) {
                    (UacVersion::Uac2, UAC_AS_GENERAL) if cs.len() >= 11 => {
                        let format_type = cs[5];
                        let formats = u32::from_le_bytes([cs[6], cs[7], cs[8], cs[9]]);
                        if format_type == UAC_FORMAT_TYPE_I && (formats & UAC2_FORMAT_TYPE_I_PCM) != 0
                        {
                            is_pcm = true;
                        }
                        channels = cs[10] as u16;
                    }
                    (UacVersion::Uac2, UAC_AS_FORMAT_TYPE) if cs.len() >= 6 => {
                        if cs[3] == UAC_FORMAT_TYPE_I {
                            subslot_size = cs[4];
                            bit_resolution = cs[5];
                        }
                    }
                    (UacVersion::Uac1, UAC_AS_GENERAL) if cs.len() >= 7 => {
                        let format_tag = u16::from_le_bytes([cs[5], cs[6]]);
                        if format_tag == UAC1_FORMAT_TAG_PCM {
                            is_pcm = true;
                        }
                    }
                    (UacVersion::Uac1, UAC_AS_FORMAT_TYPE) if cs.len() >= 11 => {
                        if cs[3] == UAC_FORMAT_TYPE_I {
                            channels = cs[4] as u16;
                            subslot_size = cs[5];
                            bit_resolution = cs[6];
                            let sam_freq_type = cs[7];
                            if sam_freq_type == 0 && cs.len() >= 14 {
                                let min_hz = u32::from_le_bytes([cs[8], cs[9], cs[10], 0]);
                                let max_hz = u32::from_le_bytes([cs[11], cs[12], cs[13], 0]);
                                for &sr in &[44_100u32, 48_000, 88_200, 96_000, 176_400, 192_000] {
                                    if sr >= min_hz && sr <= max_hz {
                                        sample_rates.push(sr);
                                    }
                                }
                            } else {
                                let mut off = 8usize;
                                for _ in 0..sam_freq_type {
                                    if off + 3 > cs.len() {
                                        break;
                                    }
                                    let sr =
                                        u32::from_le_bytes([cs[off], cs[off + 1], cs[off + 2], 0]);
                                    if sr > 0 {
                                        sample_rates.push(sr);
                                    }
                                    off += 3;
                                }
                            }
                        }
                    }
                    _ => {}
                }
            }

            if !is_pcm || subslot_size < 2 || subslot_size > 4 || channels == 0 {
                continue;
            }

            if iface_uac == UacVersion::Uac2 {
                sample_rates = if !uac2_clock_rates.is_empty() {
                    uac2_clock_rates.clone()
                } else {
                    vec![44_100, 48_000, 88_200, 96_000, 176_400, 192_000]
                };
            } else if sample_rates.is_empty() {
                sample_rates = vec![44_100, 48_000];
            }

            candidates.push(AudioStreamCandidate {
                uac_version: iface_uac,
                control_interface,
                streaming_interface: iface_num,
                alt_setting: desc.setting_number(),
                out_endpoint: out_addr,
                max_packet_size,
                service_interval_us,
                is_high_speed,
                feedback_endpoint: feedback_ep.map(|(addr, _)| addr),
                feedback_max_packet_size: feedback_ep.map(|(_, mps)| mps).unwrap_or(0),
                channels,
                subslot_size,
                bit_resolution,
                sample_rates,
                clock_source_id,
                feature_unit_id,
            });
        }
    }

    if candidates.is_empty() {
        return Err("No compatible PCM Isochronous OUT alt-setting found on USB DAC".to_string());
    }

    all_audio_interfaces.sort_unstable();
    all_audio_interfaces.dedup();

    Ok(ParsedUsbAudioDevice {
        uac_version,
        control_interface,
        all_audio_interfaces,
        clock_source_id,
        feature_unit_id,
        candidates,
    })
}

/// Select the best PCM alt-setting for the requested `(sample_rate, channels, preferred_bit_depth)`.
pub fn select_best_candidate<'a>(
    candidates: &'a [AudioStreamCandidate],
    sample_rate: u32,
    channels: u16,
    preferred_bit_depth: u8,
) -> Option<&'a AudioStreamCandidate> {
    candidates
        .iter()
        .min_by_key(|c| {
            let rate_mismatch = if c.sample_rates.contains(&sample_rate) {
                0u32
            } else {
                1000
            };
            let chan_diff = c.channels.abs_diff(channels) as u32 * 100;
            // Prefer exact or higher bit resolution (e.g. 24/32-bit over 16-bit).
            let depth_penalty = if c.bit_resolution == preferred_bit_depth {
                0u32
            } else if c.bit_resolution >= 24 {
                10
            } else {
                50
            };
            // Prefer 4-byte padded over 3-byte packed when resolution is equal (more DACs handle it cleanly),
            // or 3-byte packed if that's the only 24-bit option.
            let subslot_pref = match (c.bit_resolution, c.subslot_size) {
                (32, 4) => 0u32,
                (24, 4) => 1,
                (24, 3) => 2,
                (16, 2) => 3,
                _ => 4,
            };
            (rate_mismatch, chan_diff, depth_penalty, subslot_pref)
        })
}
