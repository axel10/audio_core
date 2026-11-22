package com.flutter_rust_bridge.audio_core

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.roundToInt

/**
 * Maintains a streaming [AudioTrack] fed with the real playing track's PCM at
 * an inaudibly low gain (`~ -66 dB`) while USB exclusive playback is active.
 *
 * Why real PCM instead of all-zero silence:
 * OEM power monitors (such as Xiaomi HyperOS `AudioTrackImpl` / `PowerInsight`)
 * inspect both track volume and PCM `maxAmplitude`, and may ignore all-zero
 * silent tracks or zero-volume tracks and still freeze the process shortly
 * after screen-off.
 *
 * Feeding real PCM via [AudioTrack.WRITE_NON_BLOCKING] ensures:
 * - AudioFlinger & OEM power monitors see a genuine active media track with
 *   real non-zero PCM amplitude and non-zero volume.
 * - Track volume is attenuated to [KEEP_ALIVE_VOLUME] (~ -66 dB), well below
 *   audible level on speakers or other outputs.
 * - Non-blocking writes never stall or backpressure the USB exclusive clock.
 */
class UsbExclusiveAudioKeepAlive {
    companion object {
        private const val MAX_KEEP_ALIVE_SAMPLE_RATE = 48000
        private const val MIN_KEEP_ALIVE_SAMPLE_RATE = 8000
        private const val DEFAULT_SAMPLE_RATE = 44100
        private const val DEFAULT_CHANNELS = 2

        /**
         * ~ -66 dB: non-zero so OEM power monitors do not classify the track as
         * muted, while inaudible on device speakers.
         */
        private const val KEEP_ALIVE_VOLUME = 0.0005f
    }

    @Volatile
    private var isRunning: Boolean = false

    private var track: AudioTrack? = null
    private var configuredSourceSampleRate: Int = DEFAULT_SAMPLE_RATE
    private var configuredSourceChannels: Int = DEFAULT_CHANNELS
    private var targetSampleRate: Int = DEFAULT_SAMPLE_RATE
    private var targetChannels: Int = DEFAULT_CHANNELS
    private var decimationFactor: Int = 1

    private var pcmScratch: ShortArray = ShortArray(4096)

    @Synchronized
    fun configure(sampleRate: Int, channelCount: Int) {
        val safeSr = if (sampleRate > 0) sampleRate else DEFAULT_SAMPLE_RATE
        val safeCh = if (channelCount > 0) channelCount else DEFAULT_CHANNELS

        val nextDecimation = if (safeSr > MAX_KEEP_ALIVE_SAMPLE_RATE) {
            maxOf(1, (safeSr + MAX_KEEP_ALIVE_SAMPLE_RATE - 1) / MAX_KEEP_ALIVE_SAMPLE_RATE)
        } else {
            1
        }
        val nextTargetSr = (safeSr / nextDecimation)
            .coerceIn(MIN_KEEP_ALIVE_SAMPLE_RATE, MAX_KEEP_ALIVE_SAMPLE_RATE)
        val nextTargetCh = if (safeCh <= 1) 1 else 2

        val formatChanged = nextTargetSr != targetSampleRate || nextTargetCh != targetChannels
        configuredSourceSampleRate = safeSr
        configuredSourceChannels = safeCh
        decimationFactor = nextDecimation
        targetSampleRate = nextTargetSr
        targetChannels = nextTargetCh

        if (formatChanged && track != null) {
            val wasRunning = isRunning
            stopLocked()
            if (wasRunning) {
                startLocked()
            }
        }
    }

    @Synchronized
    fun start() {
        startLocked()
    }

    @Synchronized
    fun stop() {
        stopLocked()
    }

    /**
     * Feeds interleaved Float32 PCM (native byte order) from the active track
     * into the low-volume keep-alive [AudioTrack] without blocking.
     */
    fun feedFloatPcm(floatPcm: ByteBuffer, sourceChannels: Int) {
        if (!isRunning) return
        val bytes = floatPcm.remaining()
        if (bytes < 4) return

        synchronized(this) {
            val activeTrack = track ?: return
            if (!isRunning || activeTrack.playState != AudioTrack.PLAYSTATE_PLAYING) return

            val srcCh = if (sourceChannels > 0) sourceChannels else configuredSourceChannels
            val totalFloats = bytes / 4
            val totalFrames = totalFloats / srcCh
            if (totalFrames <= 0) return

            val step = decimationFactor.coerceAtLeast(1)
            val outFrames = (totalFrames + step - 1) / step
            val outSamples = outFrames * targetChannels
            if (pcmScratch.size < outSamples) {
                pcmScratch = ShortArray(outSamples)
            }

            val floatView = floatPcm.duplicate().order(ByteOrder.nativeOrder()).asFloatBuffer()
            var outIdx = 0
            var frame = 0
            while (frame < totalFrames) {
                val base = frame * srcCh
                for (ch in 0 until targetChannels) {
                    val s = if (ch < srcCh) floatView.get(base + ch) else 0f
                    val clamped = when {
                        s.isNaN() -> 0f
                        s > 1f -> 1f
                        s < -1f -> -1f
                        else -> s
                    }
                    pcmScratch[outIdx++] = (clamped * 32767f).roundToInt().toShort()
                }
                frame += step
            }

            try {
                activeTrack.write(pcmScratch, 0, outIdx, AudioTrack.WRITE_NON_BLOCKING)
            } catch (_: Throwable) {
            }
        }
    }

    private fun startLocked() {
        val existing = track
        if (existing != null) {
            if (existing.playState == AudioTrack.PLAYSTATE_PLAYING) {
                isRunning = true
                return
            }
            stopLocked()
        }

        var candidate: AudioTrack? = null
        try {
            val channelMask = if (targetChannels <= 1) {
                AudioFormat.CHANNEL_OUT_MONO
            } else {
                AudioFormat.CHANNEL_OUT_STEREO
            }
            val bytesPerFrame = targetChannels * 2 // 16-bit PCM
            val minBufBytes = AudioTrack.getMinBufferSize(
                targetSampleRate,
                channelMask,
                AudioFormat.ENCODING_PCM_16BIT,
            )
            val targetBufBytes = (targetSampleRate / 5) * bytesPerFrame // ~200ms
            val rawBytes = if (minBufBytes > 0) maxOf(targetBufBytes, minBufBytes * 2) else targetBufBytes
            val bufferBytes = ((rawBytes + bytesPerFrame - 1) / bytesPerFrame) * bytesPerFrame

            val attributes = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                .build()

            val format = AudioFormat.Builder()
                .setSampleRate(targetSampleRate)
                .setChannelMask(channelMask)
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .build()

            candidate = AudioTrack.Builder()
                .setAudioAttributes(attributes)
                .setAudioFormat(format)
                .setBufferSizeInBytes(bufferBytes)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()

            if (candidate.state != AudioTrack.STATE_INITIALIZED) {
                NativeLog.d("UsbExclusive", "UsbExclusiveAudioKeepAlive failed to initialize")
                candidate.release()
                return
            }

            candidate.setVolume(KEEP_ALIVE_VOLUME)
            candidate.play()
            track = candidate
            isRunning = true
            NativeLog.d(
                "UsbExclusive",
                "UsbExclusiveAudioKeepAlive started (sessionId=${candidate.audioSessionId}, " +
                    "src=${configuredSourceSampleRate}Hz/${configuredSourceChannels}ch -> " +
                    "dst=${targetSampleRate}Hz/${targetChannels}ch, step=$decimationFactor, vol=$KEEP_ALIVE_VOLUME)",
            )
        } catch (t: Throwable) {
            NativeLog.d("UsbExclusive", "UsbExclusiveAudioKeepAlive start error: ${t.message}")
            try {
                candidate?.release()
            } catch (_: Throwable) {
            }
            track = null
            isRunning = false
        }
    }

    private fun stopLocked() {
        isRunning = false
        val existing = track ?: return
        track = null
        try {
            if (existing.playState == AudioTrack.PLAYSTATE_PLAYING) {
                existing.pause()
            }
            existing.flush()
            existing.stop()
        } catch (_: Throwable) {
        }
        try {
            existing.release()
        } catch (_: Throwable) {
        }
        NativeLog.d("UsbExclusive", "UsbExclusiveAudioKeepAlive stopped")
    }
}
