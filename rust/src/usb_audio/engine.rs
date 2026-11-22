//! Android user-space USB Audio exclusive engine.
//!
//! Owns the duplicated USB file descriptor, claims Audio interfaces (detaching
//! Linux `snd-usb-audio` so other apps have no audio output), configures UAC1 /
//! UAC2 sample rates, and streams interleaved Float32 PCM from an `rtrb` ring
//! buffer to the DAC via asynchronous `libusb` isochronous transfers.

use crate::usb_audio::descriptor::{
    parse_usb_audio_device, refresh_uac2_clock_rates, select_best_candidate, AudioStreamCandidate,
    ParsedUsbAudioDevice, UacVersion, USB_CLASS_AUDIO,
};
use crate::usb_audio::iso_scheduler::IsoPacketScheduler;
use libusb1_sys::{
    constants::{
        LIBUSB_TRANSFER_CANCELLED, LIBUSB_TRANSFER_COMPLETED, LIBUSB_TRANSFER_NO_DEVICE,
    },
    libusb_alloc_transfer, libusb_cancel_transfer, libusb_fill_iso_transfer, libusb_free_transfer,
    libusb_submit_transfer, libusb_transfer,
};
use once_cell::sync::Lazy;
use parking_lot::Mutex;
use rusb::{disable_device_discovery, supports_detach_kernel_driver, Context, DeviceHandle, UsbContext};
use serde::Serialize;
use std::ffi::c_void;
use std::os::raw::{c_int, c_uint};
use std::os::unix::io::RawFd;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Once};
use std::thread::{self, JoinHandle};
use std::time::Duration;

const USB_DIR_OUT: u8 = 0x00;
const USB_TYPE_CLASS: u8 = 0x20;
const USB_RECIP_INTERFACE: u8 = 0x01;
const USB_RECIP_ENDPOINT: u8 = 0x02;

const UAC2_REQUEST_SET_CUR: u8 = 0x01;
const UAC1_REQUEST_SET_CUR: u8 = 0x01;
const UAC2_CLOCK_SOURCE_SAM_FREQ_CONTROL: u16 = 0x0100;
const UAC1_SAM_FREQ_CONTROL: u16 = 0x0100;

const ISO_TRANSFER_QUEUE_DEPTH: usize = 8;
const ISO_TRANSFER_TIMEOUT_MS: c_uint = 1000;
const RING_BUFFER_DURATION_MS: usize = 250;
const CLOCK_SETTLE_DELAY_MS: u64 = 25;

static LIBUSB_INIT_ONCE: Once = Once::new();

fn init_libusb_for_android() {
    LIBUSB_INIT_ONCE.call_once(|| {
        if let Err(err) = disable_device_discovery() {
            log::warn!("[UsbAudio] disable_device_discovery returned: {}", err);
        }
    });
}

/// RAII owner of a `dup()`-ed Android USB file descriptor.
struct OwnedFd(RawFd);

impl OwnedFd {
    fn duplicate(fd: RawFd) -> Result<Self, String> {
        let dup_fd = unsafe { libc::dup(fd) };
        if dup_fd < 0 {
            return Err(format!(
                "libc::dup({}) failed: {}",
                fd,
                std::io::Error::last_os_error()
            ));
        }
        Ok(Self(dup_fd))
    }

    fn raw(&self) -> RawFd {
        self.0
    }
}

impl Drop for OwnedFd {
    fn drop(&mut self) {
        if self.0 >= 0 {
            unsafe {
                libc::close(self.0);
            }
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct UsbExclusiveStatus {
    pub exclusive_active: bool,
    pub stream_running: bool,
    pub paused: bool,
    pub device_name: String,
    pub vendor_id: u16,
    pub product_id: u16,
    pub uac_version: String,
    pub sample_rate: u32,
    pub channels: u16,
    pub bit_depth: u8,
    pub subslot_size: u8,
    pub has_feedback_endpoint: bool,
    pub played_frames: u64,
    pub buffered_frames: u64,
    pub underrun_count: u64,
    pub supported_sample_rates: Vec<u32>,
    pub last_error: Option<String>,
}

impl Default for UsbExclusiveStatus {
    fn default() -> Self {
        Self {
            exclusive_active: false,
            stream_running: false,
            paused: false,
            device_name: String::new(),
            vendor_id: 0,
            product_id: 0,
            uac_version: "none".to_string(),
            sample_rate: 0,
            channels: 0,
            bit_depth: 0,
            subslot_size: 0,
            has_feedback_endpoint: false,
            played_frames: 0,
            buffered_frames: 0,
            underrun_count: 0,
            supported_sample_rates: Vec::new(),
            last_error: None,
        }
    }
}

struct RegisteredDevice {
    // Drop order matters: release libusb handle before context and before closing dup_fd.
    handle: DeviceHandle<Context>,
    context: Context,
    _owned_fd: OwnedFd,
    vendor_id: u16,
    product_id: u16,
    device_name: String,
    parsed: ParsedUsbAudioDevice,
    claimed_interfaces: Vec<u8>,
}

/// Shared state accessed by both the producer (ExoPlayer JNI thread) and the
/// libusb event-loop thread.
struct StreamShared {
    stop_flag: AtomicBool,
    paused_flag: AtomicBool,
    flush_flag: AtomicBool,
    in_flight: AtomicUsize,
    played_frames: AtomicU64,
    underrun_count: AtomicU64,
    volume_bits: AtomicU32,
    sample_rate: u32,
    channels: u16,
    subslot_size: u8,
    bit_resolution: u8,
    is_high_speed: bool,
    service_interval_us: u32,
    out_endpoint: u8,
    feedback_endpoint: Option<u8>,
    feedback_max_packet_size: u16,
    /// Only accessed inside the single libusb event-loop thread.
    consumer: Mutex<rtrb::Consumer<f32>>,
    scheduler: Mutex<IsoPacketScheduler>,
    /// Temp scratch buffer for reading f32 samples from ring buffer.
    scratch_f32: Mutex<Vec<f32>>,
}

struct IsoOutSlot {
    shared: Arc<StreamShared>,
    transfer: *mut libusb_transfer,
    buffer: Vec<u8>,
    frame_counts: Vec<usize>,
}

struct IsoFeedbackSlot {
    shared: Arc<StreamShared>,
    transfer: *mut libusb_transfer,
    buffer: Vec<u8>,
}

struct ActiveStream {
    shared: Arc<StreamShared>,
    streaming_interface: u8,
    event_thread: Option<JoinHandle<()>>,
}

struct GlobalUsbState {
    device: Option<RegisteredDevice>,
    active_candidate: Option<AudioStreamCandidate>,
    configured_sample_rate: u32,
    configured_channels: u16,
    stream: Option<ActiveStream>,
    producer: Option<rtrb::Producer<f32>>,
    volume: f32,
    last_error: Option<String>,
}

impl GlobalUsbState {
    fn new() -> Self {
        Self {
            device: None,
            active_candidate: None,
            configured_sample_rate: 0,
            configured_channels: 0,
            stream: None,
            producer: None,
            volume: 1.0,
            last_error: None,
        }
    }
}

static USB_STATE: Lazy<Mutex<GlobalUsbState>> = Lazy::new(|| Mutex::new(GlobalUsbState::new()));
/// Separate lock for the hot-path PCM producer so `write_float_pcm` never
/// contends with status queries or control calls.
static PCM_PRODUCER: Lazy<Mutex<Option<rtrb::Producer<f32>>>> = Lazy::new(|| Mutex::new(None));

#[repr(C)]
struct UsbdevfsGetDriver {
    interface: c_uint,
    driver: [u8; 256],
}

#[repr(C)]
struct UsbdevfsIoctl {
    ifno: c_int,
    ioctl_code: c_int,
    data: *mut c_void,
}

const fn usbdevfs_iow(nr: u32, size: usize) -> u32 {
    0x4000_0000 | ((size as u32) << 16) | ((b'U' as u32) << 8) | nr
}

const fn usbdevfs_iowr(nr: u32, size: usize) -> u32 {
    0xC000_0000 | ((size as u32) << 16) | ((b'U' as u32) << 8) | nr
}

// Linux <linux/usbdevice_fs.h>
const USBDEVFS_GETDRIVER: u32 = usbdevfs_iow(8, std::mem::size_of::<UsbdevfsGetDriver>());
const USBDEVFS_IOCTL: u32 = usbdevfs_iowr(18, std::mem::size_of::<UsbdevfsIoctl>());
const USBDEVFS_DISCONNECT: c_int = ((b'U' as c_int) << 8) | 22;
const USBDEVFS_CONNECT: c_int = ((b'U' as c_int) << 8) | 23;

fn query_usbfs_driver_name(fd: RawFd, iface: u8) -> Result<String, std::io::Error> {
    let mut info = UsbdevfsGetDriver {
        interface: iface as c_uint,
        driver: [0u8; 256],
    };
    let rc = unsafe {
        libc::ioctl(
            fd,
            USBDEVFS_GETDRIVER as _,
            &mut info as *mut UsbdevfsGetDriver,
        )
    };
    if rc == 0 {
        let nul_pos = info
            .driver
            .iter()
            .position(|&b| b == 0)
            .unwrap_or(info.driver.len());
        Ok(String::from_utf8_lossy(&info.driver[..nul_pos]).into_owned())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

fn format_usbfs_driver(res: &Result<String, std::io::Error>) -> String {
    match res {
        Ok(name) => format!("driver=\"{}\"", name),
        Err(err) => format!("ioctl_err={} (raw_os_error={:?})", err, err.raw_os_error()),
    }
}

/// Directly sends `USBDEVFS_IOCTL(USBDEVFS_DISCONNECT)` to detach any driver
/// currently bound to `iface`, including a stale `"usbfs"` claim that `libusb`
/// intentionally skips in `detach_kernel_driver()` / `auto_detach_kernel_driver`.
fn force_disconnect_usbfs_driver(fd: RawFd, iface: u8) -> Result<(), std::io::Error> {
    let mut ctl = UsbdevfsIoctl {
        ifno: iface as c_int,
        ioctl_code: USBDEVFS_DISCONNECT,
        data: std::ptr::null_mut(),
    };
    let rc = unsafe { libc::ioctl(fd, USBDEVFS_IOCTL as _, &mut ctl as *mut UsbdevfsIoctl) };
    if rc >= 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

/// Directly sends `USBDEVFS_IOCTL(USBDEVFS_CONNECT)` to re-attach the Linux
/// kernel driver (e.g. `snd-usb-audio`) to an unbound USB interface.
fn force_connect_usbfs_driver(fd: RawFd, iface: u8) -> Result<(), std::io::Error> {
    let mut ctl = UsbdevfsIoctl {
        ifno: iface as c_int,
        ioctl_code: USBDEVFS_CONNECT,
        data: std::ptr::null_mut(),
    };
    let rc = unsafe { libc::ioctl(fd, USBDEVFS_IOCTL as _, &mut ctl as *mut UsbdevfsIoctl) };
    if rc >= 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

fn claim_interface_force(
    handle: &DeviceHandle<Context>,
    fd: RawFd,
    iface: u8,
) -> Result<(), String> {
    let supports_detach = supports_detach_kernel_driver();
    let initial_drv = query_usbfs_driver_name(fd, iface);

    if let Ok(ref drv) = initial_drv {
        if drv == "usbfs" {
            let res = force_disconnect_usbfs_driver(fd, iface);
            log::warn!(
                "[UsbAudio] iface={} held by stale usbfs; force USBDEVFS_DISCONNECT -> {:?}",
                iface,
                res,
            );
        } else if supports_detach {
            let _ = handle.detach_kernel_driver(iface);
        }
    } else if supports_detach {
        if let Ok(true) = handle.kernel_driver_active(iface) {
            let _ = handle.detach_kernel_driver(iface);
        }
    }

    for attempt in 0..6 {
        match handle.claim_interface(iface) {
            Ok(()) => return Ok(()),
            Err(err) => {
                let drv_now = query_usbfs_driver_name(fd, iface);
                if attempt == 5 {
                    return Err(format!(
                        "claim_interface({}) failed: {} [{}]",
                        iface,
                        err,
                        format_usbfs_driver(&drv_now)
                    ));
                }
                if matches!(drv_now.as_deref(), Ok("usbfs")) {
                    let _ = force_disconnect_usbfs_driver(fd, iface);
                } else if supports_detach {
                    let _ = handle.detach_kernel_driver(iface);
                }
                thread::sleep(Duration::from_millis(50));
            }
        }
    }
    unreachable!()
}

fn release_interfaces_and_restore_kernel(handle: &DeviceHandle<Context>, interfaces: &[u8]) {
    for &iface in interfaces.iter().rev() {
        let _ = handle.set_alternate_setting(iface, 0);
        let _ = handle.release_interface(iface);
        if supports_detach_kernel_driver() {
            let _ = handle.attach_kernel_driver(iface);
        }
    }
}

fn configure_sample_rate(
    handle: &DeviceHandle<Context>,
    candidate: &AudioStreamCandidate,
    sample_rate: u32,
) -> Result<(), String> {
    match candidate.uac_version {
        UacVersion::Uac2 => {
            let cs_id = candidate
                .clock_source_id
                .ok_or_else(|| "UAC2 device missing Clock Source ID".to_string())?;
            let request_type = USB_DIR_OUT | USB_TYPE_CLASS | USB_RECIP_INTERFACE;
            let w_index = ((cs_id as u16) << 8) | (candidate.control_interface as u16);
            let data = sample_rate.to_le_bytes();
            handle
                .write_control(
                    request_type,
                    UAC2_REQUEST_SET_CUR,
                    UAC2_CLOCK_SOURCE_SAM_FREQ_CONTROL,
                    w_index,
                    &data,
                    Duration::from_millis(500),
                )
                .map_err(|e| format!("UAC2 SET_CUR sample_rate={} failed: {}", sample_rate, e))?;
        }
        UacVersion::Uac1 => {
            let request_type = USB_DIR_OUT | USB_TYPE_CLASS | USB_RECIP_ENDPOINT;
            let w_index = candidate.out_endpoint as u16;
            let bytes = sample_rate.to_le_bytes();
            let data = [bytes[0], bytes[1], bytes[2]];
            if let Err(err) = handle.write_control(
                request_type,
                UAC1_REQUEST_SET_CUR,
                UAC1_SAM_FREQ_CONTROL,
                w_index,
                &data,
                Duration::from_millis(500),
            ) {
                // Some fixed-rate UAC1 DACs stall SET_CUR on endpoint; log and proceed.
                log::warn!(
                    "[UsbAudio] UAC1 SET_CUR sample_rate={} returned: {}",
                    sample_rate,
                    err
                );
            }
        }
    }
    thread::sleep(Duration::from_millis(CLOCK_SETTLE_DELAY_MS));
    Ok(())
}

/// Dynamic range (in dB) of the perceptual logarithmic volume curve for USB
/// exclusive output. `0.0` is hard-muted and `1.0` is bit-perfect unity gain.
const USB_VOLUME_MIN_DB: f32 = 60.0;

/// Map a linear UI volume in `[0.0, 1.0]` to a perceptual logarithmic gain
/// spanning `-60 dB .. 0 dB`.
pub(crate) fn volume_to_perceptual_gain(volume: f32) -> f32 {
    if !volume.is_finite() || volume <= 0.0 {
        return 0.0;
    }
    if volume >= 1.0 {
        return 1.0;
    }
    10.0_f32.powf((volume - 1.0) * (USB_VOLUME_MIN_DB / 20.0))
}

/// Convert interleaved f32 samples into the wire format expected by the DAC.
fn pack_f32_to_wire(
    samples: &[f32],
    subslot_size: u8,
    bit_resolution: u8,
    volume: f32,
    out: &mut [u8],
) {
    let gain = volume_to_perceptual_gain(volume);
    match subslot_size {
        2 => {
            for (i, &s) in samples.iter().enumerate() {
                let clamped = (s * gain).clamp(-1.0, 1.0);
                let val = (clamped * 32767.0).round() as i16;
                let bytes = val.to_le_bytes();
                let off = i * 2;
                out[off] = bytes[0];
                out[off + 1] = bytes[1];
            }
        }
        3 => {
            // S24_3LE: 24-bit signed little-endian packed in 3 bytes.
            for (i, &s) in samples.iter().enumerate() {
                let clamped = (s * gain).clamp(-1.0, 1.0);
                let val = (clamped * 8_388_607.0).round() as i32;
                let bytes = val.to_le_bytes();
                let off = i * 3;
                out[off] = bytes[0];
                out[off + 1] = bytes[1];
                out[off + 2] = bytes[2];
            }
        }
        4 => {
            if bit_resolution <= 24 {
                // S24_LE in 32-bit container (left-aligned or LSB-24 depending on DAC;
                // UAC2 standard puts active bits in the MSBs: shift left by 8).
                for (i, &s) in samples.iter().enumerate() {
                    let clamped = (s * gain).clamp(-1.0, 1.0);
                    let val = ((clamped * 8_388_607.0).round() as i32) << 8;
                    let bytes = val.to_le_bytes();
                    let off = i * 4;
                    out[off..off + 4].copy_from_slice(&bytes);
                }
            } else {
                // S32_LE
                for (i, &s) in samples.iter().enumerate() {
                    let clamped = (s as f64 * gain as f64).clamp(-1.0, 1.0);
                    let val = (clamped * 2_147_483_647.0).round() as i32;
                    let bytes = val.to_le_bytes();
                    let off = i * 4;
                    out[off..off + 4].copy_from_slice(&bytes);
                }
            }
        }
        _ => {
            out.fill(0);
        }
    }
}

/// Fill an Isochronous OUT slot's buffer & packet descriptors from the ring buffer.
unsafe fn fill_and_submit_out_slot(
    slot: &mut IsoOutSlot,
    dev_handle_raw: *mut libusb1_sys::libusb_device_handle,
) -> bool {
    let shared = Arc::clone(&slot.shared);
    if shared.stop_flag.load(Ordering::Acquire) {
        return false;
    }

    let bytes_per_frame = shared.channels as usize * shared.subslot_size as usize;
    let packet_bytes = {
        let mut sched = shared.scheduler.lock();
        sched.next_transfer_packet_bytes()
    };
    let num_packets = packet_bytes.len();
    let total_bytes: usize = packet_bytes.iter().sum();
    if slot.buffer.len() < total_bytes {
        slot.buffer.resize(total_bytes, 0);
    }
    slot.frame_counts.clear();

    let total_frames = total_bytes / bytes_per_frame.max(1);
    let total_samples = total_frames * shared.channels as usize;

    let paused = shared.paused_flag.load(Ordering::Acquire);
    let mut consumer = shared.consumer.lock();

    if shared.flush_flag.swap(false, Ordering::AcqRel) {
        let avail = consumer.slots();
        if avail > 0 {
            if let Ok(chunk) = consumer.read_chunk(avail) {
                chunk.commit_all();
            }
        }
    }

    if paused {
        slot.buffer[..total_bytes].fill(0);
        for &pb in &packet_bytes {
            slot.frame_counts.push(pb / bytes_per_frame.max(1));
        }
    } else {
        let mut scratch = shared.scratch_f32.lock();
        if scratch.len() < total_samples {
            scratch.resize(total_samples, 0.0);
        }

        let available = consumer.slots();
        let to_read = available.min(total_samples);
        let mut read_done = 0usize;
        if to_read > 0 {
            if let Ok(chunk) = consumer.read_chunk(to_read) {
                let (first, second) = chunk.as_slices();
                let n1 = first.len();
                scratch[..n1].copy_from_slice(first);
                let n2 = second.len();
                if n2 > 0 {
                    scratch[n1..n1 + n2].copy_from_slice(second);
                }
                chunk.commit_all();
                read_done = n1 + n2;
            }
        }

        if read_done < total_samples {
            scratch[read_done..total_samples].fill(0.0);
            if read_done > 0 {
                shared.underrun_count.fetch_add(1, Ordering::Relaxed);
            }
        }

        let volume = f32::from_bits(shared.volume_bits.load(Ordering::Relaxed));
        pack_f32_to_wire(
            &scratch[..total_samples],
            shared.subslot_size,
            shared.bit_resolution,
            volume,
            &mut slot.buffer[..total_bytes],
        );

        let played_in_this_urb = read_done / shared.channels.max(1) as usize;
        // Distribute played frames metadata for completion accounting.
        slot.frame_counts.push(played_in_this_urb);
    }

    libusb_fill_iso_transfer(
        slot.transfer,
        dev_handle_raw,
        shared.out_endpoint,
        slot.buffer.as_mut_ptr(),
        total_bytes as c_int,
        num_packets as c_int,
        iso_out_callback,
        (slot as *mut IsoOutSlot) as *mut c_void,
        ISO_TRANSFER_TIMEOUT_MS,
    );

    let desc_base = (*slot.transfer).iso_packet_desc.as_mut_ptr();
    for (i, &pkt_len) in packet_bytes.iter().enumerate() {
        (*desc_base.add(i)).length = pkt_len as c_uint;
    }

    shared.in_flight.fetch_add(1, Ordering::AcqRel);
    let rc = libusb_submit_transfer(slot.transfer);
    if rc != 0 {
        shared.in_flight.fetch_sub(1, Ordering::AcqRel);
        log::error!("[UsbAudio] libusb_submit_transfer (OUT) failed: {}", rc);
        if rc == -4 {
            // LIBUSB_ERROR_NO_DEVICE
            shared.stop_flag.store(true, Ordering::Release);
        }
        return false;
    }
    true
}

extern "system" fn iso_out_callback(transfer: *mut libusb_transfer) {
    unsafe {
        if transfer.is_null() {
            return;
        }
        let slot_ptr = (*transfer).user_data as *mut IsoOutSlot;
        if slot_ptr.is_null() {
            return;
        }
        let slot = &mut *slot_ptr;
        let shared = &slot.shared;
        shared.in_flight.fetch_sub(1, Ordering::AcqRel);

        let status = (*transfer).status;
        if status == LIBUSB_TRANSFER_COMPLETED {
            if !shared.paused_flag.load(Ordering::Acquire) {
                if let Some(&played) = slot.frame_counts.first() {
                    if played > 0 {
                        shared
                            .played_frames
                            .fetch_add(played as u64, Ordering::Relaxed);
                    }
                }
            }
        } else if status == LIBUSB_TRANSFER_NO_DEVICE {
            log::warn!("[UsbAudio] USB device disconnected during ISO OUT transfer");
            shared.stop_flag.store(true, Ordering::Release);
            return;
        } else if status == LIBUSB_TRANSFER_CANCELLED {
            return;
        }

        if !shared.stop_flag.load(Ordering::Acquire) {
            let dev_handle = (*transfer).dev_handle;
            let _ = fill_and_submit_out_slot(slot, dev_handle);
        }
    }
}

extern "system" fn iso_feedback_callback(transfer: *mut libusb_transfer) {
    unsafe {
        if transfer.is_null() {
            return;
        }
        let slot_ptr = (*transfer).user_data as *mut IsoFeedbackSlot;
        if slot_ptr.is_null() {
            return;
        }
        let slot = &mut *slot_ptr;
        let shared = &slot.shared;
        shared.in_flight.fetch_sub(1, Ordering::AcqRel);

        let status = (*transfer).status;
        if status == LIBUSB_TRANSFER_COMPLETED {
            let desc = &*(*transfer).iso_packet_desc.as_ptr();
            let actual = desc.actual_length as usize;
            if shared.is_high_speed && actual >= 4 {
                // High-speed 16.16 fixed-point frames per microframe (125 us).
                let raw = u32::from_le_bytes([
                    slot.buffer[0],
                    slot.buffer[1],
                    slot.buffer[2],
                    slot.buffer[3],
                ]);
                let frames_per_uframe = (raw as f64) / 65536.0;
                let uframes_per_packet = (shared.service_interval_us / 125).max(1) as f64;
                shared
                    .scheduler
                    .lock()
                    .update_feedback_frames_per_packet(frames_per_uframe * uframes_per_packet);
            } else if !shared.is_high_speed && actual >= 3 {
                // Full-speed 10.14 fixed-point frames per ms (1000 us).
                let raw = u32::from_le_bytes([slot.buffer[0], slot.buffer[1], slot.buffer[2], 0]);
                let frames_per_ms = (raw as f64) / 16384.0;
                let ms_per_packet = (shared.service_interval_us / 1000).max(1) as f64;
                shared
                    .scheduler
                    .lock()
                    .update_feedback_frames_per_packet(frames_per_ms * ms_per_packet);
            }
        } else if status == LIBUSB_TRANSFER_NO_DEVICE || status == LIBUSB_TRANSFER_CANCELLED {
            return;
        }

        if !shared.stop_flag.load(Ordering::Acquire) {
            if let Some(fb_ep) = shared.feedback_endpoint {
                let len = slot.buffer.len();
                libusb_fill_iso_transfer(
                    slot.transfer,
                    (*transfer).dev_handle,
                    fb_ep,
                    slot.buffer.as_mut_ptr(),
                    len as c_int,
                    1,
                    iso_feedback_callback,
                    slot_ptr as *mut c_void,
                    ISO_TRANSFER_TIMEOUT_MS,
                );
                (*(*slot.transfer).iso_packet_desc.as_mut_ptr()).length = len as c_uint;
                shared.in_flight.fetch_add(1, Ordering::AcqRel);
                if libusb_submit_transfer(slot.transfer) != 0 {
                    shared.in_flight.fetch_sub(1, Ordering::AcqRel);
                }
            }
        }
    }
}

fn stop_active_stream_locked(state: &mut GlobalUsbState) {
    *PCM_PRODUCER.lock() = None;
    state.producer = None;

    if let Some(mut active) = state.stream.take() {
        active.shared.stop_flag.store(true, Ordering::Release);
        if let Some(handle) = active.event_thread.take() {
            let _ = handle.join();
        }
        if let Some(dev) = state.device.as_ref() {
            let _ = dev
                .handle
                .set_alternate_setting(active.streaming_interface, 0);
        }
    }
}

/// Register an Android USB DAC file descriptor and immediately claim all audio
/// interfaces (detaching `snd-usb-audio` so other apps have no sound).
pub fn register_device(
    fd: RawFd,
    vendor_id: u16,
    product_id: u16,
    device_name: String,
) -> Result<UsbExclusiveStatus, String> {
    let mut state = USB_STATE.lock();
    stop_active_stream_locked(&mut state);
    if let Some(old) = state.device.take() {
        release_interfaces_and_restore_kernel(&old.handle, &old.claimed_interfaces);
    }

    init_libusb_for_android();

    let owned_fd = OwnedFd::duplicate(fd)?;
    let context =
        Context::new().map_err(|e| format!("Failed to create libusb context: {}", e))?;
    let handle = unsafe { context.open_device_with_fd(owned_fd.raw()) }
        .map_err(|e| format!("libusb open_device_with_fd({}) failed: {}", owned_fd.raw(), e))?;

    if supports_detach_kernel_driver() {
        let _ = handle.set_auto_detach_kernel_driver(true);
    }

    let device = handle.device();
    let speed = device.speed();
    let config = device
        .active_config_descriptor()
        .map_err(|e| format!("Failed to read USB active config descriptor: {}", e))?;

    let mut parsed = parse_usb_audio_device(&config, speed)?;

    // Claim all AudioControl & AudioStreaming interfaces right away so kernel
    // `snd-usb-audio` (or any stale `usbfs` claim) is detached before issuing
    // class-specific control transfers.
    let mut claimed = Vec::new();
    for &iface in &parsed.all_audio_interfaces {
        if let Err(err) = claim_interface_force(&handle, owned_fd.raw(), iface) {
            release_interfaces_and_restore_kernel(&handle, &claimed);
            state.last_error = Some(err.clone());
            return Err(err);
        }
        claimed.push(iface);
    }

    // Query UAC 2.0 clock rates after claiming AudioControl so `snd-usb-audio`
    // does not interfere with the RANGE control transfer.
    refresh_uac2_clock_rates(&handle, &mut parsed);

    log::info!(
        "[UsbAudio] Registered exclusive USB DAC: {} ({:04x}:{:04x}) {:?}, {} candidates, claimed={:?}",
        device_name,
        vendor_id,
        product_id,
        parsed.uac_version,
        parsed.candidates.len(),
        claimed
    );

    state.device = Some(RegisteredDevice {
        _owned_fd: owned_fd,
        context,
        handle,
        vendor_id,
        product_id,
        device_name,
        parsed,
        claimed_interfaces: claimed,
    });
    state.active_candidate = None;
    state.configured_sample_rate = 0;
    state.configured_channels = 0;
    state.last_error = None;

    Ok(build_status_locked(&state))
}

/// Release the USB DAC and re-attach the Linux kernel audio driver.
pub fn clear_device() {
    let mut state = USB_STATE.lock();
    stop_active_stream_locked(&mut state);
    if let Some(dev) = state.device.take() {
        release_interfaces_and_restore_kernel(&dev.handle, &dev.claimed_interfaces);
        log::info!(
            "[UsbAudio] Released exclusive USB DAC: {} ({:04x}:{:04x})",
            dev.device_name,
            dev.vendor_id,
            dev.product_id
        );
    }
    state.active_candidate = None;
    state.configured_sample_rate = 0;
    state.configured_channels = 0;
}

/// Recover a USB Audio DAC left without `snd-usb-audio` (or with a stale
/// `"usbfs"` claim) after the previous app process was force-stopped while in
/// exclusive mode.
///
/// Returns `Ok(true)` if at least one audio interface was re-attached to the
/// kernel audio driver.
pub fn restore_kernel_driver(fd: RawFd) -> Result<bool, String> {
    init_libusb_for_android();

    let owned_fd = OwnedFd::duplicate(fd)?;
    let context =
        Context::new().map_err(|e| format!("Failed to create libusb context: {}", e))?;
    let handle = unsafe { context.open_device_with_fd(owned_fd.raw()) }
        .map_err(|e| format!("libusb open_device_with_fd({}) failed: {}", owned_fd.raw(), e))?;

    let config = handle
        .device()
        .active_config_descriptor()
        .map_err(|e| format!("Failed to read USB active config descriptor: {}", e))?;

    let mut audio_interfaces = Vec::new();
    for interface in config.interfaces() {
        let iface_num = interface.number();
        if interface
            .descriptors()
            .any(|d| d.class_code() == USB_CLASS_AUDIO)
        {
            audio_interfaces.push(iface_num);
        }
    }
    audio_interfaces.sort_unstable();
    audio_interfaces.dedup();

    if audio_interfaces.is_empty() {
        drop(handle);
        drop(context);
        return Ok(false);
    }

    // Pass 1: disconnect any stale `usbfs` claims across all audio interfaces
    // before re-attaching `snd-usb-audio`, since probing AudioControl (iface 0)
    // also claims the associated AudioStreaming interfaces.
    for &iface in &audio_interfaces {
        if matches!(
            query_usbfs_driver_name(owned_fd.raw(), iface).as_deref(),
            Ok("usbfs")
        ) {
            let res = force_disconnect_usbfs_driver(owned_fd.raw(), iface);
            log::info!(
                "[UsbAudio] restore_kernel_driver: disconnected stale usbfs on iface={} -> {:?}",
                iface,
                res,
            );
        }
    }

    // Pass 2: re-attach kernel driver (`snd-usb-audio`) on any unbound audio interface.
    let mut restored_any = false;
    for &iface in &audio_interfaces {
        match query_usbfs_driver_name(owned_fd.raw(), iface) {
            Ok(drv) if drv != "usbfs" => {
                // Already bound to a kernel driver (e.g. `snd-usb-audio`).
            }
            _ => {
                let res = force_connect_usbfs_driver(owned_fd.raw(), iface);
                log::info!(
                    "[UsbAudio] restore_kernel_driver: USBDEVFS_CONNECT iface={} -> {:?}",
                    iface,
                    res,
                );
                if res.is_ok() {
                    restored_any = true;
                }
            }
        }
    }

    drop(handle);
    drop(context);
    Ok(restored_any)
}

/// Configure DAC alt-setting and clock rate for the incoming ExoPlayer PCM format.
pub fn configure_stream(
    sample_rate: u32,
    channels: u16,
    preferred_bit_depth: u8,
) -> Result<(), String> {
    let mut state = USB_STATE.lock();
    stop_active_stream_locked(&mut state);

    let dev = state
        .device
        .as_ref()
        .ok_or_else(|| "No exclusive USB DAC registered".to_string())?;

    let candidate = select_best_candidate(
        &dev.parsed.candidates,
        sample_rate,
        channels,
        preferred_bit_depth,
    )
    .cloned()
    .ok_or_else(|| "No compatible USB Audio alt-setting found".to_string())?;

    dev.handle
        .set_alternate_setting(candidate.streaming_interface, candidate.alt_setting)
        .map_err(|e| {
            format!(
                "set_alternate_setting(iface={}, alt={}) failed: {}",
                candidate.streaming_interface, candidate.alt_setting, e
            )
        })?;

    configure_sample_rate(&dev.handle, &candidate, sample_rate)?;

    log::info!(
        "[UsbAudio] Configured stream: {} Hz, {} ch, {}-bit (subslot={}B), ep=0x{:02x}, fb={:?}, interval={}us",
        sample_rate,
        candidate.channels,
        candidate.bit_resolution,
        candidate.subslot_size,
        candidate.out_endpoint,
        candidate.feedback_endpoint,
        candidate.service_interval_us
    );

    state.active_candidate = Some(candidate);
    state.configured_sample_rate = sample_rate;
    state.configured_channels = channels;
    state.last_error = None;
    Ok(())
}

/// Start the asynchronous isochronous transfer loop.
pub fn start_stream() -> Result<(), String> {
    let mut state = USB_STATE.lock();
    if state.stream.is_some() {
        if let Some(active) = state.stream.as_ref() {
            active.shared.paused_flag.store(false, Ordering::Release);
        }
        return Ok(());
    }

    let candidate = state
        .active_candidate
        .clone()
        .ok_or_else(|| "USB stream not configured".to_string())?;
    let sample_rate = state.configured_sample_rate;
    if sample_rate == 0 {
        return Err("USB stream sample rate is 0".to_string());
    }

    let dev = state
        .device
        .as_ref()
        .ok_or_else(|| "No exclusive USB DAC registered".to_string())?;

    let raw_handle = dev.handle.as_raw() as usize;
    let raw_ctx = dev.context.as_raw() as usize;

    let ring_frames = (sample_rate as usize * RING_BUFFER_DURATION_MS / 1000).max(4096);
    let ring_samples = ring_frames * candidate.channels as usize;
    let (producer, consumer) = rtrb::RingBuffer::<f32>::new(ring_samples);

    let bytes_per_frame = candidate.channels as usize * candidate.subslot_size as usize;
    let scheduler = IsoPacketScheduler::new(sample_rate, bytes_per_frame, candidate.service_interval_us);
    let packets_per_transfer = scheduler.packets_per_transfer();

    let shared = Arc::new(StreamShared {
        stop_flag: AtomicBool::new(false),
        paused_flag: AtomicBool::new(false),
        flush_flag: AtomicBool::new(false),
        in_flight: AtomicUsize::new(0),
        played_frames: AtomicU64::new(0),
        underrun_count: AtomicU64::new(0),
        volume_bits: AtomicU32::new(state.volume.to_bits()),
        sample_rate,
        channels: candidate.channels,
        subslot_size: candidate.subslot_size,
        bit_resolution: candidate.bit_resolution,
        is_high_speed: candidate.is_high_speed,
        service_interval_us: candidate.service_interval_us,
        out_endpoint: candidate.out_endpoint,
        feedback_endpoint: candidate.feedback_endpoint,
        feedback_max_packet_size: candidate.feedback_max_packet_size,
        consumer: Mutex::new(consumer),
        scheduler: Mutex::new(scheduler),
        scratch_f32: Mutex::new(vec![0.0; 8192]),
    });

    *PCM_PRODUCER.lock() = Some(producer);

    let shared_for_thread = Arc::clone(&shared);
    let event_thread = thread::Builder::new()
        .name("usb-iso-audio".to_string())
        .spawn(move || {
            unsafe {
                // Boost thread priority slightly on Android for smooth isochronous timing.
                libc::setpriority(libc::PRIO_PROCESS, 0, -16);

                let dev_handle = raw_handle as *mut libusb1_sys::libusb_device_handle;
                let ctx_raw = raw_ctx as *mut libusb1_sys::libusb_context;

                let mut out_slots: Vec<Box<IsoOutSlot>> =
                    Vec::with_capacity(ISO_TRANSFER_QUEUE_DEPTH);
                for _ in 0..ISO_TRANSFER_QUEUE_DEPTH {
                    let transfer = libusb_alloc_transfer(packets_per_transfer as c_int);
                    if transfer.is_null() {
                        log::error!("[UsbAudio] libusb_alloc_transfer (OUT) returned null");
                        break;
                    }
                    let mut slot = Box::new(IsoOutSlot {
                        shared: Arc::clone(&shared_for_thread),
                        transfer,
                        buffer: vec![0u8; packets_per_transfer * 1024],
                        frame_counts: Vec::with_capacity(packets_per_transfer),
                    });
                    if fill_and_submit_out_slot(&mut slot, dev_handle) {
                        out_slots.push(slot);
                    } else {
                        libusb_free_transfer(transfer);
                    }
                }

                // Optional Explicit Feedback IN transfer.
                let mut fb_slot: Option<Box<IsoFeedbackSlot>> = None;
                if let Some(fb_ep) = shared_for_thread.feedback_endpoint {
                    let fb_transfer = libusb_alloc_transfer(1);
                    if !fb_transfer.is_null() {
                        let fb_len = (shared_for_thread.feedback_max_packet_size as usize).clamp(4, 16);
                        let mut slot = Box::new(IsoFeedbackSlot {
                            shared: Arc::clone(&shared_for_thread),
                            transfer: fb_transfer,
                            buffer: vec![0u8; fb_len],
                        });
                        libusb_fill_iso_transfer(
                            slot.transfer,
                            dev_handle,
                            fb_ep,
                            slot.buffer.as_mut_ptr(),
                            fb_len as c_int,
                            1,
                            iso_feedback_callback,
                            (&mut *slot as *mut IsoFeedbackSlot) as *mut c_void,
                            ISO_TRANSFER_TIMEOUT_MS,
                        );
                        (*(*slot.transfer).iso_packet_desc.as_mut_ptr()).length = fb_len as c_uint;
                        shared_for_thread.in_flight.fetch_add(1, Ordering::AcqRel);
                        if libusb_submit_transfer(slot.transfer) == 0 {
                            fb_slot = Some(slot);
                        } else {
                            shared_for_thread.in_flight.fetch_sub(1, Ordering::AcqRel);
                            libusb_free_transfer(fb_transfer);
                        }
                    }
                }

                let mut tv = libc::timeval {
                    tv_sec: 0,
                    tv_usec: 20_000, // 20ms poll slice
                };
                while !shared_for_thread.stop_flag.load(Ordering::Acquire)
                    && shared_for_thread.in_flight.load(Ordering::Acquire) > 0
                {
                    let rc = libusb1_sys::libusb_handle_events_timeout_completed(
                        ctx_raw,
                        &mut tv as *mut libc::timeval,
                        std::ptr::null_mut(),
                    );
                    if rc < 0 && rc != -10 {
                        // Ignore LIBUSB_ERROR_INTERRUPTED (-10)
                        log::warn!("[UsbAudio] libusb_handle_events returned {}", rc);
                        break;
                    }
                }

                // Cancel all in-flight transfers and drain events before freeing memory.
                for slot in &out_slots {
                    let _ = libusb_cancel_transfer(slot.transfer);
                }
                if let Some(ref fb) = fb_slot {
                    let _ = libusb_cancel_transfer(fb.transfer);
                }

                let drain_start = std::time::Instant::now();
                while shared_for_thread.in_flight.load(Ordering::Acquire) > 0
                    && drain_start.elapsed() < Duration::from_millis(500)
                {
                    let mut drain_tv = libc::timeval {
                        tv_sec: 0,
                        tv_usec: 10_000,
                    };
                    let _ = libusb1_sys::libusb_handle_events_timeout_completed(
                        ctx_raw,
                        &mut drain_tv as *mut libc::timeval,
                        std::ptr::null_mut(),
                    );
                }

                for slot in out_slots {
                    libusb_free_transfer(slot.transfer);
                }
                if let Some(fb) = fb_slot {
                    libusb_free_transfer(fb.transfer);
                }
            }
        })
        .map_err(|e| format!("Failed to spawn usb-iso-audio thread: {}", e))?;

    state.stream = Some(ActiveStream {
        shared,
        streaming_interface: candidate.streaming_interface,
        event_thread: Some(event_thread),
    });

    Ok(())
}

pub fn set_paused(paused: bool) {
    let state = USB_STATE.lock();
    if let Some(active) = state.stream.as_ref() {
        active.shared.paused_flag.store(paused, Ordering::Release);
    }
}

pub fn flush_stream() {
    let state = USB_STATE.lock();
    if let Some(active) = state.stream.as_ref() {
        active.shared.flush_flag.store(true, Ordering::Release);
        active.shared.played_frames.store(0, Ordering::Release);
    }
}

pub fn stop_stream() {
    let mut state = USB_STATE.lock();
    stop_active_stream_locked(&mut state);
}

pub fn set_volume(volume: f32) {
    let clamped = volume.clamp(0.0, 1.0);
    let mut state = USB_STATE.lock();
    state.volume = clamped;
    if let Some(active) = state.stream.as_ref() {
        active
            .shared
            .volume_bits
            .store(clamped.to_bits(), Ordering::Relaxed);
    }
}

/// Write interleaved Float32 PCM samples into the ring buffer.
/// Returns the number of float samples actually written (for ExoPlayer backpressure).
pub fn write_float_pcm(samples: &[f32]) -> usize {
    if samples.is_empty() {
        return 0;
    }
    let mut guard = PCM_PRODUCER.lock();
    let Some(producer) = guard.as_mut() else {
        return 0;
    };
    let free = producer.slots();
    if free == 0 {
        return 0;
    }
    let to_write = free.min(samples.len());
    let written = if let Ok(mut chunk) = producer.write_chunk(to_write) {
        let (first, second) = chunk.as_mut_slices();
        let n1 = first.len();
        first.copy_from_slice(&samples[..n1]);
        let n2 = second.len();
        if n2 > 0 {
            second.copy_from_slice(&samples[n1..n1 + n2]);
        }
        chunk.commit_all();
        n1 + n2
    } else {
        0
    };
    written
}

pub fn get_played_frames() -> u64 {
    let state = USB_STATE.lock();
    state
        .stream
        .as_ref()
        .map(|s| s.shared.played_frames.load(Ordering::Relaxed))
        .unwrap_or(0)
}

pub fn get_buffered_frames() -> u64 {
    let channels = {
        let state = USB_STATE.lock();
        state.configured_channels.max(1) as usize
    };
    let guard = PCM_PRODUCER.lock();
    let Some(producer) = guard.as_ref() else {
        return 0;
    };
    let cap = producer.buffer().capacity();
    let free = producer.slots();
    (cap.saturating_sub(free) / channels) as u64
}

fn build_status_locked(state: &GlobalUsbState) -> UsbExclusiveStatus {
    let Some(dev) = state.device.as_ref() else {
        return UsbExclusiveStatus {
            last_error: state.last_error.clone(),
            ..Default::default()
        };
    };

    let supported_sample_rates = dev
        .parsed
        .candidates
        .first()
        .map(|c| c.sample_rates.clone())
        .unwrap_or_default();

    let (bit_depth, subslot_size, has_fb) = state
        .active_candidate
        .as_ref()
        .map(|c| (c.bit_resolution, c.subslot_size, c.feedback_endpoint.is_some()))
        .unwrap_or((0, 0, false));

    let (stream_running, paused, played_frames, underrun_count) = state
        .stream
        .as_ref()
        .map(|s| {
            (
                !s.shared.stop_flag.load(Ordering::Relaxed),
                s.shared.paused_flag.load(Ordering::Relaxed),
                s.shared.played_frames.load(Ordering::Relaxed),
                s.shared.underrun_count.load(Ordering::Relaxed),
            )
        })
        .unwrap_or((false, false, 0, 0));

    let buffered_frames = {
        let ch = state.configured_channels.max(1) as usize;
        PCM_PRODUCER
            .lock()
            .as_ref()
            .map(|p| (p.buffer().capacity().saturating_sub(p.slots()) / ch) as u64)
            .unwrap_or(0)
    };

    UsbExclusiveStatus {
        exclusive_active: true,
        stream_running,
        paused,
        device_name: dev.device_name.clone(),
        vendor_id: dev.vendor_id,
        product_id: dev.product_id,
        uac_version: match dev.parsed.uac_version {
            UacVersion::Uac1 => "UAC 1.0".to_string(),
            UacVersion::Uac2 => "UAC 2.0".to_string(),
        },
        sample_rate: state.configured_sample_rate,
        channels: state.configured_channels,
        bit_depth,
        subslot_size,
        has_feedback_endpoint: has_fb,
        played_frames,
        buffered_frames,
        underrun_count,
        supported_sample_rates,
        last_error: state.last_error.clone(),
    }
}

pub fn get_status_json() -> String {
    let state = USB_STATE.lock();
    let status = build_status_locked(&state);
    serde_json::to_string(&status).unwrap_or_else(|_| "{}".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn perceptual_gain_handles_boundaries_and_non_finite() {
        assert_eq!(volume_to_perceptual_gain(0.0), 0.0);
        assert_eq!(volume_to_perceptual_gain(-0.5), 0.0);
        assert_eq!(volume_to_perceptual_gain(f32::NAN), 0.0);
        assert_eq!(volume_to_perceptual_gain(f32::NEG_INFINITY), 0.0);
        assert_eq!(volume_to_perceptual_gain(f32::INFINITY), 0.0);

        assert_eq!(volume_to_perceptual_gain(1.0), 1.0);
        assert_eq!(volume_to_perceptual_gain(1.5), 1.0);
    }

    #[test]
    fn perceptual_gain_follows_60db_logarithmic_curve() {
        // 50% -> -30 dB => 10^(-1.5) ≈ 0.03162278
        let half = volume_to_perceptual_gain(0.5);
        assert!((half - 10.0_f32.powf(-1.5)).abs() < 1e-5);

        // 25% -> -45 dB => 10^(-2.25) ≈ 0.00562341
        let quarter = volume_to_perceptual_gain(0.25);
        assert!((quarter - 10.0_f32.powf(-2.25)).abs() < 1e-5);

        // Strictly monotonic over (0, 1].
        let mut prev = volume_to_perceptual_gain(0.0);
        for step in 1..=100 {
            let cur = volume_to_perceptual_gain(step as f32 / 100.0);
            assert!(cur > prev, "gain must increase at step={step}");
            prev = cur;
        }
    }

    #[test]
    fn pack_f32_to_wire_applies_unity_and_perceptual_scaling() {
        let samples = [1.0_f32, -1.0_f32];

        // Unity gain (100%): exact full-scale 16-bit output.
        let mut out_full = [0u8; 4];
        pack_f32_to_wire(&samples, 2, 16, 1.0, &mut out_full);
        assert_eq!(i16::from_le_bytes([out_full[0], out_full[1]]), 32767);
        assert_eq!(i16::from_le_bytes([out_full[2], out_full[3]]), -32767);

        // 50% UI volume: attenuated by -30 dB (~1036 out of 32767).
        let mut out_half = [0u8; 4];
        pack_f32_to_wire(&samples, 2, 16, 0.5, &mut out_half);
        let expected_half = (10.0_f32.powf(-1.5) * 32767.0).round() as i16;
        assert_eq!(i16::from_le_bytes([out_half[0], out_half[1]]), expected_half);
        assert_eq!(i16::from_le_bytes([out_half[2], out_half[3]]), -expected_half);

        // 0% UI volume: strict digital silence.
        let mut out_mute = [0xffu8; 4];
        pack_f32_to_wire(&samples, 2, 16, 0.0, &mut out_mute);
        assert_eq!(out_mute, [0, 0, 0, 0]);
    }
}
