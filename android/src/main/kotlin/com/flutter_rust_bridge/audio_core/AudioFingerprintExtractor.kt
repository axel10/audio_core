package com.flutter_rust_bridge.audio_core

import android.content.Context
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import android.util.Log
import java.nio.ByteBuffer

object AudioFingerprintExtractor {
    private const val TAG = "AudioFingerprintExtr"
    private const val MAX_SECONDS_TO_FINGERPRINT = 20

    fun extractFingerprint(context: Context, uri: Uri): String? {
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        var handle: Long = 0
        
        try {
            extractor.setDataSource(context, uri, null)
            
            var audioTrackIndex = -1
            var format: MediaFormat? = null
            
            for (i in 0 until extractor.trackCount) {
                val fmt = extractor.getTrackFormat(i)
                val mime = fmt.getString(MediaFormat.KEY_MIME)
                if (mime?.startsWith("audio/") == true) {
                    audioTrackIndex = i
                    format = fmt
                    break
                }
            }
            
            if (audioTrackIndex < 0 || format == null) {
                Log.e(TAG, "No audio track found in file")
                return null
            }
            
            extractor.selectTrack(audioTrackIndex)
            
            val mime = format.getString(MediaFormat.KEY_MIME) ?: return null
            val sampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            val channelCount = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            
            codec = MediaCodec.createDecoderByType(mime)
            codec.configure(format, null, null, 0)
            codec.start()
            
            handle = ChromaprintNative.nativeCreate(sampleRate, channelCount)
            if (handle == 0L) {
                return null
            }
            
            var isEOS = false
            var totalSamplesProcessed: Long = 0
            val targetSamples = sampleRate * channelCount * MAX_SECONDS_TO_FINGERPRINT
            
            val info = MediaCodec.BufferInfo()
            val TIMEOUT_US = 10000L
            
            while (!isEOS && totalSamplesProcessed < targetSamples) {
                val inIndex = codec.dequeueInputBuffer(TIMEOUT_US)
                if (inIndex >= 0) {
                    val inputBuffer = codec.getInputBuffer(inIndex)
                    if (inputBuffer != null) {
                        val sampleSize = extractor.readSampleData(inputBuffer, 0)
                        if (sampleSize < 0) {
                            codec.queueInputBuffer(inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        } else {
                            codec.queueInputBuffer(inIndex, 0, sampleSize, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }

                var outIndex = codec.dequeueOutputBuffer(info, TIMEOUT_US)
                while (outIndex >= 0) {
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                        isEOS = true
                    }
                    if (info.size > 0) {
                        val outputBuffer = codec.getOutputBuffer(outIndex)
                        if (outputBuffer != null) {
                            outputBuffer.position(info.offset)
                            outputBuffer.limit(info.offset + info.size)
                            val slicedBuffer = outputBuffer.slice()

                            // MediaCodec decoder output is 16-bit PCM (2 bytes per sample)
                            val numShorts = info.size / 2
                            val remaining = (targetSamples - totalSamplesProcessed).toInt()
                            if (numShorts >= remaining) {
                                ChromaprintNative.nativeProcess(handle, slicedBuffer, remaining)
                                totalSamplesProcessed += remaining
                                codec.releaseOutputBuffer(outIndex, false)
                                break
                            } else {
                                ChromaprintNative.nativeProcess(handle, slicedBuffer, numShorts)
                                totalSamplesProcessed += numShorts
                            }
                        }
                    }
                    codec.releaseOutputBuffer(outIndex, false)
                    
                    if (totalSamplesProcessed >= targetSamples) {
                        break
                    }
                    
                    outIndex = codec.dequeueOutputBuffer(info, 0)
                }
            }
            
            return ChromaprintNative.nativeGetFingerprint(handle)
        } catch (e: Exception) {
            Log.e(TAG, "Error extracting fingerprint", e)
            return null
        } finally {
            if (handle != 0L) {
                ChromaprintNative.nativeDestroy(handle)
            }
            try {
                codec?.stop()
                codec?.release()
            } catch (e: Exception) {}
            extractor.release()
        }
    }
}
