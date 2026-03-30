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
        // Always output 16-bit PCM for wide compatibility with other processors and AudioTrack
        return AudioFormat(inputAudioFormat.sampleRate, inputAudioFormat.channelCount, C.ENCODING_PCM_16BIT)
    }

    override fun queueInput(inputBuffer: ByteBuffer) {
        if (!inputBuffer.hasRemaining()) return

        val remaining = inputBuffer.remaining()
        val encoding = inputAudioFormat.encoding
        val channelCount = inputAudioFormat.channelCount
        
        // Bytes per sample: 2 for 16-bit, 4 for float
        val bytesPerSample = if (encoding == C.ENCODING_PCM_16BIT) 2 else 4
        val bytesPerFrame = bytesPerSample * channelCount
        
        // Output will always be 16-bit
        val outputSize = if (encoding == C.ENCODING_PCM_FLOAT) {
            (remaining / 4) * 2
        } else {
            remaining
        }
        val outputBuffer = replaceOutputBuffer(outputSize)

        if (encoding == C.ENCODING_PCM_FLOAT) {
            val floatBuffer = inputBuffer.asFloatBuffer()
            val floatArray = FloatArray(floatBuffer.remaining())
            floatBuffer.get(floatArray)
            inputBuffer.position(inputBuffer.position() + remaining)
            
            // Process FFT if we have enough data
            if (floatArray.size >= fftSize * channelCount) {
                for (i in 0 until fftSize) {
                    var sum = 0f
                    for (c in 0 until channelCount) {
                        sum += floatArray[i * channelCount + c]
                    }
                    fftBuffer[i] = (sum / channelCount) * window[i]
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
            
            // Convert everything to 16-bit for output
            for (f in floatArray) {
                // Clamp and convert
                val clamped = if (f > 1f) 1f else if (f < -1f) -1f else f
                outputBuffer.putShort((clamped * 32767.0f).toInt().toShort())
            }
        } else {
            // 16-bit input
            val shortBuffer = inputBuffer.asShortBuffer()
            
            // Process FFT if we have enough data
            if (remaining >= fftSize * bytesPerFrame) {
                for (i in 0 until fftSize) {
                    var sum = 0f
                    for (c in 0 until channelCount) {
                        val index = i * channelCount + c
                        if (index < shortBuffer.remaining()) {
                            sum += shortBuffer.get(index).toFloat()
                        }
                    }
                    fftBuffer[i] = (sum / channelCount / 32768f) * window[i]
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
            
            // Pass through the original 16-bit data
            outputBuffer.put(inputBuffer)
        }
        outputBuffer.flip()
    }

    fun getLatestMagnitudes(): FloatArray {
        return latestMagnitudes.get()
    }
}
