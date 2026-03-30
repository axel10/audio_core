package com.flutter_rust_bridge.audio_core

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.AudioProcessor.AudioFormat
import androidx.media3.common.audio.BaseAudioProcessor
import androidx.media3.common.util.UnstableApi
import java.nio.ByteBuffer
import java.nio.ByteOrder
import android.util.Log

/**
 * An AudioProcessor that uses a native C++ Equalizer.
 */
@UnstableApi
class CppEqualizerProcessor : BaseAudioProcessor() {

    private var numBands = 10
    private var isInitialized = false
    private var isEnabled = false
    private var nativeHandle: Long = 0

    private var currentSampleRate = 44100f

    init {
        nativeHandle = nativeCreate()
    }

    fun setNumBands(numBands: Int) {
        this.numBands = numBands
        if (isInitialized) {
            nativeInit(nativeHandle, numBands, currentSampleRate, inputAudioFormat.channelCount)
        }
    }

    fun setEnabled(enabled: Boolean) {
        this.isEnabled = enabled
    }

    fun setBandGain(index: Int, gainDb: Float) {
        nativeSetBandGain(nativeHandle, index, gainDb)
    }

    fun setPreAmp(gainDb: Float) {
        nativeSetPreAmp(nativeHandle, gainDb)
    }

    fun release() {
        if (nativeHandle != 0L) {
            nativeDestroy(nativeHandle)
            nativeHandle = 0
        }
    }

    override fun onConfigure(inputAudioFormat: AudioFormat): AudioFormat {
        currentSampleRate = inputAudioFormat.sampleRate.toFloat()
        if (inputAudioFormat.encoding != C.ENCODING_PCM_FLOAT && inputAudioFormat.encoding != C.ENCODING_PCM_16BIT) {
            throw AudioProcessor.UnhandledAudioFormatException(inputAudioFormat)
        }
        
        // Native initialization
        Log.d("CppEqualizer", "Configuring EQ. SampleRate: ${inputAudioFormat.sampleRate} Hz, Channels: ${inputAudioFormat.channelCount}")
        nativeInit(nativeHandle, numBands, inputAudioFormat.sampleRate.toFloat(), inputAudioFormat.channelCount)
        isInitialized = true
        
        return AudioFormat(inputAudioFormat.sampleRate, inputAudioFormat.channelCount, C.ENCODING_PCM_FLOAT)
    }

    override fun queueInput(inputBuffer: ByteBuffer) {
        if (!inputBuffer.hasRemaining() || !isInitialized || nativeHandle == 0L) return

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
        
        // Let native layer process in-place on the output buffer directly
        if (isEnabled) {
            nativeProcess(nativeHandle, outputBuffer, numSamples / inputAudioFormat.channelCount, inputAudioFormat.channelCount)
        }
        
        outputBuffer.flip()
    }

    private external fun nativeCreate(): Long
    private external fun nativeDestroy(handle: Long)
    private external fun nativeInit(handle: Long, numBands: Int, sampleRate: Float, channelCount: Int)
    private external fun nativeProcess(handle: Long, buffer: ByteBuffer, numSamples: Int, channels: Int)
    private external fun nativeSetBandGain(handle: Long, index: Int, gainDb: Float)
    private external fun nativeSetPreAmp(handle: Long, gainDb: Float)
}
