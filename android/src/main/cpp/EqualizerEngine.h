#ifndef EQUALIZER_ENGINE_H
#define EQUALIZER_ENGINE_H

#include <vector>
#include <cmath>
#include <atomic>

enum FilterType {
    PEAKING,
    LOW_SHELF,
    HIGH_SHELF
};

struct BiquadCoefficients {
    float b0, b1, b2, a1, a2;
};

class BiquadFilter {
public:
    BiquadFilter();
    void setPeaking(float frequency, float sampleRate, float gainDb, float Q);
    void process(float* buffer, int numSamples, int channels);
    void processNeon(float* buffer, int numSamples, int channels);

    void prepare(int channels);

private:
    double b0, b1, b2, a1, a2;
    std::vector<double> z1, z2; // For each channel
};

struct EqualizerBand {
    std::atomic<float> targetFrequency{0.0f};
    std::atomic<float> targetGainDb{0.0f};
    std::atomic<float> targetQ{1.41f};

    float currentFrequency = 0.0f;
    float currentGainDb = 0.0f;
    float currentQ = 1.41f;

    BiquadFilter filter;

    EqualizerBand() = default;
    EqualizerBand(const EqualizerBand& other) {
        targetFrequency.store(other.targetFrequency.load(std::memory_order_relaxed), std::memory_order_relaxed);
        targetGainDb.store(other.targetGainDb.load(std::memory_order_relaxed), std::memory_order_relaxed);
        targetQ.store(other.targetQ.load(std::memory_order_relaxed), std::memory_order_relaxed);
        currentFrequency = other.currentFrequency;
        currentGainDb = other.currentGainDb;
        currentQ = other.currentQ;
        filter = other.filter;
    }
};

class EqualizerEngine {
public:
    EqualizerEngine();
    void init(int numBands, float sampleRate, int channels);
    void setBandGain(int index, float gainDb);
    void setBandFrequency(int index, float frequency);
    void setBandQ(int index, float Q);
    void setPreAmp(float gainDb);
    void process(float* buffer, int numSamples, int channels);

private:
    float mSampleRate;
    std::atomic<float> mTargetPreAmpLinear{1.0f};
    float mCurrentPreAmpLinear{1.0f};
    
    std::vector<EqualizerBand> mBands;
};

#endif // EQUALIZER_ENGINE_H
