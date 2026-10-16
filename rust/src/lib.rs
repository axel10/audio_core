pub mod api;
mod frb_generated;

#[cfg(target_os = "linux")]
#[no_mangle]
pub extern "C" fn log10f(x: f32) -> f32 {
    libm::log10f(x)
}

pub mod audio_converter_internal;

#[cfg(any(
    target_os = "windows",
    target_os = "linux",
    target_os = "macos",
    target_os = "ios"
))]
mod stress_test;

#[cfg(target_os = "android")]
#[no_mangle]
pub extern "C" fn JNI_OnLoad(vm: jni::JavaVM, res: *mut std::os::raw::c_void) -> jni::sys::jint {
    use std::ffi::c_void;

    let vm = vm.get_java_vm_pointer() as *mut c_void;
    unsafe {
        ndk_context::initialize_android_context(vm, res);
    }
    jni::JNIVersion::V6.into()
}

/// Installs the Android log backend with a sane level.
///
/// Must run before `flutter_rust_bridge::setup_default_user_utils()`: frb
/// initializes `android_logger` itself with `LevelFilter::Trace`, and the `jni`
/// crate emits three trace lines per JNI call ("calling unchecked jni method",
/// "looking up jni method", "found jni method"). The playback path hits two
/// direct-buffer calls per audio buffer (`GetDirectBufferAddress` /
/// `GetDirectBufferCapacity` in the equalizer processor), which floods logcat.
///
/// `android_logger::init_once` only takes effect for the first caller, so an
/// explicit `log::set_max_level` is added afterwards to make the threshold
/// independent of init order. `debug!` calls from this crate are kept, hence
/// Debug for debug builds and Info for release builds — the same level the
/// desktop `env_logger` uses.
#[cfg(target_os = "android")]
pub(crate) fn init_platform_logger() {
    let level = if cfg!(debug_assertions) {
        log::LevelFilter::Debug
    } else {
        log::LevelFilter::Info
    };
    android_logger::init_once(android_logger::Config::default().with_max_level(level));
    log::set_max_level(level);
}
