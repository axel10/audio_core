#[cfg(target_os = "windows")]
pub(crate) mod wasapi_impl {
    use crate::api::simple::controller::AudioDeviceDesc;
    use log::{error, info, warn};
    use rodio::mixer::{mixer, Mixer};
    use std::mem::size_of;
    use std::num::NonZero;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;
    use std::thread::{self, JoinHandle};

    use windows::core::{GUID, PCWSTR, PWSTR};
    use windows::Win32::Foundation::{CloseHandle, HANDLE, WAIT_OBJECT_0};
    use windows::Win32::Media::Audio::*;
    use windows::Win32::System::Com::StructuredStorage::PropVariantClear;
    use windows::Win32::System::Com::*;
    use windows::Win32::System::Threading::{
        CreateEventW, GetCurrentThread, SetEvent, SetThreadPriority, WaitForSingleObject,
        THREAD_PRIORITY_TIME_CRITICAL,
    };
    use windows::Win32::System::Variant::VT_LPWSTR;
    use windows::Win32::UI::Shell::PropertiesSystem::PROPERTYKEY;

    pub(crate) const PKEY_DEVICE_FRIENDLY_NAME: PROPERTYKEY = PROPERTYKEY {
        fmtid: GUID::from_u128(0xa45c254e_df1c_4efd_8020_67d146a850e0),
        pid: 14,
    };

    pub(crate) const KSDATAFORMAT_SUBTYPE_PCM: GUID =
        GUID::from_u128(0x00000001_0000_0010_8000_00aa00389b71);
    pub(crate) const KSDATAFORMAT_SUBTYPE_IEEE_FLOAT: GUID =
        GUID::from_u128(0x00000003_0000_0010_8000_00aa00389b71);

    pub(crate) struct ComSend<T>(pub(crate) T);
    unsafe impl<T> Send for ComSend<T> {}
    impl<T> ComSend<T> {
        pub(crate) fn into_inner(self) -> T {
            self.0
        }
    }

    pub(crate) const WAVE_FORMAT_EXTENSIBLE_TAG: u16 = 0xFFFE;

    #[inline]
    fn win_err(op: &str, e: windows::core::Error) -> String {
        format!("{op} failed (HRESULT: 0x{:08X})", e.code().0 as u32)
    }

    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub(crate) enum SampleType {
        Float32,
        Int32,
        Int24In32,
        Int24In24,
        Int16,
    }

    #[derive(Clone)]
    pub(crate) struct WasapiFormatConfig {
        pub(crate) sample_rate: u32,
        pub(crate) channels: u16,
        pub(crate) bit_depth: u16,
        pub(crate) sample_type: SampleType,
        pub(crate) wave_format: WAVEFORMATEXTENSIBLE,
    }

    unsafe fn get_device_friendly_name(dev: &IMMDevice, fallback: &str) -> String {
        if let Ok(props) = dev.OpenPropertyStore(STGM_READ) {
            if let Ok(mut var) = props.GetValue(&PKEY_DEVICE_FRIENDLY_NAME) {
                let mut result = None;
                if var.Anonymous.Anonymous.vt == VT_LPWSTR {
                    let ptr = var.Anonymous.Anonymous.Anonymous.pwszVal;
                    if !ptr.is_null() {
                        result = ptr.to_string().ok();
                    }
                }
                let _ = PropVariantClear(&mut var);
                if let Some(name) = result {
                    if !name.trim().is_empty() {
                        return name;
                    }
                }
            }
        }
        fallback.to_string()
    }

    pub(crate) fn enumerate_wasapi_render_devices() -> Result<Vec<AudioDeviceDesc>, String> {
        unsafe {
            let _ = CoInitializeEx(None, COINIT_MULTITHREADED);

            let enumerator: IMMDeviceEnumerator =
                CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL)
                    .map_err(|e| win_err("create MMDeviceEnumerator", e))?;

            let default_id = enumerator
                .GetDefaultAudioEndpoint(eRender, eConsole)
                .and_then(|dev| dev.GetId())
                .map(|pwstr| pwstr_to_string(pwstr))
                .unwrap_or_default();

            let collection: IMMDeviceCollection = enumerator
                .EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE)
                .map_err(|e| win_err("enum audio endpoints", e))?;

            let count = collection
                .GetCount()
                .map_err(|e| win_err("get device count", e))?;

            let mut devices = Vec::with_capacity(count as usize);

            for i in 0..count {
                if let Ok(device) = collection.Item(i) {
                    if let Ok(pwstr_id) = device.GetId() {
                        let id = pwstr_to_string(pwstr_id);
                        let is_default = !default_id.is_empty() && id == default_id;
                        let fallback_name = format!("Audio Device {}", i + 1);
                        let name = get_device_friendly_name(&device, &fallback_name);

                        devices.push(AudioDeviceDesc {
                            id,
                            name,
                            is_default,
                        });
                    }
                }
            }

            Ok(devices)
        }
    }

    unsafe fn pwstr_to_string(pwstr: PWSTR) -> String {
        if pwstr.is_null() {
            String::new()
        } else {
            pwstr.to_string().unwrap_or_default()
        }
    }

    fn create_waveformat_extensible(
        sample_rate: u32,
        channels: u16,
        sample_type: SampleType,
    ) -> (WAVEFORMATEXTENSIBLE, u16) {
        let (bits_per_sample, valid_bits, sub_format, container_bytes) = match sample_type {
            SampleType::Float32 => (32, 32, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT, 4),
            SampleType::Int32 => (32, 32, KSDATAFORMAT_SUBTYPE_PCM, 4),
            SampleType::Int24In32 => (32, 24, KSDATAFORMAT_SUBTYPE_PCM, 4),
            SampleType::Int24In24 => (24, 24, KSDATAFORMAT_SUBTYPE_PCM, 3),
            SampleType::Int16 => (16, 16, KSDATAFORMAT_SUBTYPE_PCM, 2),
        };

        let block_align = channels * container_bytes;
        let avg_bytes_per_sec = sample_rate * block_align as u32;

        let channel_mask = match channels {
            1 => 0x04, // SPEAKER_FRONT_CENTER
            2 => 0x03, // SPEAKER_FRONT_LEFT | SPEAKER_FRONT_RIGHT
            4 => 0x33, // Quad
            6 => 0x3F, // 5.1
            8 => 0x63F, // 7.1
            _ => 0,
        };

        let format = WAVEFORMATEXTENSIBLE {
            Format: WAVEFORMATEX {
                wFormatTag: WAVE_FORMAT_EXTENSIBLE_TAG,
                nChannels: channels,
                nSamplesPerSec: sample_rate,
                nAvgBytesPerSec: avg_bytes_per_sec,
                nBlockAlign: block_align,
                wBitsPerSample: bits_per_sample,
                cbSize: (size_of::<WAVEFORMATEXTENSIBLE>() - size_of::<WAVEFORMATEX>()) as u16,
            },
            Samples: WAVEFORMATEXTENSIBLE_0 {
                wValidBitsPerSample: valid_bits,
            },
            dwChannelMask: channel_mask,
            SubFormat: sub_format,
        };

        (format, valid_bits)
    }

    fn probe_exclusive_format(
        audio_client: &IAudioClient,
        target_sample_rate: u32,
        channels: u16,
    ) -> Result<WasapiFormatConfig, String> {
        let candidates = [
            SampleType::Float32,
            SampleType::Int24In32,
            SampleType::Int32,
            SampleType::Int24In24,
            SampleType::Int16,
        ];

        for &st in &candidates {
            let (wf_ext, bit_depth) = create_waveformat_extensible(target_sample_rate, channels, st);
            let p_wf = &wf_ext as *const _ as *const WAVEFORMATEX;

            unsafe {
                if audio_client
                    .IsFormatSupported(AUDCLNT_SHAREMODE_EXCLUSIVE, p_wf, None)
                    .is_ok()
                {
                    info!(
                        "[WasapiExclusive] Matched hardware format: {}Hz, {}ch, {:?}, {}bit",
                        target_sample_rate, channels, st, bit_depth
                    );
                    return Ok(WasapiFormatConfig {
                        sample_rate: target_sample_rate,
                        channels,
                        bit_depth,
                        sample_type: st,
                        wave_format: wf_ext,
                    });
                }
            }
        }

        // Fallback sample rates if target is not supported
        let fallback_rates = [48000, 44100, 96000, 192000, 88200, 176400];
        for &rate in &fallback_rates {
            if rate == target_sample_rate {
                continue;
            }
            for &st in &candidates {
                let (wf_ext, bit_depth) = create_waveformat_extensible(rate, channels, st);
                let p_wf = &wf_ext as *const _ as *const WAVEFORMATEX;
                unsafe {
                    if audio_client
                        .IsFormatSupported(AUDCLNT_SHAREMODE_EXCLUSIVE, p_wf, None)
                        .is_ok()
                    {
                        warn!(
                            "[WasapiExclusive] Target {}Hz not supported by DAC, falling back to {}Hz ({:?})",
                            target_sample_rate, rate, st
                        );
                        return Ok(WasapiFormatConfig {
                            sample_rate: rate,
                            channels,
                            bit_depth,
                            sample_type: st,
                            wave_format: wf_ext,
                        });
                    }
                }
            }
        }

        Err(format!(
            "DAC does not support requested audio format ({}Hz, {}ch) in exclusive mode",
            target_sample_rate, channels
        ))
    }

    pub(crate) struct WasapiExclusiveSink {
        mixer: Mixer,
        format_config: WasapiFormatConfig,
        device_name: String,
        stop_signal: Arc<AtomicBool>,
        thread_handle: Option<JoinHandle<()>>,
        event_handle: usize,
    }

    impl WasapiExclusiveSink {
        pub(crate) fn open(
            target_device_id: Option<&str>,
            sample_rate: u32,
            channels: u16,
        ) -> Result<Self, String> {
            unsafe {
                let _ = CoInitializeEx(None, COINIT_MULTITHREADED);

                let enumerator: IMMDeviceEnumerator =
                    CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL)
                        .map_err(|e| win_err("create MMDeviceEnumerator", e))?;

                let (device, device_name) = match target_device_id {
                    Some(id) if !id.trim().is_empty() => {
                        let id_wide: Vec<u16> = id.encode_utf16().chain(std::iter::once(0)).collect();
                        let dev = enumerator
                            .GetDevice(PCWSTR(id_wide.as_ptr()))
                            .map_err(|e| win_err(&format!("get device '{id}'"), e))?;

                        let name = get_device_friendly_name(&dev, id);
                        (dev, name)
                    }
                    _ => {
                        let dev = enumerator
                            .GetDefaultAudioEndpoint(eRender, eConsole)
                            .map_err(|e| win_err("get default audio endpoint", e))?;

                        let name = get_device_friendly_name(&dev, "Default Output Device");
                        (dev, name)
                    }
                };

                let mut audio_client: IAudioClient = device
                    .Activate(CLSCTX_ALL, None)
                    .map_err(|e| win_err("activate IAudioClient", e))?;

                let format_config = probe_exclusive_format(&audio_client, sample_rate, channels)?;

                let mut default_period: i64 = 0;
                let mut min_period: i64 = 0;
                let _ = audio_client.GetDevicePeriod(Some(&mut default_period), Some(&mut min_period));

                let mut buffer_duration = if min_period > 0 {
                    min_period
                } else if default_period > 0 {
                    default_period
                } else {
                    100_000 // 10ms (100,000 in 100-nanosecond units)
                };

                let p_wf = &format_config.wave_format as *const _ as *const WAVEFORMATEX;

                let mut init_res = audio_client.Initialize(
                    AUDCLNT_SHAREMODE_EXCLUSIVE,
                    AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
                    buffer_duration,
                    buffer_duration,
                    p_wf,
                    None,
                );

                // If buffer size not aligned (AUDCLNT_E_BUFFER_SIZE_NOT_ALIGNED = 0x88890019), align and retry
                if let Err(e) = &init_res {
                    if e.code().0 as u32 == 0x88890019 {
                        if let Ok(aligned_frames) = audio_client.GetBufferSize() {
                            buffer_duration = ((10_000_000i64 * aligned_frames as i64)
                                + (sample_rate as i64 / 2))
                                / sample_rate as i64;
                            if let Ok(new_client) = device.Activate::<IAudioClient>(CLSCTX_ALL, None) {
                                audio_client = new_client;
                                init_res = audio_client.Initialize(
                                    AUDCLNT_SHAREMODE_EXCLUSIVE,
                                    AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
                                    buffer_duration,
                                    buffer_duration,
                                    p_wf,
                                    None,
                                );
                            }
                        }
                    }
                }

                init_res.map_err(|e| win_err("IAudioClient Initialize (exclusive)", e))?;

                let event: HANDLE = CreateEventW(None, false, false, None)
                    .map_err(|e| win_err("CreateEventW", e))?;

                audio_client
                    .SetEventHandle(event)
                    .map_err(|e| win_err("SetEventHandle", e))?;

                let render_client: IAudioRenderClient = audio_client
                    .GetService()
                    .map_err(|e| win_err("GetService IAudioRenderClient", e))?;

                let buffer_frame_count = audio_client
                    .GetBufferSize()
                    .map_err(|e| win_err("GetBufferSize", e))?;

                let (mixer_controller, mut mixer_source) = mixer(
                    NonZero::new(format_config.channels).unwrap_or(NonZero::new(2).unwrap()),
                    NonZero::new(format_config.sample_rate).unwrap_or(NonZero::new(44100).unwrap()),
                );

                // In WASAPI Exclusive event-driven mode, pre-fill the entire buffer with silence before calling Start()
                if let Ok(p_init_buffer) = render_client.GetBuffer(buffer_frame_count) {
                    if !p_init_buffer.is_null() {
                        let byte_count = buffer_frame_count as usize
                            * format_config.channels as usize
                            * match format_config.sample_type {
                                SampleType::Float32 | SampleType::Int32 | SampleType::Int24In32 => 4,
                                SampleType::Int24In24 => 3,
                                SampleType::Int16 => 2,
                            };
                        std::ptr::write_bytes(p_init_buffer, 0, byte_count);
                    }
                    let _ = render_client.ReleaseBuffer(buffer_frame_count, 0);
                }

                let stop_signal = Arc::new(AtomicBool::new(false));
                let stop_signal_clone = Arc::clone(&stop_signal);
                let format_config_clone = format_config.clone();
                let event_val = event.0 as usize;

                audio_client
                    .Start()
                    .map_err(|e| win_err("IAudioClient Start", e))?;

                let render_client_send = ComSend(render_client);
                let audio_client_send = ComSend(audio_client);

                let thread_handle = thread::Builder::new()
                    .name("WasapiExclusiveRenderThread".to_string())
                    .spawn(move || {
                        let render_client = render_client_send.into_inner();
                        let audio_client = audio_client_send.into_inner();
                        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
                        let _ = SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_TIME_CRITICAL);

                        let channels = format_config_clone.channels as usize;
                        let sample_type = format_config_clone.sample_type;
                        let frame_size = match sample_type {
                            SampleType::Float32 | SampleType::Int32 | SampleType::Int24In32 => {
                                channels * 4
                            }
                            SampleType::Int24In24 => channels * 3,
                            SampleType::Int16 => channels * 2,
                        };

                        while !stop_signal_clone.load(Ordering::Relaxed) {
                            let wait_res = WaitForSingleObject(HANDLE(event_val as isize), 2000);
                            if wait_res != WAIT_OBJECT_0 {
                                if stop_signal_clone.load(Ordering::Relaxed) {
                                    break;
                                }
                                continue;
                            }

                            if stop_signal_clone.load(Ordering::Relaxed) {
                                break;
                            }

                            let p_data = match render_client.GetBuffer(buffer_frame_count) {
                                Ok(ptr) => ptr,
                                Err(e) => {
                                    error!("[WasapiExclusive] GetBuffer error: 0x{:08X}", e.code().0 as u32);
                                    break;
                                }
                            };

                            if p_data.is_null() {
                                continue;
                            }

                            let total_samples = buffer_frame_count as usize * channels;

                            match sample_type {
                                SampleType::Float32 => {
                                    let slice = std::slice::from_raw_parts_mut(
                                        p_data as *mut f32,
                                        total_samples,
                                    );
                                    for s in slice.iter_mut() {
                                        *s = mixer_source.next().unwrap_or(0.0);
                                    }
                                }
                                SampleType::Int32 => {
                                    let slice = std::slice::from_raw_parts_mut(
                                        p_data as *mut i32,
                                        total_samples,
                                    );
                                    for s in slice.iter_mut() {
                                        let sample = mixer_source.next().unwrap_or(0.0).clamp(-1.0, 1.0);
                                        *s = (sample * 2147483647.0) as i32;
                                    }
                                }
                                SampleType::Int24In32 => {
                                    let slice = std::slice::from_raw_parts_mut(
                                        p_data as *mut i32,
                                        total_samples,
                                    );
                                    for s in slice.iter_mut() {
                                        let sample = mixer_source.next().unwrap_or(0.0).clamp(-1.0, 1.0);
                                        let val24 = (sample * 8388607.0) as i32;
                                        *s = val24 << 8;
                                    }
                                }
                                SampleType::Int24In24 => {
                                    let slice = std::slice::from_raw_parts_mut(
                                        p_data as *mut u8,
                                        buffer_frame_count as usize * frame_size,
                                    );
                                    for chunk in slice.chunks_exact_mut(3) {
                                        let sample = mixer_source.next().unwrap_or(0.0).clamp(-1.0, 1.0);
                                        let val24 = (sample * 8388607.0) as i32;
                                        let bytes = val24.to_le_bytes();
                                        chunk[0] = bytes[0];
                                        chunk[1] = bytes[1];
                                        chunk[2] = bytes[2];
                                    }
                                }
                                SampleType::Int16 => {
                                    let slice = std::slice::from_raw_parts_mut(
                                        p_data as *mut i16,
                                        total_samples,
                                    );
                                    for s in slice.iter_mut() {
                                        let sample = mixer_source.next().unwrap_or(0.0).clamp(-1.0, 1.0);
                                        *s = (sample * 32767.0) as i16;
                                    }
                                }
                            }

                            if let Err(e) = render_client.ReleaseBuffer(buffer_frame_count, 0) {
                                error!("[WasapiExclusive] ReleaseBuffer error: 0x{:08X}", e.code().0 as u32);
                                break;
                            }
                        }

                        let _ = audio_client.Stop();
                        let _ = audio_client.Reset();
                        CoUninitialize();
                    })
                    .map_err(|e| format!("spawn render thread failed: {e}"))?;

                Ok(Self {
                    mixer: mixer_controller,
                    format_config,
                    device_name,
                    stop_signal,
                    thread_handle: Some(thread_handle),
                    event_handle: event_val,
                })
            }
        }

        pub(crate) fn mixer(&self) -> Mixer {
            self.mixer.clone()
        }

        pub(crate) fn format_config(&self) -> &WasapiFormatConfig {
            &self.format_config
        }

        pub(crate) fn device_name(&self) -> &str {
            &self.device_name
        }
    }

    impl Drop for WasapiExclusiveSink {
        fn drop(&mut self) {
            self.stop_signal.store(true, Ordering::Release);
            if self.event_handle != 0 {
                unsafe {
                    let _ = SetEvent(HANDLE(self.event_handle as isize));
                }
            }
            if let Some(handle) = self.thread_handle.take() {
                let _ = handle.join();
            }
            if self.event_handle != 0 {
                unsafe {
                    let _ = CloseHandle(HANDLE(self.event_handle as isize));
                }
                self.event_handle = 0;
            }
        }
    }
}
