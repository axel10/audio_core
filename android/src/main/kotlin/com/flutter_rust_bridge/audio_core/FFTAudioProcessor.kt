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

/**
 * An AudioProcessor that calculates FFT on the PCM audio data.
 */
@UnstableApi
class FFTAudioProcessor(private val fftSize: Int = 1024) : BaseAudioProcessor() {

    private val fft = FloatFFT_1D(fftSize.toLong())
    private val fftBuffer = FloatArray(fftSize * 2) // Real and Imaginary parts
    private val window = FloatArray(fftSize)
    
    // Accumulate samples for FFT
    private val sampleBuffer = FloatArray(fftSize)
    private var sampleCount = 0L

    // Thread-safe storage for the latest magnitude spectrum
    private val latestMagnitudes = AtomicReference<FloatArray>(FloatArray(fftSize / 2))

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

    private fun processSample(monoSample: Float) {
        sampleBuffer[(sampleCount % fftSize).toInt()] = monoSample
        sampleCount++
    }

    private fun runFft() {
        if (sampleCount < fftSize) return

        for (i in 0 until fftSize) {
            // Get the latest fftSize samples in chronological order
            val index = ((sampleCount - fftSize + i) % fftSize).toInt()
            fftBuffer[i] = sampleBuffer[index] * window[i]
            fftBuffer[fftSize + i] = 0f
        }
        
        fft.realForwardFull(fftBuffer)
        
        val magnitudes = FloatArray(fftSize / 2)
        for (i in 0 until fftSize / 2) {
            val real = fftBuffer[2 * i]
            val imag = fftBuffer[2 * i + 1]
            magnitudes[i] = sqrt(real * real + imag * imag) / fftSize
        }
        latestMagnitudes.set(magnitudes)
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
}
