#include "EqualizerEngine.h"
#include <cmath>
#include <algorithm>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

#if defined(__ARM_NEON) || defined(__ARM_NEON__) || defined(__aarch64__)
#define USE_NEON_INTRINSICS 1
#include <arm_neon.h>

// 辅助函数：快速 Clip
inline float32x4_t clamp_ps(float32x4_t val, float32x4_t min, float32x4_t max) {
    return vminq_f32(vmaxq_f32(val, min), max);
}

// Fast division for NEON using Newton-Raphson approximation
// compatible with both ARMv7 and AArch64
inline float32x4_t vdivq_f32_fast(float32x4_t num, float32x4_t den) {
    float32x4_t recip = vrecpeq_f32(den);
    recip = vmulq_f32(vrecpsq_f32(den, recip), recip); // 1st iteration
    recip = vmulq_f32(vrecpsq_f32(den, recip), recip); // 2nd iteration
    return vmulq_f32(num, recip);
}
#else
#define USE_NEON_INTRINSICS 0
#endif

BiquadFilter::BiquadFilter() : b0(1.0), b1(0.0), b2(0.0), a1(0.0), a2(0.0) {}

namespace {
constexpr float kHeadroomSmoothing = 0.15f;
constexpr float kLimiterThreshold = 0.95f;
constexpr float kLimiterKneeWidth = 0.05f;

float computeHeadroomLinear(const std::vector<EqualizerBand>& bands) {
    float maxBoostDb = 0.0f;
    for (const auto& band : bands) {
        const float gainDb = band.targetGainDb.load(std::memory_order_relaxed);
        if (gainDb > maxBoostDb) {
            maxBoostDb = gainDb;
        }
    }
    return std::pow(10.0f, -maxBoostDb / 20.0f);
}
} // namespace

void BiquadFilter::prepare(int channels) {
    if (channels <= 0) return;
    if (z1.size() != (size_t)channels) {
        z1.assign(channels, 0.0);
        z2.assign(channels, 0.0);
    }
}

void BiquadFilter::setPeaking(float frequency, float sampleRate, float gainDb, float Q) {
    double A = std::pow(10.0, (double)gainDb / 40.0);
    double omega = 2.0 * M_PI * (double)frequency / (double)sampleRate;
    double sn = std::sin(omega);
    double cs = std::cos(omega);
    double alpha = sn / (2.0 * (double)Q);

    double b0_raw = 1.0 + alpha * A;
    double b1_raw = -2.0 * cs;
    double b2_raw = 1.0 - alpha * A;
    double a0_raw = 1.0 + alpha / A;
    double a1_raw = -2.0 * cs;
    double a2_raw = 1.0 - alpha / A;

    b0 = b0_raw / a0_raw;
    b1 = b1_raw / a0_raw;
    b2 = b2_raw / a0_raw;
    a1 = a1_raw / a0_raw;
    a2 = a2_raw / a0_raw;
}

void BiquadFilter::process(float* buffer, int numSamples, int channels) {
    if (z1.size() != (size_t)channels) {
        prepare(channels);
    }

    for (int i = 0; i < numSamples; ++i) {
        for (int c = 0; c < channels; ++c) {
            double in = (double)buffer[i * channels + c];
            double out = b0 * in + z1[c];
            z1[c] = b1 * in - a1 * out + z2[c];
            z2[c] = b2 * in - a2 * out;
            buffer[i * channels + c] = (float)out;
        }
    }
}

void BiquadFilter::processNeon(float* buffer, int numSamples, int channels) {
    if (z1.size() != (size_t)channels) {
        prepare(channels);
    }

#if defined(__aarch64__) && USE_NEON_INTRINSICS
    if (channels == 2) {
        float64x2_t vb0 = vdupq_n_f64(b0);
        float64x2_t vb1 = vdupq_n_f64(b1);
        float64x2_t vb2 = vdupq_n_f64(b2);
        float64x2_t va1 = vdupq_n_f64(a1);
        float64x2_t va2 = vdupq_n_f64(a2);

        double z1_arr[2] = { z1[0], z1[1] };
        double z2_arr[2] = { z2[0], z2[1] };
        float64x2_t vz1 = vld1q_f64(z1_arr);
        float64x2_t vz2 = vld1q_f64(z2_arr);

        for (int i = 0; i < numSamples; ++i) {
            float left = buffer[i * 2];
            float right = buffer[i * 2 + 1];
            
            double in_arr[2] = { (double)left, (double)right };
            float64x2_t vin = vld1q_f64(in_arr);

            // out = b0 * in + z1
            float64x2_t vout = vfmaq_f64(vz1, vb0, vin);
            
            // z1 = b1 * in - a1 * out + z2
            float64x2_t vz1_new = vfmaq_f64(vz2, vb1, vin);
            vz1 = vfmsq_f64(vz1_new, va1, vout);

            // z2 = b2 * in - a2 * out
            float64x2_t vz2_new = vmulq_f64(vb2, vin);
            vz2 = vfmsq_f64(vz2_new, va2, vout);

            buffer[i * 2] = (float)vgetq_lane_f64(vout, 0);
            buffer[i * 2 + 1] = (float)vgetq_lane_f64(vout, 1);
        }
        
        vst1q_f64(z1_arr, vz1);
        vst1q_f64(z2_arr, vz2);
        z1[0] = z1_arr[0]; z1[1] = z1_arr[1];
        z2[0] = z2_arr[0]; z2[1] = z2_arr[1];
        return;
    }
#endif
    // Fallback if not AArch64 or not stereo
    process(buffer, numSamples, channels);
}

EqualizerEngine::EqualizerEngine() : mSampleRate(44100.0f) {}

void EqualizerEngine::init(int numBands, float sampleRate, int channels) {
    std::lock_guard<std::mutex> lock(mMutex);
    mSampleRate = sampleRate;
    mCurrentPreAmpLinear = mTargetPreAmpLinear.load(std::memory_order_relaxed);
    mCurrentHeadroomLinear = 1.0f;
    mBands.clear();
    
    if (numBands < 1) return;

    float defaultFrequencies[] = {31.25, 62.5, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0};
    
    for (int i = 0; i < numBands; ++i) {
        float freq;
        if (numBands == 10) {
             freq = defaultFrequencies[i];
        } else {
             float minFreq = 31.25f;
             float maxFreq = 16000.0f;
             float exponent = (numBands > 1) ? (float)i / (numBands - 1) : 0.0f;
             freq = minFreq * std::pow(maxFreq / minFreq, exponent);
        }
        EqualizerBand band;
        band.targetFrequency.store(freq, std::memory_order_relaxed);
        band.currentFrequency = freq;
        band.targetGainDb.store(0.0f, std::memory_order_relaxed);
        band.currentGainDb = 0.0f;
        band.targetQ.store(1.41f, std::memory_order_relaxed);
        band.currentQ = 1.41f;
        
        band.filter.prepare(channels);
        band.filter.setPeaking(freq, mSampleRate, 0.0f, 1.41f);
        mBands.push_back(band);
    }
}

void EqualizerEngine::setBandGain(int index, float gainDb) {
    std::lock_guard<std::mutex> lock(mMutex);
    if (index >= 0 && index < (int)mBands.size()) {
        mBands[index].targetGainDb.store(gainDb, std::memory_order_relaxed);
    }
}

void EqualizerEngine::setBandFrequency(int index, float frequency) {
    std::lock_guard<std::mutex> lock(mMutex);
    if (index >= 0 && index < (int)mBands.size()) {
        mBands[index].targetFrequency.store(frequency, std::memory_order_relaxed);
    }
}

void EqualizerEngine::setBandQ(int index, float Q) {
    std::lock_guard<std::mutex> lock(mMutex);
    if (index >= 0 && index < (int)mBands.size()) {
        mBands[index].targetQ.store(Q, std::memory_order_relaxed);
    }
}

void EqualizerEngine::setPreAmp(float gainDb) {
    float linearGain = std::pow(10.0f, gainDb / 20.0f);
    mTargetPreAmpLinear.store(linearGain, std::memory_order_relaxed);
}

void EqualizerEngine::process(float* buffer, int numSamples, int channels) {
    std::lock_guard<std::mutex> lock(mMutex);
    int totalSamples = numSamples * channels;
    const float SMOOTH_FACTOR = 0.2f;

    // 1. Thread-safe updates (lock-free) and parameter smoothing
    float tPreAmp = mTargetPreAmpLinear.load(std::memory_order_relaxed);
    if (std::abs(tPreAmp - mCurrentPreAmpLinear) > 0.001f) {
        mCurrentPreAmpLinear += SMOOTH_FACTOR * (tPreAmp - mCurrentPreAmpLinear);
    } else {
        mCurrentPreAmpLinear = tPreAmp;
    }

    for (auto& band : mBands) {
        float tFreq = band.targetFrequency.load(std::memory_order_relaxed);
        float tGain = band.targetGainDb.load(std::memory_order_relaxed);
        float tQ = band.targetQ.load(std::memory_order_relaxed);

        bool needsUpdate = false;

        if (std::abs(tFreq - band.currentFrequency) > 0.1f) {
            band.currentFrequency += SMOOTH_FACTOR * (tFreq - band.currentFrequency);
            needsUpdate = true;
        } else if (band.currentFrequency != tFreq) {
            band.currentFrequency = tFreq;
            needsUpdate = true;
        }

        if (std::abs(tGain - band.currentGainDb) > 0.01f) {
            band.currentGainDb += SMOOTH_FACTOR * (tGain - band.currentGainDb);
            needsUpdate = true;
        } else if (band.currentGainDb != tGain) {
            band.currentGainDb = tGain;
            needsUpdate = true;
        }

        if (std::abs(tQ - band.currentQ) > 0.01f) {
            band.currentQ += SMOOTH_FACTOR * (tQ - band.currentQ);
            needsUpdate = true;
        } else if (band.currentQ != tQ) {
            band.currentQ = tQ;
            needsUpdate = true;
        }

        if (needsUpdate) {
            band.filter.setPeaking(band.currentFrequency, mSampleRate, band.currentGainDb, band.currentQ);
        }
    }

    float desiredHeadroomLinear = computeHeadroomLinear(mBands);
    if (std::abs(desiredHeadroomLinear - mCurrentHeadroomLinear) > 0.001f) {
        mCurrentHeadroomLinear +=
            kHeadroomSmoothing * (desiredHeadroomLinear - mCurrentHeadroomLinear);
    } else {
        mCurrentHeadroomLinear = desiredHeadroomLinear;
    }

    // Rust 侧的策略是：当有正增益时先把前级整体降下来，再让 EQ 去抬频段，
    // 这样能保留 headroom 而不是靠每个 buffer 动态抽吸。
    float totalGain = mCurrentPreAmpLinear * mCurrentHeadroomLinear;

    // 2. 应用 Pre-Amp 增益 
    if (totalGain != 1.0f) {
#if USE_NEON_INTRINSICS
        float32x4_t vGain = vdupq_n_f32(totalGain);
        int i = 0;
        for (; i <= totalSamples - 4; i += 4) {
            float32x4_t vData = vld1q_f32(&buffer[i]);
            vst1q_f32(&buffer[i], vmulq_f32(vData, vGain));
        }
        for (; i < totalSamples; ++i) {
            buffer[i] *= totalGain;
        }
#else
        for (int i = 0; i < totalSamples; ++i) {
            buffer[i] *= totalGain;
        }
#endif
    }

    // 3. 滤波器处理
    for (auto& band : mBands) {
        if (channels == 2) {
            band.filter.processNeon(buffer, numSamples, channels);
        } else {
            band.filter.process(buffer, numSamples, channels);
        }
    }

    // 4. 软限制器和安全 Hard Clamp
#if USE_NEON_INTRINSICS
    float32x4_t vOne = vdupq_n_f32(1.0f);
    float32x4_t vNegOne = vdupq_n_f32(-1.0f);
    float32x4_t vThreshold = vdupq_n_f32(kLimiterThreshold);
    float32x4_t vSoftKneeMult = vdupq_n_f32(1.0f / kLimiterKneeWidth);

    int j = 0;
    for (; j <= totalSamples - 4; j += 4) {
        float32x4_t x = vld1q_f32(&buffer[j]);
        float32x4_t abs_x = vabsq_f32(x);
        
        // 计算软限制: diff = max(0, abs_x - threshold)
        float32x4_t diff = vmaxq_f32(vdupq_n_f32(0.0f), vsubq_f32(abs_x, vThreshold));
        
        // denom = 1.0 + diff * 6.6666667
        float32x4_t denom = vaddq_f32(vOne, vmulq_f32(diff, vSoftKneeMult));
        
        // shaped = threshold + diff / denom
        float32x4_t shaped_magnitude = vaddq_f32(vThreshold, vdivq_f32_fast(diff, denom));
        
        // 恢复符号: copy sign bit from x to shaped_magnitude
        uint32x4_t sign_mask = vdupq_n_u32(0x80000000);
        float32x4_t sign_x = vreinterpretq_f32_u32(vandq_u32(vreinterpretq_u32_f32(x), sign_mask));
        float32x4_t shaped_x = vreinterpretq_f32_u32(vorrq_u32(vreinterpretq_u32_f32(shaped_magnitude), sign_x));
        
        // mix: 如果 abs_x > threshold，使用 shaped_x，否则保留原始 x
        uint32x4_t gt_mask = vcgtq_f32(abs_x, vThreshold);
        x = vbslq_f32(gt_mask, shaped_x, x);
        
        // 最终 Hard Clamp
        x = clamp_ps(x, vNegOne, vOne);
        vst1q_f32(&buffer[j], x);
    }
    
    // 处理剩余的非 4 倍数点
    for (; j < totalSamples; ++j) {
        float x = buffer[j];
        float abs_x = std::abs(x);
        if (abs_x > kLimiterThreshold) {
            float diff = abs_x - kLimiterThreshold;
            float shaped =
                kLimiterThreshold + diff / (1.0f + diff / kLimiterKneeWidth);
            x = (x > 0.0f) ? shaped : -shaped;
        }
        buffer[j] = std::max(-1.0f, std::min(1.0f, x));
    }
#else
    for (int j = 0; j < totalSamples; ++j) {
        float x = buffer[j];
        float abs_x = std::abs(x);
        if (abs_x > kLimiterThreshold) {
            float diff = abs_x - kLimiterThreshold;
            float shaped =
                kLimiterThreshold + diff / (1.0f + diff / kLimiterKneeWidth);
            x = (x > 0.0f) ? shaped : -shaped;
        }
        buffer[j] = std::max(-1.0f, std::min(1.0f, x));
    }
#endif
}
