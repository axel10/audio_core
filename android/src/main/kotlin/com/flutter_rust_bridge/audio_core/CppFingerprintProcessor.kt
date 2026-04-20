package com.flutter_rust_bridge.audio_core

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.AudioProcessor.AudioFormat
import androidx.media3.common.audio.BaseAudioProcessor
import androidx.media3.common.util.UnstableApi
import java.nio.ByteBuffer
import android.util.Log

/**
 * An AudioProcessor that calculates a Chromaprint audio fingerprint of the passing PCM data.
 * Once enough seconds of audio are collected, it debug-prints the fingerprint.
 */
@UnstableApi
class CppFingerprintProcessor : BaseAudioProcessor() {

    private var nativeHandle: Long = 0
    private var isInitialized = false
    private var hasPrinted = false
    private var totalSamplesProcessed: Long = 0
    
    // We only need the first 15-20 seconds for a good fingerprint 
    private val SECONDS_TO_FINGERPRINT = 20

    override fun onConfigure(inputAudioFormat: AudioFormat): AudioFormat {
        if (inputAudioFormat.encoding != C.ENCODING_PCM_16BIT) {
            // Chromaprint expects 16-bit PCM. We'll let Exoplayer convert it before us
            throw AudioProcessor.UnhandledAudioFormatException(inputAudioFormat)
        }
        if (inputAudioFormat.channelCount <= 0 || inputAudioFormat.sampleRate <= 0) {
            throw AudioProcessor.UnhandledAudioFormatException(inputAudioFormat)
        }
        
        if (nativeHandle != 0L) {
            ChromaprintNative.nativeDestroy(nativeHandle)
            nativeHandle = 0
        }
        
        nativeHandle = ChromaprintNative.nativeCreate(inputAudioFormat.sampleRate, inputAudioFormat.channelCount)
        isInitialized = true
        hasPrinted = false
        totalSamplesProcessed = 0
        NativeLog.d("Chromaprint", "Configured CppFingerprintProcessor. SR: ${inputAudioFormat.sampleRate}")
        
        return inputAudioFormat // We don't change the format
    }

    override fun queueInput(inputBuffer: ByteBuffer) {
        val remaining = inputBuffer.remaining()
        if (remaining == 0) return
        
        val posBefore = inputBuffer.position()

        if (isInitialized && nativeHandle != 0L && !hasPrinted) {
            val numShorts = remaining / 2
            
            // Feed PCM directly from the direct ByteBuffer to native C++
            ChromaprintNative.nativeProcess(nativeHandle, inputBuffer, numShorts)
            
            totalSamplesProcessed += (numShorts / inputAudioFormat.channelCount)
            val elapsedSeconds = totalSamplesProcessed.toDouble() / inputAudioFormat.sampleRate.toDouble()
            
            if (elapsedSeconds >= SECONDS_TO_FINGERPRINT) {
                val fingerprint = ChromaprintNative.nativeGetFingerprint(nativeHandle)
                if (fingerprint != null) {
                    NativeLog.d("Chromaprint", "==========================================================")
                    NativeLog.d("Chromaprint", "🎵 SONG FINGERPRINT GENERATED (after $SECONDS_TO_FINGERPRINT s):")
                    NativeLog.d("Chromaprint", fingerprint)
                    NativeLog.d("Chromaprint", "==========================================================")
                }
                hasPrinted = true
            }
        }
        
        // Restore position so we can pass data to the next processor
        inputBuffer.position(posBefore)
        
        val outputBuffer = replaceOutputBuffer(remaining)
        outputBuffer.put(inputBuffer)
        outputBuffer.flip()
    }

    override fun onFlush() {
        totalSamplesProcessed = 0
    }

    override fun onReset() {
        isInitialized = false
        hasPrinted = false
        totalSamplesProcessed = 0
    }

    fun release() {
        if (nativeHandle != 0L) {
            ChromaprintNative.nativeDestroy(nativeHandle)
            nativeHandle = 0
        }
    }
}

