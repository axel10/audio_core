package com.flutter_rust_bridge.audio_core

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.AudioProcessor.AudioFormat
import androidx.media3.common.audio.BaseAudioProcessor
import androidx.media3.common.util.UnstableApi
import java.nio.ByteBuffer

/**
 * ExoPlayer AudioProcessor that delegates stereo/mono concert hall reverb DSP
 * (Freeverb & FunDSP FDN) to the native Rust `audio_core` library.
 */
@UnstableApi
class RustReverbProcessor : BaseAudioProcessor() {

    companion object {
        init {
            try {
                System.loadLibrary("audio_core")
            } catch (t: Throwable) {
                NativeLog.d("RustReverb", "Note: System.loadLibrary(audio_core): ${t.message}")
            }
        }
    }

    private var isInitialized = false
    private var nativeHandle: Long = 0

    // Default to Concert Hall preset (disabled initially).
    private var enabled = false
    private var algorithm = 0
    private var dryMix = 0.85f
    private var wetMix = 0.75f
    private var roomSize = 0.9f
    private var damping = 0.4f
    private var width = 0.75f
    private var timeSeconds = 2.8f
    private var freeze = false

    init {
        nativeHandle = nativeCreate()
    }

    fun setConfig(
        enabled: Boolean,
        algorithm: Int,
        dryMix: Float,
        wetMix: Float,
        roomSize: Float,
        damping: Float,
        width: Float,
        timeSeconds: Float,
        freeze: Boolean,
    ) {
        this.enabled = enabled
        this.algorithm = algorithm
        this.dryMix = dryMix
        this.wetMix = wetMix
        this.roomSize = roomSize
        this.damping = damping
        this.width = width
        this.timeSeconds = timeSeconds
        this.freeze = freeze
        if (nativeHandle != 0L) {
            nativeSetConfig(
                nativeHandle,
                enabled,
                algorithm,
                dryMix,
                wetMix,
                roomSize,
                damping,
                width,
                timeSeconds,
                freeze,
            )
        }
    }

    fun release() {
        if (nativeHandle != 0L) {
            nativeDestroy(nativeHandle)
            nativeHandle = 0
        }
    }

    override fun onConfigure(inputAudioFormat: AudioFormat): AudioFormat {
        if (inputAudioFormat.encoding != C.ENCODING_PCM_FLOAT &&
            inputAudioFormat.encoding != C.ENCODING_PCM_16BIT
        ) {
            throw AudioProcessor.UnhandledAudioFormatException(inputAudioFormat)
        }
        if (inputAudioFormat.channelCount <= 0 || inputAudioFormat.sampleRate <= 0) {
            throw AudioProcessor.UnhandledAudioFormatException(inputAudioFormat)
        }

        if (nativeHandle != 0L) {
            nativeInit(
                nativeHandle,
                inputAudioFormat.sampleRate.toFloat(),
                inputAudioFormat.channelCount,
            )
            nativeSetConfig(
                nativeHandle,
                enabled,
                algorithm,
                dryMix,
                wetMix,
                roomSize,
                damping,
                width,
                timeSeconds,
                freeze,
            )
        }
        isInitialized = true
        return AudioFormat(
            inputAudioFormat.sampleRate,
            inputAudioFormat.channelCount,
            C.ENCODING_PCM_FLOAT,
        )
    }

    override fun queueInput(inputBuffer: ByteBuffer) {
        if (!inputBuffer.hasRemaining() ||
            !isInitialized ||
            nativeHandle == 0L ||
            inputAudioFormat.channelCount <= 0
        ) {
            return
        }

        val encoding = inputAudioFormat.encoding
        val remaining = inputBuffer.remaining()
        val numSamples = if (encoding == C.ENCODING_PCM_16BIT) {
            remaining / 2
        } else {
            remaining / 4
        }

        val floatBytesSize = numSamples * 4
        val outputBuffer = replaceOutputBuffer(floatBytesSize)

        if (encoding == C.ENCODING_PCM_16BIT) {
            val shortBuffer = inputBuffer.asShortBuffer()
            for (i in 0 until numSamples) {
                outputBuffer.putFloat(shortBuffer.get() / 32768f)
            }
            inputBuffer.position(inputBuffer.position() + remaining)
        } else {
            outputBuffer.put(inputBuffer)
        }

        if (nativeHandle != 0L) {
            nativeProcess(
                nativeHandle,
                outputBuffer,
                numSamples / inputAudioFormat.channelCount,
                inputAudioFormat.channelCount,
            )
        }

        outputBuffer.flip()
    }

    override fun onFlush() {
        // Keep reverb tail/state across minor flushes or let fade handle it.
    }

    override fun onReset() {
        isInitialized = false
    }

    private external fun nativeCreate(): Long
    private external fun nativeDestroy(handle: Long)
    private external fun nativeInit(handle: Long, sampleRate: Float, channels: Int)
    private external fun nativeProcess(
        handle: Long,
        buffer: ByteBuffer,
        numSamples: Int,
        channels: Int,
    )
    private external fun nativeSetConfig(
        handle: Long,
        enabled: Boolean,
        algorithm: Int,
        dryMix: Float,
        wetMix: Float,
        roomSize: Float,
        damping: Float,
        width: Float,
        timeSeconds: Float,
        freeze: Boolean,
    )
}
