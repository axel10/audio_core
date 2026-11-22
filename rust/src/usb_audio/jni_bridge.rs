//! JNI bindings for `com.flutter_rust_bridge.audio_core.UsbExclusiveNative`.
//! Compatible with `jni = "0.21.1"`.

use crate::usb_audio::engine;
use jni::objects::{JByteBuffer, JClass, JString};
use jni::sys::{jboolean, jfloat, jint, jlong, jstring, JNI_FALSE, JNI_TRUE};
use jni::JNIEnv;

fn string_to_jstring(env: &JNIEnv, s: &str) -> jstring {
    env.new_string(s)
        .map(|js| js.into_raw())
        .unwrap_or(std::ptr::null_mut())
}

#[no_mangle]
pub extern "system" fn Java_com_flutter_1rust_1bridge_audio_1core_UsbExclusiveNative_nativeRegisterDevice(
    mut env: JNIEnv,
    _class: JClass,
    fd: jint,
    vendor_id: jint,
    product_id: jint,
    device_name: JString,
) -> jstring {
    let name: String = env
        .get_string(&device_name)
        .map(|s| s.into())
        .unwrap_or_else(|_| "USB Audio DAC".to_string());

    let result_json = match engine::register_device(fd, vendor_id as u16, product_id as u16, name) {
        Ok(status) => serde_json::json!({
            "ok": true,
            "status": status
        })
        .to_string(),
        Err(err) => serde_json::json!({
            "ok": false,
            "error": err
        })
        .to_string(),
    };

    string_to_jstring(&env, &result_json)
}

#[no_mangle]
pub extern "system" fn Java_com_flutter_1rust_1bridge_audio_1core_UsbExclusiveNative_nativeClearDevice(
    _env: JNIEnv,
    _class: JClass,
) {
    engine::clear_device();
}

#[no_mangle]
pub extern "system" fn Java_com_flutter_1rust_1bridge_audio_1core_UsbExclusiveNative_nativeRestoreKernelDriver(
    _env: JNIEnv,
    _class: JClass,
    fd: jint,
) -> jboolean {
    match engine::restore_kernel_driver(fd) {
        Ok(restored) => {
            if restored {
                JNI_TRUE
            } else {
                JNI_FALSE
            }
        }
        Err(err) => {
            log::warn!("[UsbAudio] nativeRestoreKernelDriver error: {}", err);
            JNI_FALSE
        }
    }
}

#[no_mangle]
pub extern "system" fn Java_com_flutter_1rust_1bridge_audio_1core_UsbExclusiveNative_nativeConfigureStream(
    _env: JNIEnv,
    _class: JClass,
    sample_rate: jint,
    channels: jint,
    preferred_bit_depth: jint,
) -> jboolean {
    if sample_rate <= 0 || channels <= 0 {
        return JNI_FALSE;
    }
    match engine::configure_stream(
        sample_rate as u32,
        channels as u16,
        preferred_bit_depth.clamp(16, 32) as u8,
    ) {
        Ok(()) => JNI_TRUE,
        Err(err) => {
            log::error!("[UsbAudio] nativeConfigureStream error: {}", err);
            JNI_FALSE
        }
    }
}

#[no_mangle]
pub extern "system" fn Java_com_flutter_1rust_1bridge_audio_1core_UsbExclusiveNative_nativeStartStream(
    _env: JNIEnv,
    _class: JClass,
) -> jboolean {
    match engine::start_stream() {
        Ok(()) => JNI_TRUE,
        Err(err) => {
            log::error!("[UsbAudio] nativeStartStream error: {}", err);
            JNI_FALSE
        }
    }
}

#[no_mangle]
pub extern "system" fn Java_com_flutter_1rust_1bridge_audio_1core_UsbExclusiveNative_nativeSetPaused(
    _env: JNIEnv,
    _class: JClass,
    paused: jboolean,
) {
    engine::set_paused(paused != JNI_FALSE);
}

#[no_mangle]
pub extern "system" fn Java_com_flutter_1rust_1bridge_audio_1core_UsbExclusiveNative_nativeFlushStream(
    _env: JNIEnv,
    _class: JClass,
) {
    engine::flush_stream();
}

#[no_mangle]
pub extern "system" fn Java_com_flutter_1rust_1bridge_audio_1core_UsbExclusiveNative_nativeStopStream(
    _env: JNIEnv,
    _class: JClass,
) {
    engine::stop_stream();
}

#[no_mangle]
pub extern "system" fn Java_com_flutter_1rust_1bridge_audio_1core_UsbExclusiveNative_nativeSetVolume(
    _env: JNIEnv,
    _class: JClass,
    volume: jfloat,
) {
    engine::set_volume(volume);
}

/// Zero-copy write of interleaved Float32 PCM from a DirectByteBuffer.
/// Returns the number of bytes actually consumed (aligned to 4-byte float samples).
#[no_mangle]
pub extern "system" fn Java_com_flutter_1rust_1bridge_audio_1core_UsbExclusiveNative_nativeWriteFloatPcm(
    env: JNIEnv,
    _class: JClass,
    buffer: JByteBuffer,
    offset_bytes: jint,
    length_bytes: jint,
) -> jint {
    if offset_bytes < 0 || length_bytes <= 0 {
        return 0;
    }
    let ptr = match env.get_direct_buffer_address(&buffer) {
        Ok(p) => p,
        Err(_) => return 0,
    };
    let cap = match env.get_direct_buffer_capacity(&buffer) {
        Ok(c) => c,
        Err(_) => return 0,
    };

    let off = offset_bytes as usize;
    let len = length_bytes as usize;
    if off.saturating_add(len) > cap {
        return 0;
    }

    let sample_count = len / 4;
    if sample_count == 0 {
        return 0;
    }

    let float_slice = unsafe {
        let base = ptr.add(off) as *const f32;
        std::slice::from_raw_parts(base, sample_count)
    };

    let written_samples = engine::write_float_pcm(float_slice);
    (written_samples * 4) as jint
}

#[no_mangle]
pub extern "system" fn Java_com_flutter_1rust_1bridge_audio_1core_UsbExclusiveNative_nativeGetPlayedFrames(
    _env: JNIEnv,
    _class: JClass,
) -> jlong {
    engine::get_played_frames() as jlong
}

#[no_mangle]
pub extern "system" fn Java_com_flutter_1rust_1bridge_audio_1core_UsbExclusiveNative_nativeGetBufferedFrames(
    _env: JNIEnv,
    _class: JClass,
) -> jlong {
    engine::get_buffered_frames() as jlong
}

#[no_mangle]
pub extern "system" fn Java_com_flutter_1rust_1bridge_audio_1core_UsbExclusiveNative_nativeGetStatusJson(
    env: JNIEnv,
    _class: JClass,
) -> jstring {
    let json = engine::get_status_json();
    string_to_jstring(&env, &json)
}
