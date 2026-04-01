package com.flutter_rust_bridge.audio_core

import java.nio.ByteBuffer

object ChromaprintNative {
    external fun nativeCreate(sampleRate: Int, numChannels: Int): Long
    external fun nativeProcess(handle: Long, buffer: ByteBuffer, numShorts: Int)
    external fun nativeGetFingerprint(handle: Long): String?
    external fun nativeDestroy(handle: Long)
}
