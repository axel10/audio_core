package com.flutter_rust_bridge.audio_core.extractor

import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.util.ParsableByteArray
import androidx.media3.extractor.Extractor
import androidx.media3.extractor.ExtractorInput
import androidx.media3.extractor.ExtractorOutput
import androidx.media3.extractor.PositionHolder
import androidx.media3.extractor.SeekMap
import androidx.media3.extractor.SeekPoint
import androidx.media3.extractor.TrackOutput
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Collections

/** Extracts DSF's channel-planar DSD blocks as interleaved DSD-LSB packets for FFmpeg. */
internal class DsfExtractor : Extractor {
    companion object {
        const val MIME_TYPE = "audio/x-dsf"
        private const val HEADER_SIZE = 28
        private const val CHUNK_HEADER_SIZE = 12
        private const val FORMAT_CHUNK_MIN_SIZE = 52L
        private const val TRACK_ID = 0
        private const val ANDROID_OUTPUT_SAMPLE_RATE = 48_000
    }

    private lateinit var extractorOutput: ExtractorOutput
    private lateinit var trackOutput: TrackOutput
    private var parsed = false
    private var dataStartPosition = 0L
    private var dataEndPosition = 0L
    private var channelCount = 0
    private var sampleRate = 0
    private var sampleCount = 0L
    private var blockSizePerChannel = 0
    private var packetSize = 0
    private var dataBytesRead = 0L

    override fun sniff(input: ExtractorInput): Boolean {
        val signature = ByteArray(4)
        return input.peekFully(signature, 0, signature.size, true) && signature.contentEquals("DSD ".toByteArray())
    }

    override fun init(output: ExtractorOutput) {
        extractorOutput = output
        trackOutput = output.track(TRACK_ID, C.TRACK_TYPE_AUDIO)
    }

    override fun read(input: ExtractorInput, seekPosition: PositionHolder): Int {
        if (!parsed) {
            parseHeader(input)
            parsed = true
            trackOutput.format(
                Format.Builder()
                    .setSampleMimeType(MIME_TYPE)
                    .setChannelCount(channelCount)
                    // Android AudioTrack does not universally support the DSD
                    // PCM-equivalent rate (for example 352.8 kHz). The FFmpeg
                    // decoder uses this value as its output resampling target.
                    .setSampleRate(ANDROID_OUTPUT_SAMPLE_RATE)
                    .setAverageBitrate((sampleRate.toLong() * channelCount).coerceAtMost(Int.MAX_VALUE.toLong()).toInt())
                    .setInitializationData(Collections.singletonList(littleEndianIntBytes(sampleRate)))
                    .build(),
            )
            extractorOutput.endTracks()
            extractorOutput.seekMap(DsfSeekMap(dataStartPosition, dataEndPosition, sampleRate, channelCount, blockSizePerChannel, sampleCount))
        }

        if (dataStartPosition + dataBytesRead >= dataEndPosition) {
            return Extractor.RESULT_END_OF_INPUT
        }

        val remaining = dataEndPosition - dataStartPosition - dataBytesRead
        if (remaining < packetSize) {
            throw IOException("Truncated DSF data block")
        }

        val planar = ByteArray(packetSize)
        input.readFully(planar, 0, packetSize)
        val interleaved = ByteArray(packetSize)
        for (sampleByte in 0 until blockSizePerChannel) {
            for (channel in 0 until channelCount) {
                interleaved[sampleByte * channelCount + channel] = planar[channel * blockSizePerChannel + sampleByte]
            }
        }

        val timeUs = dataBytesRead / channelCount * 8L * 1_000_000L / sampleRate
        trackOutput.sampleData(ParsableByteArray(interleaved), interleaved.size)
        trackOutput.sampleMetadata(timeUs, C.BUFFER_FLAG_KEY_FRAME, interleaved.size, 0, null)
        dataBytesRead += packetSize
        return Extractor.RESULT_CONTINUE
    }

    override fun seek(position: Long, timeUs: Long) {
        // Media3 invokes seek(0, 0) after sniffing, before the first read has
        // parsed the DSF format block and established the packet size.
        if (!parsed) return
        dataBytesRead = (position - dataStartPosition).coerceIn(0L, dataEndPosition - dataStartPosition)
        dataBytesRead -= dataBytesRead % packetSize
    }

    override fun release() = Unit

    private fun parseHeader(input: ExtractorInput) {
        val header = ByteArray(HEADER_SIZE)
        input.readFully(header, 0, header.size)
        if (!header.copyOfRange(0, 4).contentEquals("DSD ".toByteArray())) {
            throw IOException("Invalid DSF file signature")
        }
        val headerSize = littleEndianLong(header, 4)
        if (headerSize != HEADER_SIZE.toLong()) {
            throw IOException("Unsupported DSF header size: $headerSize")
        }

        var foundFormat = false
        while (!foundFormat) {
            val chunkHeader = readChunkHeader(input)
            when (chunkHeader.id) {
                "fmt " -> {
                    if (chunkHeader.size < FORMAT_CHUNK_MIN_SIZE) {
                        throw IOException("Invalid DSF format chunk size: ${chunkHeader.size}")
                    }
                    val format = ByteArray((chunkHeader.size - CHUNK_HEADER_SIZE).toInt())
                    input.readFully(format, 0, format.size)
                    val formatVersion = littleEndianInt(format, 0)
                    val formatId = littleEndianInt(format, 4)
                    channelCount = littleEndianInt(format, 12)
                    sampleRate = littleEndianInt(format, 16)
                    val bitsPerSample = littleEndianInt(format, 20)
                    sampleCount = littleEndianLong(format, 24)
                    blockSizePerChannel = littleEndianInt(format, 32)
                    if (formatVersion != 1 || formatId != 0 || bitsPerSample != 1 || channelCount !in 1..8 || sampleRate <= 0 || sampleCount <= 0 || blockSizePerChannel <= 0) {
                        throw IOException("Unsupported DSF format")
                    }
                    packetSize = Math.multiplyExact(channelCount, blockSizePerChannel)
                    foundFormat = true
                }
                else -> skipFully(input, chunkHeader.size - CHUNK_HEADER_SIZE)
            }
        }

        while (true) {
            val chunkHeader = readChunkHeader(input)
            if (chunkHeader.id == "data") {
                if (chunkHeader.size <= CHUNK_HEADER_SIZE) throw IOException("Empty DSF data chunk")
                dataStartPosition = input.position
                dataEndPosition = dataStartPosition + chunkHeader.size - CHUNK_HEADER_SIZE
                if ((dataEndPosition - dataStartPosition) % packetSize != 0L) {
                    throw IOException("DSF data is not aligned to its channel block size")
                }
                return
            }
            skipFully(input, chunkHeader.size - CHUNK_HEADER_SIZE)
        }
    }

    private fun readChunkHeader(input: ExtractorInput): ChunkHeader {
        val bytes = ByteArray(CHUNK_HEADER_SIZE)
        input.readFully(bytes, 0, bytes.size)
        val size = littleEndianLong(bytes, 4)
        if (size < CHUNK_HEADER_SIZE) throw IOException("Invalid DSF chunk size: $size")
        return ChunkHeader(bytes.copyOfRange(0, 4).toString(Charsets.US_ASCII), size)
    }

    private fun skipFully(input: ExtractorInput, bytes: Long) {
        var remaining = bytes
        while (remaining > 0) {
            val step = minOf(remaining, Int.MAX_VALUE.toLong()).toInt()
            input.skipFully(step)
            remaining -= step
        }
    }

    private data class ChunkHeader(val id: String, val size: Long)

    private class DsfSeekMap(
        private val dataStart: Long,
        private val dataEnd: Long,
        private val sampleRate: Int,
        private val channelCount: Int,
        private val blockSizePerChannel: Int,
        sampleCount: Long,
    ) : SeekMap {
        private val blockSize = blockSizePerChannel * channelCount
        private val durationUs = sampleCount * 1_000_000L / sampleRate

        override fun isSeekable() = true

        override fun getDurationUs() = durationUs

        override fun getSeekPoints(timeUs: Long): SeekMap.SeekPoints {
            val clampedTimeUs = timeUs.coerceIn(0L, durationUs)
            val bytesPerChannel = clampedTimeUs * sampleRate / 8L / 1_000_000L
            val blockOffset = (bytesPerChannel / blockSizePerChannel) * blockSize
            val position = (dataStart + blockOffset).coerceAtMost(dataEnd - blockSize)
            val actualTimeUs = (blockOffset / channelCount) * 8L * 1_000_000L / sampleRate
            return SeekMap.SeekPoints(SeekPoint(actualTimeUs, position))
        }
    }

    private fun littleEndianInt(bytes: ByteArray, offset: Int): Int =
        ByteBuffer.wrap(bytes, offset, Int.SIZE_BYTES).order(ByteOrder.LITTLE_ENDIAN).int

    private fun littleEndianLong(bytes: ByteArray, offset: Int): Long =
        ByteBuffer.wrap(bytes, offset, Long.SIZE_BYTES).order(ByteOrder.LITTLE_ENDIAN).long

    private fun littleEndianIntBytes(value: Int): ByteArray =
        ByteBuffer.allocate(Int.SIZE_BYTES).order(ByteOrder.LITTLE_ENDIAN).putInt(value).array()
}
