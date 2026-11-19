package com.flutter_rust_bridge.audio_core

import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.ForwardingAudioSink
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Media3 [AudioSink] wrapper that transparently switches between:
 * - Normal Android playback ([delegate], i.e. `DefaultAudioSink`)
 * - User-space USB Exclusive playback ([UsbExclusiveNative] via Rust `libusb` UAC1/UAC2)
 *
 * When USB exclusive mode is active, decoded PCM bypasses Android's AudioTrack
 * and AudioFlinger completely, keeping native sample rates and feeding the USB
 * DAC directly while still driving [cppEqualizerProcessor] and [fftProcessor].
 */
@UnstableApi
class SwitchableUsbAudioSink(
    delegate: AudioSink,
    private val usbManager: UsbExclusiveManager,
    private val fftProcessor: FFTAudioProcessor,
) : ForwardingAudioSink(delegate) {

    private var usingUsbForCurrentConfig: Boolean = false
    private var configuredSampleRate: Int = 44100
    private var configuredChannels: Int = 2
    private var configuredEncoding: Int = C.ENCODING_PCM_16BIT

    private var startPresentationTimeUs: Long = C.TIME_UNSET
    private var lastSubmittedPresentationTimeUs: Long = C.TIME_UNSET
    private var isPlayingUsb: Boolean = false
    private var handledEndOfStream: Boolean = false
    private var currentVolume: Float = 1.0f

    // Reusable DirectByteBuffer holding Float32 PCM awaiting write to Rust ring buffer.
    private var pendingFloatBuffer: ByteBuffer =
        ByteBuffer.allocateDirect(64 * 1024).order(ByteOrder.nativeOrder()).apply { limit(0) }

    override fun supportsFormat(format: Format): Boolean {
        if (usbManager.isExclusiveActive && isSupportedPcmFormat(format)) {
            return true
        }
        return super.supportsFormat(format)
    }

    override fun getFormatSupport(format: Format): Int {
        if (usbManager.isExclusiveActive && isSupportedPcmFormat(format)) {
            return AudioSink.SINK_FORMAT_SUPPORTED_DIRECTLY
        }
        return super.getFormatSupport(format)
    }

    override fun configure(
        inputFormat: Format,
        specifiedBufferSize: Int,
        outputChannels: IntArray?,
    ) {
        if (usbManager.isExclusiveActive && isSupportedPcmFormat(inputFormat)) {
            val sr = inputFormat.sampleRate
            val ch = inputFormat.channelCount
            val enc = inputFormat.pcmEncoding
            val preferredBitDepth = when (enc) {
                C.ENCODING_PCM_16BIT -> 16
                C.ENCODING_PCM_24BIT, C.ENCODING_PCM_24BIT_BIG_ENDIAN -> 24
                C.ENCODING_PCM_32BIT, C.ENCODING_PCM_32BIT_BIG_ENDIAN, C.ENCODING_PCM_FLOAT -> 32
                else -> 24
            }

            val ok = UsbExclusiveNative.nativeConfigureStream(sr, ch, preferredBitDepth) &&
                UsbExclusiveNative.nativeStartStream()

            if (ok) {
                usingUsbForCurrentConfig = true
                configuredSampleRate = sr
                configuredChannels = ch
                configuredEncoding = enc
                startPresentationTimeUs = C.TIME_UNSET
                lastSubmittedPresentationTimeUs = C.TIME_UNSET
                handledEndOfStream = false
                pendingFloatBuffer.clear()
                pendingFloatBuffer.limit(0)

                UsbExclusiveNative.nativeSetVolume(currentVolume)
                UsbExclusiveNative.nativeSetPaused(!isPlayingUsb)

                // Keep FFT visualizer alive during USB exclusive playback.
                try {
                    fftProcessor.configure(
                        androidx.media3.common.audio.AudioProcessor.AudioFormat(
                            sr,
                            ch,
                            C.ENCODING_PCM_FLOAT,
                        )
                    )
                    fftProcessor.flush()
                } catch (_: Throwable) {
                }

                NativeLog.d(
                    "UsbExclusive",
                    "AudioSink configured for USB exclusive: ${sr}Hz ${ch}ch enc=$enc (pref=${preferredBitDepth}bit)",
                )
                return
            } else {
                NativeLog.d(
                    "UsbExclusive",
                    "USB exclusive configure failed for ${sr}Hz ${ch}ch; falling back to DefaultAudioSink",
                )
            }
        }

        usingUsbForCurrentConfig = false
        super.configure(inputFormat, specifiedBufferSize, outputChannels)
    }

    override fun play() {
        isPlayingUsb = true
        if (usingUsbForCurrentConfig) {
            UsbExclusiveNative.nativeSetPaused(false)
            return
        }
        super.play()
    }

    override fun pause() {
        isPlayingUsb = false
        if (usingUsbForCurrentConfig) {
            UsbExclusiveNative.nativeSetPaused(true)
            return
        }
        super.pause()
    }

    override fun handleDiscontinuity() {
        if (usingUsbForCurrentConfig) {
            startPresentationTimeUs = C.TIME_UNSET
            return
        }
        super.handleDiscontinuity()
    }

    override fun handleBuffer(
        buffer: ByteBuffer,
        presentationTimeUs: Long,
        encodedAccessUnitCount: Int,
    ): Boolean {
        if (!usingUsbForCurrentConfig) {
            return super.handleBuffer(buffer, presentationTimeUs, encodedAccessUnitCount)
        }

        // If USB DAC was detached mid-playback, drain gracefully.
        if (!usbManager.isExclusiveActive) {
            buffer.position(buffer.limit())
            return true
        }

        // First drain any leftover samples from the previous call.
        if (pendingFloatBuffer.hasRemaining()) {
            val written = UsbExclusiveNative.nativeWriteFloatPcm(
                pendingFloatBuffer,
                pendingFloatBuffer.position(),
                pendingFloatBuffer.remaining(),
            )
            if (written > 0) {
                pendingFloatBuffer.position(pendingFloatBuffer.position() + written)
            }
            if (pendingFloatBuffer.hasRemaining()) {
                return false
            }
        }

        val remainingBytes = buffer.remaining()
        if (remainingBytes <= 0) {
            return true
        }

        if (startPresentationTimeUs == C.TIME_UNSET) {
            startPresentationTimeUs = presentationTimeUs
        }
        lastSubmittedPresentationTimeUs = presentationTimeUs

        // Convert incoming PCM to Float32 in our reusable DirectByteBuffer.
        val floatBytes = convertPcmToDirectFloatBuffer(buffer, configuredEncoding)
        if (floatBytes <= 0) {
            return true
        }

        // Feed FFT visualizer (non-blocking, best-effort).
        try {
            val fftDup = pendingFloatBuffer.duplicate().order(ByteOrder.nativeOrder())
            fftProcessor.queueInput(fftDup)
        } catch (_: Throwable) {
        }

        val written = UsbExclusiveNative.nativeWriteFloatPcm(
            pendingFloatBuffer,
            pendingFloatBuffer.position(),
            pendingFloatBuffer.remaining(),
        )
        if (written > 0) {
            pendingFloatBuffer.position(pendingFloatBuffer.position() + written)
        }

        // We already consumed `buffer` into `pendingFloatBuffer`; return true so
        // ExoPlayer advances, and any remainder in `pendingFloatBuffer` will apply
        // backpressure on the very next `handleBuffer` call.
        return true
    }

    override fun playToEndOfStream() {
        if (usingUsbForCurrentConfig) {
            handledEndOfStream = true
            return
        }
        super.playToEndOfStream()
    }

    override fun isEnded(): Boolean {
        if (usingUsbForCurrentConfig) {
            return handledEndOfStream &&
                !pendingFloatBuffer.hasRemaining() &&
                UsbExclusiveNative.nativeGetBufferedFrames() == 0L
        }
        return super.isEnded()
    }

    override fun hasPendingData(): Boolean {
        if (usingUsbForCurrentConfig) {
            return pendingFloatBuffer.hasRemaining() ||
                UsbExclusiveNative.nativeGetBufferedFrames() > 0L
        }
        return super.hasPendingData()
    }

    override fun getCurrentPositionUs(sourceEnded: Boolean): Long {
        if (usingUsbForCurrentConfig) {
            if (startPresentationTimeUs == C.TIME_UNSET || configuredSampleRate <= 0) {
                return AudioSink.CURRENT_POSITION_NOT_SET
            }
            val playedFrames = UsbExclusiveNative.nativeGetPlayedFrames()
            val playedUs = (playedFrames * 1_000_000L) / configuredSampleRate.toLong()
            return startPresentationTimeUs + playedUs
        }
        return super.getCurrentPositionUs(sourceEnded)
    }

    override fun setVolume(volume: Float) {
        currentVolume = volume.coerceIn(0f, 1f)
        if (usingUsbForCurrentConfig) {
            UsbExclusiveNative.nativeSetVolume(currentVolume)
            return
        }
        super.setVolume(volume)
    }

    override fun flush() {
        if (usingUsbForCurrentConfig) {
            pendingFloatBuffer.clear()
            pendingFloatBuffer.limit(0)
            startPresentationTimeUs = C.TIME_UNSET
            lastSubmittedPresentationTimeUs = C.TIME_UNSET
            handledEndOfStream = false
            UsbExclusiveNative.nativeFlushStream()
            return
        }
        super.flush()
    }

    override fun reset() {
        if (usingUsbForCurrentConfig) {
            pendingFloatBuffer.clear()
            pendingFloatBuffer.limit(0)
            startPresentationTimeUs = C.TIME_UNSET
            lastSubmittedPresentationTimeUs = C.TIME_UNSET
            handledEndOfStream = false
            usingUsbForCurrentConfig = false
            UsbExclusiveNative.nativeStopStream()
            return
        }
        super.reset()
    }

    override fun release() {
        if (usingUsbForCurrentConfig) {
            usingUsbForCurrentConfig = false
            UsbExclusiveNative.nativeStopStream()
        }
        super.release()
    }

    private fun isSupportedPcmFormat(format: Format): Boolean {
        if (format.sampleMimeType != MimeTypes.AUDIO_RAW) return false
        if (format.sampleRate <= 0 || format.channelCount <= 0) return false
        return when (format.pcmEncoding) {
            C.ENCODING_PCM_16BIT,
            C.ENCODING_PCM_24BIT,
            C.ENCODING_PCM_32BIT,
            C.ENCODING_PCM_FLOAT -> true
            else -> false
        }
    }

    private fun ensureFloatBufferCapacity(bytesNeeded: Int) {
        if (pendingFloatBuffer.capacity() < bytesNeeded) {
            pendingFloatBuffer =
                ByteBuffer.allocateDirect(bytesNeeded).order(ByteOrder.nativeOrder())
        }
        pendingFloatBuffer.clear()
    }

    private fun convertPcmToDirectFloatBuffer(src: ByteBuffer, encoding: Int): Int {
        val rem = src.remaining()
        return when (encoding) {
            C.ENCODING_PCM_FLOAT -> {
                ensureFloatBufferCapacity(rem)
                pendingFloatBuffer.put(src)
                pendingFloatBuffer.flip()
                pendingFloatBuffer.remaining()
            }

            C.ENCODING_PCM_16BIT -> {
                val samples = rem / 2
                val outBytes = samples * 4
                ensureFloatBufferCapacity(outBytes)
                val order = src.order()
                src.order(ByteOrder.LITTLE_ENDIAN)
                for (i in 0 until samples) {
                    val s = src.short
                    pendingFloatBuffer.putFloat(s / 32768.0f)
                }
                src.order(order)
                pendingFloatBuffer.flip()
                pendingFloatBuffer.remaining()
            }

            C.ENCODING_PCM_24BIT -> {
                val samples = rem / 3
                val outBytes = samples * 4
                ensureFloatBufferCapacity(outBytes)
                for (i in 0 until samples) {
                    val b0 = src.get().toInt() and 0xFF
                    val b1 = src.get().toInt() and 0xFF
                    val b2 = src.get().toInt() // signed MSB
                    val sample24 = (b2 shl 16) or (b1 shl 8) or b0
                    pendingFloatBuffer.putFloat(sample24 / 8388608.0f)
                }
                pendingFloatBuffer.flip()
                pendingFloatBuffer.remaining()
            }

            C.ENCODING_PCM_32BIT -> {
                val samples = rem / 4
                val outBytes = samples * 4
                ensureFloatBufferCapacity(outBytes)
                val order = src.order()
                src.order(ByteOrder.LITTLE_ENDIAN)
                for (i in 0 until samples) {
                    val s = src.int
                    pendingFloatBuffer.putFloat((s.toDouble() / 2147483648.0).toFloat())
                }
                src.order(order)
                pendingFloatBuffer.flip()
                pendingFloatBuffer.remaining()
            }

            else -> {
                src.position(src.limit())
                0
            }
        }
    }
}
