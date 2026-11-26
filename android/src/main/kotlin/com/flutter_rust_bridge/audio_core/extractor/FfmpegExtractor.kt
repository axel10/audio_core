package com.flutter_rust_bridge.audio_core.extractor

import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.ParsableByteArray
import androidx.media3.decoder.ffmpeg.FfmpegLibrary
import androidx.media3.extractor.Extractor
import androidx.media3.extractor.ExtractorInput
import androidx.media3.extractor.ExtractorOutput
import androidx.media3.extractor.PositionHolder
import androidx.media3.extractor.SeekMap
import androidx.media3.extractor.SeekPoint
import androidx.media3.extractor.TrackOutput
import java.io.IOException
import java.util.Collections
import kotlin.math.min

/**
 * ExoPlayer Extractor backed by FFmpeg's libavformat via JNI.
 *
 * Operates in two modes:
 * - [onlyInterceptAbnormalWav] = true (placed BEFORE DefaultExtractorsFactory):
 *   Fast-sniffs RIFF/WAVE headers and data chunks to intercept DTS-WAV (both 0x2001 tagged
 *   and 0x0001 SPDIF-disguised DTS-CD) before Media3's WavExtractor claims or rejects them.
 * - [onlyInterceptAbnormalWav] = false (placed AFTER DefaultExtractorsFactory):
 *   Fallback demuxer for formats unsupported by Media3's built-in extractors (e.g. APE, WV, TTA).
 */
class FfmpegExtractor(
    private val onlyInterceptAbnormalWav: Boolean = false,
) : Extractor {

    companion object {
        private const val TRACK_ID = 0
        private const val READ_RESULT_PACKET = 0
        private const val READ_RESULT_EOF = 1
        private const val READ_RESULT_SEEK = 2

        private const val WAV_PROBE_PEEK_BYTES = 8192
        private const val MAX_SEEK_REPOSITIONS = 4

        // Standard WAV wFormatTag values natively handled by Media3 WavExtractor.
        private const val WAVE_FORMAT_PCM = 0x0001
        private const val WAVE_FORMAT_IEEE_FLOAT = 0x0003
        private const val WAVE_FORMAT_ALAW = 0x0006
        private const val WAVE_FORMAT_MULAW = 0x0007
        private const val WAVE_FORMAT_IMA_ADPCM = 0x0011
        private const val WAVE_FORMAT_EXTENSIBLE = 0xFFFE

        fun ffmpegCodecToMimeType(codecName: String): String {
            return when (codecName) {
                "aac" -> MimeTypes.AUDIO_AAC
                "mp3", "mp3float" -> MimeTypes.AUDIO_MPEG
                "mp2", "mp2float" -> MimeTypes.AUDIO_MPEG_L2
                "mp1", "mp1float" -> MimeTypes.AUDIO_MPEG_L1
                "ac3" -> MimeTypes.AUDIO_AC3
                "eac3" -> MimeTypes.AUDIO_E_AC3
                "truehd" -> MimeTypes.AUDIO_TRUEHD
                "dca", "dts" -> MimeTypes.AUDIO_DTS
                "vorbis" -> MimeTypes.AUDIO_VORBIS
                "opus" -> MimeTypes.AUDIO_OPUS
                "amrnb" -> MimeTypes.AUDIO_AMR_NB
                "amrwb" -> MimeTypes.AUDIO_AMR_WB
                "flac" -> MimeTypes.AUDIO_FLAC
                "alac" -> MimeTypes.AUDIO_ALAC
                "pcm_mulaw" -> MimeTypes.AUDIO_MLAW
                "pcm_alaw" -> MimeTypes.AUDIO_ALAW
                else -> "audio/x-ffmpeg-$codecName"
            }
        }
    }

    private lateinit var extractorOutput: ExtractorOutput
    private lateinit var trackOutput: TrackOutput

    private var nativeHandle: Long = 0L
    private var currentInput: ExtractorInput? = null
    private var isSniffing: Boolean = false

    // Stream info populated by jniOnStreamInfo during nativeOpen.
    private var codecName: String = ""
    private var sampleRate: Int = 44100
    private var channelCount: Int = 2
    private var durationUs: Long = C.TIME_UNSET
    private var extraData: ByteArray? = null

    private var pendingSeekTimeUs: Long = C.TIME_UNSET
    private var seekRepositionCount: Int = 0
    private var trackInitialized: Boolean = false

    override fun sniff(input: ExtractorInput): Boolean {
        if (!FfmpegLibrary.isAvailable()) return false

        if (onlyInterceptAbnormalWav) {
            return sniffAbnormalWav(input)
        }

        // Fallback mode: probe with libavformat using peek-only I/O.
        currentInput = input
        isSniffing = true
        var handle = 0L
        return try {
            handle = nativeOpen(input.length, input.position)
            if (handle == 0L) {
                false
            } else {
                val mime = ffmpegCodecToMimeType(codecName)
                FfmpegLibrary.supportsFormat(mime)
            }
        } finally {
            if (handle != 0L) {
                nativeClose(handle)
            }
            isSniffing = false
            currentInput = null
        }
    }

    private fun sniffAbnormalWav(input: ExtractorInput): Boolean {
        val header = ByteArray(12)
        if (!input.peekFully(header, 0, 12, true)) return false
        if (header[0] != 'R'.code.toByte() ||
            header[1] != 'I'.code.toByte() ||
            header[2] != 'F'.code.toByte() ||
            header[3] != 'F'.code.toByte() ||
            header[8] != 'W'.code.toByte() ||
            header[9] != 'A'.code.toByte() ||
            header[10] != 'V'.code.toByte() ||
            header[11] != 'E'.code.toByte()
        ) {
            return false
        }

        val probeBuf = ByteArray(WAV_PROBE_PEEK_BYTES)
        var peeked = 0
        while (peeked < WAV_PROBE_PEEK_BYTES) {
            val n = input.peek(probeBuf, peeked, WAV_PROBE_PEEK_BYTES - peeked)
            if (n == C.RESULT_END_OF_INPUT || n <= 0) break
            peeked += n
        }
        if (peeked < 24) return false

        // Walk RIFF chunks inside peeked buffer to locate fmt and data chunks.
        var offset = 0
        var formatTag = -1
        var dataOffset = -1
        while (offset + 8 <= peeked) {
            val chunkId0 = probeBuf[offset]
            val chunkId1 = probeBuf[offset + 1]
            val chunkId2 = probeBuf[offset + 2]
            val chunkId3 = probeBuf[offset + 3]
            val chunkSize = readLeInt(probeBuf, offset + 4).toLong() and 0xFFFFFFFFL
            val payloadStart = offset + 8

            if (chunkId0 == 'f'.code.toByte() &&
                chunkId1 == 'm'.code.toByte() &&
                chunkId2 == 't'.code.toByte() &&
                chunkId3 == ' '.code.toByte() &&
                payloadStart + 2 <= peeked
            ) {
                formatTag = readLeShort(probeBuf, payloadStart)
            } else if (chunkId0 == 'd'.code.toByte() &&
                chunkId1 == 'a'.code.toByte() &&
                chunkId2 == 't'.code.toByte() &&
                chunkId3 == 'a'.code.toByte()
            ) {
                dataOffset = payloadStart
                break
            }

            val paddedSize = chunkSize + (chunkSize and 1L)
            val nextOffset = payloadStart + paddedSize
            if (nextOffset <= offset || nextOffset > peeked) break
            offset = nextOffset.toInt()
        }

        if (formatTag == -1) return false

        // Non-standard WAV format tag (e.g. 0x2001 DTS): intercept immediately.
        val isStandardWavTag = formatTag == WAVE_FORMAT_PCM ||
            formatTag == WAVE_FORMAT_IEEE_FLOAT ||
            formatTag == WAVE_FORMAT_ALAW ||
            formatTag == WAVE_FORMAT_MULAW ||
            formatTag == WAVE_FORMAT_IMA_ADPCM ||
            formatTag == WAVE_FORMAT_EXTENSIBLE

        if (!isStandardWavTag) {
            return true
        }

        // For PCM (0x0001) or Extensible (0xFFFE), check data payload for disguised DTS / IEC 61937.
        if (dataOffset in 0 until peeked) {
            return containsDtsOrSpdifSync(probeBuf, dataOffset, peeked)
        }
        return false
    }

    private fun containsDtsOrSpdifSync(buf: ByteArray, start: Int, end: Int): Boolean {
        val limit = end - 4
        var i = start
        while (i <= limit) {
            val b0 = buf[i].toInt() and 0xFF
            val b1 = buf[i + 1].toInt() and 0xFF
            val b2 = buf[i + 2].toInt() and 0xFF
            val b3 = buf[i + 3].toInt() and 0xFF

            // IEC 61937 (SPDIF) Pa/Pb syncword in LE (72 F8 1F 4E) or BE (F8 72 4E 1F).
            if ((b0 == 0x72 && b1 == 0xF8 && b2 == 0x1F && b3 == 0x4E) ||
                (b0 == 0xF8 && b1 == 0x72 && b2 == 0x4E && b3 == 0x1F)
            ) {
                return true
            }
            // Raw DTS core syncword: 16-bit BE (7F FE 80 01), 16-bit LE (FE 7F 01 80),
            // 14-bit BE (1F FF E8 00), 14-bit LE (FF 1F 00 E8).
            if ((b0 == 0x7F && b1 == 0xFE && b2 == 0x80 && b3 == 0x01) ||
                (b0 == 0xFE && b1 == 0x7F && b2 == 0x01 && b3 == 0x80) ||
                (b0 == 0x1F && b1 == 0xFF && b2 == 0xE8 && b3 == 0x00) ||
                (b0 == 0xFF && b1 == 0x1F && b2 == 0x00 && b3 == 0xE8)
            ) {
                return true
            }
            i++
        }
        return false
    }

    override fun init(output: ExtractorOutput) {
        extractorOutput = output
        trackOutput = output.track(TRACK_ID, C.TRACK_TYPE_AUDIO)
    }

    override fun read(input: ExtractorInput, seekPosition: PositionHolder): Int {
        currentInput = input
        isSniffing = false
        try {
            if (nativeHandle == 0L) {
                nativeHandle = nativeOpen(input.length, input.position)
                if (nativeHandle == 0L) {
                    throw IOException("FFmpeg failed to open audio stream")
                }
                if (!trackInitialized) {
                    trackInitialized = true
                    val mimeType = ffmpegCodecToMimeType(codecName)
                    val formatBuilder = Format.Builder()
                        .setSampleMimeType(mimeType)
                        .setChannelCount(channelCount)
                        .setSampleRate(sampleRate)
                    val extra = extraData
                    if (extra != null && extra.isNotEmpty()) {
                        formatBuilder.setInitializationData(Collections.singletonList(extra))
                    }
                    trackOutput.format(formatBuilder.build())
                    extractorOutput.endTracks()
                    extractorOutput.seekMap(FfmpegSeekMap(durationUs, input.length))
                }
            }

            if (pendingSeekTimeUs != C.TIME_UNSET) {
                val seekRes = nativeSeek(nativeHandle, pendingSeekTimeUs, input.position)
                if (seekRes == READ_RESULT_SEEK) {
                    val targetPos = nativeGetDeferredSeekPos(nativeHandle)
                    if (targetPos >= 0 && seekRepositionCount < MAX_SEEK_REPOSITIONS) {
                        seekRepositionCount++
                        seekPosition.position = targetPos
                        return Extractor.RESULT_SEEK
                    }
                }
                pendingSeekTimeUs = C.TIME_UNSET
                seekRepositionCount = 0
            }

            val res = nativeReadPacket(nativeHandle, input.position)
            return when (res) {
                READ_RESULT_PACKET -> Extractor.RESULT_CONTINUE
                READ_RESULT_EOF -> Extractor.RESULT_END_OF_INPUT
                READ_RESULT_SEEK -> {
                    val targetPos = nativeGetDeferredSeekPos(nativeHandle)
                    if (targetPos >= 0 && seekRepositionCount < MAX_SEEK_REPOSITIONS) {
                        seekRepositionCount++
                        seekPosition.position = targetPos
                        Extractor.RESULT_SEEK
                    } else {
                        seekRepositionCount = 0
                        Extractor.RESULT_END_OF_INPUT
                    }
                }
                else -> throw IOException("FFmpeg read packet error")
            }
        } finally {
            currentInput = null
        }
    }

    override fun seek(position: Long, timeUs: Long) {
        if (nativeHandle == 0L) return
        pendingSeekTimeUs = timeUs
        seekRepositionCount = 0
    }

    override fun release() {
        if (nativeHandle != 0L) {
            nativeClose(nativeHandle)
            nativeHandle = 0L
        }
        currentInput = null
    }

    // --- Callbacks invoked synchronously from JNI on the current loader thread ---

    @Suppress("unused")
    private fun jniReadFromInput(target: ByteArray, length: Int): Int {
        val input = currentInput ?: return -1
        val toRead = min(length, target.size)
        return try {
            if (isSniffing) {
                input.peek(target, 0, toRead)
            } else {
                input.read(target, 0, toRead)
            }
        } catch (_: Throwable) {
            -2
        }
    }

    @Suppress("unused")
    private fun jniSkipInput(length: Int): Int {
        val input = currentInput ?: return -1
        return try {
            if (isSniffing) {
                input.advancePeekPosition(length)
                length
            } else {
                input.skip(length)
            }
        } catch (_: Throwable) {
            -2
        }
    }

    @Suppress("unused")
    private fun jniOnStreamInfo(
        codecName: String,
        sampleRate: Int,
        channels: Int,
        durationUs: Long,
        @Suppress("UNUSED_PARAMETER") currentPos: Long,
        extraData: ByteArray?,
    ) {
        this.codecName = codecName
        this.sampleRate = sampleRate
        this.channelCount = channels
        this.durationUs = if (durationUs > 0) durationUs else C.TIME_UNSET
        this.extraData = extraData
    }

    @Suppress("unused")
    private fun jniOnPacket(data: ByteArray, size: Int, ptsUs: Long) {
        if (size <= 0) return
        trackOutput.sampleData(ParsableByteArray(data, size), size)
        trackOutput.sampleMetadata(ptsUs, C.BUFFER_FLAG_KEY_FRAME, size, 0, null)
    }

    private fun readLeShort(buf: ByteArray, offset: Int): Int {
        return (buf[offset].toInt() and 0xFF) or ((buf[offset + 1].toInt() and 0xFF) shl 8)
    }

    private fun readLeInt(buf: ByteArray, offset: Int): Int {
        return (buf[offset].toInt() and 0xFF) or
            ((buf[offset + 1].toInt() and 0xFF) shl 8) or
            ((buf[offset + 2].toInt() and 0xFF) shl 16) or
            ((buf[offset + 3].toInt() and 0xFF) shl 24)
    }

    private external fun nativeOpen(inputLength: Long, initialPos: Long): Long
    private external fun nativeReadPacket(handle: Long, currentPos: Long): Int
    private external fun nativeGetDeferredSeekPos(handle: Long): Long
    private external fun nativeSeek(handle: Long, timeUs: Long, currentPos: Long): Int
    private external fun nativeClose(handle: Long)

    private class FfmpegSeekMap(
        private val durationUs: Long,
        private val inputLength: Long,
    ) : SeekMap {
        override fun isSeekable(): Boolean = durationUs != C.TIME_UNSET && durationUs > 0

        override fun getDurationUs(): Long = durationUs

        override fun getSeekPoints(timeUs: Long): SeekMap.SeekPoints {
            if (!isSeekable) {
                return SeekMap.SeekPoints(SeekPoint.START)
            }
            val clampedTime = timeUs.coerceIn(0L, durationUs)
            val estimatedPos = if (inputLength > 0) {
                (clampedTime.toDouble() / durationUs.toDouble() * inputLength.toDouble())
                    .toLong()
                    .coerceIn(0L, inputLength - 1)
            } else {
                0L
            }
            return SeekMap.SeekPoints(SeekPoint(clampedTime, estimatedPos))
        }
    }
}
