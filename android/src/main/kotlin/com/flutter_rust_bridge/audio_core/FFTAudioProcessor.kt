package com.flutter_rust_bridge.audio_core
import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.AudioProcessor.AudioFormat
import androidx.media3.common.audio.BaseAudioProcessor
import androidx.media3.common.util.UnstableApi
import org.jtransforms.fft.FloatFFT_1D
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.sqrt
import kotlin.math.pow

/**
 * An AudioProcessor that calculates FFT on the PCM audio data.
 */
@UnstableApi
class FFTAudioProcessor(private val fftSize: Int = 1024) : BaseAudioProcessor() {
    enum class FftAggregationMode {
        PEAK,
        MEAN,
        RMS;

        companion object {
            fun fromName(name: String?): FftAggregationMode {
                return when (name?.lowercase()) {
                    "mean" -> MEAN
                    "rms" -> RMS
                    else -> PEAK
                }
            }
        }
    }

    private val fft = FloatFFT_1D(fftSize.toLong())
    private val fftBuffer = FloatArray(fftSize * 2) // Real and Imaginary parts
    private val window = FloatArray(fftSize)
    private val groupedLock = Any()
    
    // Accumulate samples for FFT
    private val sampleBuffer = FloatArray(fftSize)
    private var sampleCount = 0L

    // Thread-safe storage for the latest raw magnitude spectrum.
    private val latestMagnitudes = AtomicReference<FloatArray>(FloatArray(fftSize / 2))
    @Volatile
    var onFftUpdated: ((FloatArray) -> Unit)? = null

    @Volatile
    var isPaused: Boolean = false
    @Volatile
    private var frequencyGroups: Int = 32
    @Volatile
    private var skipHighFrequencyGroups: Int = 0
    @Volatile
    private var aggregationMode: FftAggregationMode = FftAggregationMode.PEAK

    init {
        // Pre-calculate Hanning window
        for (i in 0 until fftSize) {
            window[i] = (0.5 * (1.0 - Math.cos(2.0 * Math.PI * i / (fftSize - 1)))).toFloat()
        }
    }

    override fun onConfigure(inputAudioFormat: AudioFormat): AudioFormat {
        if (inputAudioFormat.encoding != C.ENCODING_PCM_16BIT && 
            inputAudioFormat.encoding != C.ENCODING_PCM_FLOAT) {
            throw AudioProcessor.UnhandledAudioFormatException(inputAudioFormat)
        }
        if (inputAudioFormat.channelCount <= 0 || inputAudioFormat.sampleRate <= 0) {
            throw AudioProcessor.UnhandledAudioFormatException(inputAudioFormat)
        }
        // Always output 16-bit PCM
        return AudioFormat(inputAudioFormat.sampleRate, inputAudioFormat.channelCount, C.ENCODING_PCM_16BIT)
    }

    override fun queueInput(inputBuffer: ByteBuffer) {
        if (!inputBuffer.hasRemaining()) return

        val remaining = inputBuffer.remaining()
        val encoding = inputAudioFormat.encoding
        val channelCount = inputAudioFormat.channelCount
        
        val bytesPerSample = if (encoding == C.ENCODING_PCM_16BIT) 2 else 4
        val bytesPerFrame = bytesPerSample * channelCount
        val frameCount = remaining / bytesPerFrame
        
        // Output will always be 16-bit
        val outputSize = frameCount * 2 * channelCount
        val outputBuffer = replaceOutputBuffer(outputSize)

        if (encoding == C.ENCODING_PCM_FLOAT) {
            val floatBuffer = inputBuffer.asFloatBuffer()
            for (i in 0 until frameCount) {
                var sum = 0f
                for (c in 0 until channelCount) {
                    val sample = floatBuffer.get()
                    sum += sample
                    
                    // Convert and put to output
                    val clamped = if (sample > 1f) 1f else if (sample < -1f) -1f else sample
                    outputBuffer.putShort((clamped * 32767.0f).toInt().toShort())
                }
                processSample(sum / channelCount)
            }
        } else {
            val shortBuffer = inputBuffer.asShortBuffer()
            for (i in 0 until frameCount) {
                var sum = 0f
                for (c in 0 until channelCount) {
                    val sample = shortBuffer.get()
                    sum += sample.toFloat()
                    
                    // Already 16-bit, just put to output
                    outputBuffer.putShort(sample)
                }
                processSample(sum / channelCount / 32768f)
            }
        }
        
        // Finalize input buffer position consumption
        inputBuffer.position(inputBuffer.position() + remaining)
        
        // Execute FFT after filling the buffer with all samples from this chunk
        runFft()
        
        outputBuffer.flip()
    }

    fun updateGroupingOptions(
        frequencyGroups: Int,
        skipHighFrequencyGroups: Int,
        aggregationMode: String?,
    ) {
        synchronized(groupedLock) {
            this.frequencyGroups = frequencyGroups.coerceAtLeast(1)
            this.skipHighFrequencyGroups = skipHighFrequencyGroups.coerceAtLeast(0)
            this.aggregationMode = FftAggregationMode.fromName(aggregationMode)
        }
    }

    private fun processSample(monoSample: Float) {
        sampleBuffer[(sampleCount % fftSize).toInt()] = monoSample
        sampleCount++
    }

    private fun runFft() {
        if (isPaused || sampleCount < fftSize) return

        for (i in 0 until fftSize) {
            // Get the latest fftSize samples in chronological order
            val index = ((sampleCount - fftSize + i) % fftSize).toInt()
            fftBuffer[i] = sampleBuffer[index] * window[i]
            fftBuffer[fftSize + i] = 0f
        }
        
        fft.realForwardFull(fftBuffer)

        val rawMagnitudes = FloatArray(fftSize / 2)
        for (i in 0 until fftSize / 2) {
            val real = fftBuffer[2 * i]
            val imag = fftBuffer[2 * i + 1]
            rawMagnitudes[i] = sqrt(real * real + imag * imag) / fftSize
        }

        latestMagnitudes.set(rawMagnitudes)
        onFftUpdated?.invoke(rawMagnitudes)
    }

    override fun onFlush() {
        resetInternalState()
    }

    override fun onReset() {
        resetInternalState()
    }

    private fun resetInternalState() {
        sampleCount = 0
        latestMagnitudes.set(FloatArray(fftSize / 2))
        for (i in sampleBuffer.indices) sampleBuffer[i] = 0f
    }

    fun getLatestMagnitudes(): FloatArray {
        return latestMagnitudes.get()
    }

    private fun groupBins(bins: FloatArray): FloatArray {
        val groups = frequencyGroups.coerceAtLeast(1)
        if (bins.isEmpty()) return FloatArray(groups)
        if (bins.size <= 1) return FloatArray(groups)

        val totalGroups = (groups + skipHighFrequencyGroups).coerceAtLeast(groups).coerceAtMost(512)
        val binCount = bins.size
        val boundaries = IntArray(totalGroups + 1) { 1 }
        boundaries[0] = 1
        boundaries[totalGroups] = binCount

        for (i in 1 until totalGroups) {
            val t = i.toDouble() / totalGroups.toDouble()
            boundaries[i] = ((binCount.toDouble().pow(t) - 1.0).toInt())
                .coerceIn(1, binCount - 1)
        }

        for (i in 1..totalGroups) {
            if (boundaries[i] <= boundaries[i - 1]) {
                boundaries[i] = (boundaries[i - 1] + 1).coerceIn(1, binCount)
            }
        }
        boundaries[totalGroups] = binCount

        val out = FloatArray(groups)
        for (g in 0 until groups) {
            val start = boundaries[g]
            val end = boundaries[g + 1]
            if (end <= start) {
                out[g] = 0f
                continue
            }

            var acc = 0f
            var peak = 0f
            var square = 0f
            for (i in start until end) {
                val value = bins[i]
                if (value > peak) peak = value
                acc += value
                square += value * value
            }

            val count = (end - start).toFloat()
            out[g] = when (aggregationMode) {
                FftAggregationMode.PEAK -> peak
                FftAggregationMode.MEAN -> acc / count
                FftAggregationMode.RMS -> sqrt(square / count)
            }
        }
        return out
    }
}
