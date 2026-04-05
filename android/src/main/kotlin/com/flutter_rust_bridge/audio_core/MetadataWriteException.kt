package com.flutter_rust_bridge.audio_core

class MetadataWriteException(
    val code: String,
    override val message: String,
    val details: Map<String, Any?>,
    cause: Throwable? = null,
) : RuntimeException(message, cause)
