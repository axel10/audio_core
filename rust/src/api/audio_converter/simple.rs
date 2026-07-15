use flutter_rust_bridge::frb;
use serde_json;

use super::models::{
    emit_conversion_event, failure_result, AndroidConvertRequest, AndroidConvertResult,
    AndroidConverterCapabilities, ConversionEvent, ConversionFailure,
};
use crate::frb_generated::StreamSink;

use crate::audio_converter_internal::formats::{
    capabilities_notes, supported_output_formats, unsupported_output_format_error,
};
use crate::audio_converter_internal::transcoder::transcode_direct;

fn transcode(request: &AndroidConvertRequest) -> Result<AndroidConvertResult, ConversionFailure> {
    transcode_impl(request, None)
}

fn transcode_impl(
    request: &AndroidConvertRequest,
    progress_sink: Option<&StreamSink<String>>,
) -> Result<AndroidConvertResult, ConversionFailure> {
    if let Some(message) = unsupported_output_format_error(request) {
        return Err(ConversionFailure::new(message));
    }

    transcode_direct(request, progress_sink)
}

#[frb(sync)]
pub fn greet(name: String) -> String {
    format!("Hello, {name}!")
}

#[frb]
pub fn convert_file(request_json: String) -> String {
    let result = match serde_json::from_str::<AndroidConvertRequest>(&request_json) {
        Ok(request) => match transcode(&request) {
            Ok(result) => result,
            Err(error) => failure_result(
                &request,
                "transcode_failed",
                error.error_message,
                error.raw_log,
            ),
        },
        Err(error) => invalid_request_result(error.to_string()),
    };

    serde_json::to_string(&result).unwrap_or_else(|error| {
        serde_json::json!({
            "success": false,
            "engine": "rust-ffmpeg",
            "errorCode": "serialization_failed",
            "errorMessage": error.to_string(),
        })
        .to_string()
    })
}

#[frb]
pub fn convert_file_with_progress(request_json: String, progress_sink: StreamSink<String>) {
    let result = match serde_json::from_str::<AndroidConvertRequest>(&request_json) {
        Ok(request) => {
            emit_conversion_event(
                Some(&progress_sink),
                &ConversionEvent::progress(
                    0,
                    1,
                    request.input_path.clone(),
                    Some(0.0),
                    Some(0),
                    None,
                    Some("Starting conversion".to_string()),
                ),
            );
            match transcode_impl(&request, Some(&progress_sink)) {
                Ok(result) => result,
                Err(error) => failure_result(
                    &request,
                    "transcode_failed",
                    error.error_message,
                    error.raw_log,
                ),
            }
        }
        Err(error) => invalid_request_result(error.to_string()),
    };

    if result.success {
        emit_conversion_event(
            Some(&progress_sink),
            &ConversionEvent::progress(
                1,
                1,
                result.output_path.clone().unwrap_or_default(),
                Some(1.0),
                None,
                None,
                Some("Completed".to_string()),
            ),
        );
    }

    emit_conversion_event(Some(&progress_sink), &ConversionEvent::result(result));
}

#[frb]
pub fn decode_to_pcm_stream(
    input_path: String,
    output_pcm_path: String,
    target_sample_rate: Option<u32>,
    target_channels: Option<u32>,
    progress_sink: StreamSink<String>,
) {
    let result = crate::audio_converter_internal::pcm_exporter::decode_to_pcm(
        &input_path,
        &output_pcm_path,
        target_sample_rate,
        target_channels,
        Some(&progress_sink),
    );

    match result {
        Ok(()) => {
            emit_conversion_event(
                Some(&progress_sink),
                &ConversionEvent::progress(
                    1,
                    1,
                    output_pcm_path.clone(),
                    Some(1.0),
                    None,
                    None,
                    Some("Completed".to_string()),
                ),
            );
            emit_conversion_event(
                Some(&progress_sink),
                &ConversionEvent::result(super::models::AndroidConvertResult {
                    success: true,
                    command: None,
                    output_path: Some(output_pcm_path),
                    engine: Some("rust-ffmpeg".to_string()),
                    output_format: Some("pcm".to_string()),
                    error_code: None,
                    error_message: None,
                    stdout: None,
                    stderr: None,
                    raw_log: None,
                }),
            );
        }
        Err(e) => {
            emit_conversion_event(
                Some(&progress_sink),
                &ConversionEvent::progress(
                    1,
                    1,
                    output_pcm_path.clone(),
                    Some(1.0),
                    None,
                    None,
                    Some(format!("Failed: {}", e)),
                ),
            );
            emit_conversion_event(
                Some(&progress_sink),
                &ConversionEvent::result(super::models::AndroidConvertResult {
                    success: false,
                    command: None,
                    output_path: None,
                    engine: Some("rust-ffmpeg".to_string()),
                    output_format: Some("pcm".to_string()),
                    error_code: Some("pcm_export_failed".to_string()),
                    error_message: Some(e),
                    stdout: None,
                    stderr: None,
                    raw_log: None,
                }),
            );
        }
    }
}

#[frb(sync)]

pub fn get_capabilities() -> String {
    let capabilities = AndroidConverterCapabilities {
        engine: "rust-ffmpeg".to_string(),
        supported_output_formats: supported_output_formats(),
        supports_progress: true,
        supports_cancellation: false,
        requires_external_binary: false,
        notes: Some(capabilities_notes()),
    };
    serde_json::to_string(&capabilities).unwrap()
}

#[frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

fn invalid_request_result(error_message: String) -> AndroidConvertResult {
    AndroidConvertResult {
        success: false,
        command: None,
        output_path: None,
        engine: Some("rust-ffmpeg".to_string()),
        output_format: None,
        error_code: Some("invalid_request".to_string()),
        error_message: Some(error_message),
        stdout: None,
        stderr: None,
        raw_log: None,
    }
}

#[cfg(any(target_os = "macos", target_os = "ios"))]
extern "C" {
    fn mkfifo(pathname: *const std::os::raw::c_char, mode: u16) -> std::os::raw::c_int;
}

#[frb(sync)]
pub fn create_named_pipe(path: String) -> Result<(), String> {
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    {
        use std::ffi::CString;
        let c_path = CString::new(path).map_err(|e| e.to_string())?;
        let res = unsafe { mkfifo(c_path.as_ptr(), 0o666) };
        if res == 0 {
            Ok(())
        } else {
            let err = std::io::Error::last_os_error();
            if err.kind() == std::io::ErrorKind::AlreadyExists {
                Ok(())
            } else {
                Err(err.to_string())
            }
        }
    }
    #[cfg(not(any(target_os = "macos", target_os = "ios")))]
    {
        let _ = path;
        Err("Named pipes are only supported on macOS and iOS".to_string())
    }
}

