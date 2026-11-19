package com.flutter_rust_bridge.audio_core

import java.nio.ByteBuffer

/**
 * JNI bridge to the Rust `usb_audio` UAC 1.0 / 2.0 exclusive engine.
 */
object UsbExclusiveNative {
    init {
        try {
            System.loadLibrary("audio_core")
        } catch (t: Throwable) {
            NativeLog.d("UsbExclusive", "System.loadLibrary(audio_core): ${t.message}")
        }
    }

    external fun nativeRegisterDevice(
        fd: Int,
        vendorId: Int,
        productId: Int,
        deviceName: String,
    ): String

    external fun nativeClearDevice()

    external fun nativeConfigureStream(
        sampleRate: Int,
        channels: Int,
        preferredBitDepth: Int,
    ): Boolean

    external fun nativeStartStream(): Boolean

    external fun nativeSetPaused(paused: Boolean)

    external fun nativeFlushStream()

    external fun nativeStopStream()

    external fun nativeSetVolume(volume: Float)

    external fun nativeWriteFloatPcm(
        buffer: ByteBuffer,
        offsetBytes: Int,
        lengthBytes: Int,
    ): Int

    external fun nativeGetPlayedFrames(): Long

    external fun nativeGetBufferedFrames(): Long

    external fun nativeGetStatusJson(): String
}
