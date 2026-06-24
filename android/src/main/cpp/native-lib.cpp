#include <jni.h>
#include <android/log.h>
#include "EqualizerEngine.h"
#include <memory>
#include <string>
#include <chromaprint.h>
#include <vector>
#include <cmath>
#include <algorithm>

#ifdef ENABLE_ANDROID_FFMPEG_FALLBACK
#include "audio/ffmpeg_audio_reader.h"
#endif

#define LOG_TAG "MyExoplayerNative"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)

extern "C"
JNIEXPORT jlong JNICALL
Java_com_flutter_1rust_1bridge_audio_1core_CppEqualizerProcessor_nativeCreate(JNIEnv *env, jobject thiz) {
    auto engine = new EqualizerEngine();
    return reinterpret_cast<jlong>(engine);
}

extern "C"
JNIEXPORT void JNICALL
Java_com_flutter_1rust_1bridge_audio_1core_CppEqualizerProcessor_nativeDestroy(JNIEnv *env, jobject thiz, jlong handle) {
    if (handle != 0) {
        delete reinterpret_cast<EqualizerEngine*>(handle);
    }
}

extern "C"
JNIEXPORT void JNICALL
Java_com_flutter_1rust_1bridge_audio_1core_CppEqualizerProcessor_nativeInit(JNIEnv *env, jobject thiz, jlong handle, jint numBands, jfloat sampleRate, jint channels) {
    if (handle != 0) {
        auto* engine = reinterpret_cast<EqualizerEngine*>(handle);
        engine->init(numBands, sampleRate, channels);
    }
}

extern "C"
JNIEXPORT void JNICALL
Java_com_flutter_1rust_1bridge_audio_1core_CppEqualizerProcessor_nativeProcess(JNIEnv *env, jobject thiz, jlong handle, jobject buffer, jint numSamples, jint channels) {
    if (handle != 0) {
        auto* engine = reinterpret_cast<EqualizerEngine*>(handle);
        float* data = (float*)env->GetDirectBufferAddress(buffer);
        if (data) {
            engine->process(data, numSamples, channels);
        }
    }
}

// Control methods should also take handle or specify which instance they control.
// To keep things simple for global control, we will need a way to set parameters on all instances or one.
// Let's also add nativeSetBandGain etc. with handle.
extern "C"
JNIEXPORT void JNICALL
Java_com_flutter_1rust_1bridge_audio_1core_CppEqualizerProcessor_nativeSetBandGain(JNIEnv *env, jobject thiz, jlong handle, jint index, jfloat gainDb) {
    if (handle != 0) {
        reinterpret_cast<EqualizerEngine*>(handle)->setBandGain(index, gainDb);
    }
}

extern "C"
JNIEXPORT void JNICALL
Java_com_flutter_1rust_1bridge_audio_1core_CppEqualizerProcessor_nativeSetPreAmp(JNIEnv *env, jobject thiz, jlong handle, jfloat gainDb) {
    if (handle != 0) {
        reinterpret_cast<EqualizerEngine*>(handle)->setPreAmp(gainDb);
    }
}

extern "C"
JNIEXPORT void JNICALL
Java_com_flutter_1rust_1bridge_audio_1core_MyExoplayerPlugin_sayHelloFromCpp(JNIEnv *env, jobject thiz) {
    LOGI("Hello from C++!");
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_flutter_1rust_1bridge_audio_1core_ChromaprintNative_nativeCreate(
        JNIEnv* env,
        jobject /* this */,
        jint sampleRate,
        jint numChannels) {
    ChromaprintContext *ctx = chromaprint_new(CHROMAPRINT_ALGORITHM_DEFAULT);
    chromaprint_start(ctx, sampleRate, numChannels);
    return reinterpret_cast<jlong>(ctx);
}

extern "C" JNIEXPORT void JNICALL
Java_com_flutter_1rust_1bridge_audio_1core_ChromaprintNative_nativeProcess(
        JNIEnv* env,
        jobject /* this */,
        jlong handle,
        jobject buffer,
        jint numShorts) {
    if (handle == 0) return;
    auto *ctx = reinterpret_cast<ChromaprintContext *>(handle);
    int16_t *pcmData = static_cast<int16_t *>(env->GetDirectBufferAddress(buffer));
    if (pcmData != nullptr) {
        chromaprint_feed(ctx, pcmData, numShorts);
    }
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_flutter_1rust_1bridge_audio_1core_ChromaprintNative_nativeGetFingerprint(
        JNIEnv* env,
        jobject /* this */,
        jlong handle) {
    if (handle == 0) return nullptr;
    auto *ctx = reinterpret_cast<ChromaprintContext *>(handle);
    
    char *fp;
    if (chromaprint_get_fingerprint(ctx, &fp) == 1) {
        jstring result = env->NewStringUTF(fp);
        chromaprint_dealloc(fp); // free the char buffer
        return result;
    }
    return nullptr;
}

extern "C" JNIEXPORT void JNICALL
Java_com_flutter_1rust_1bridge_audio_1core_ChromaprintNative_nativeDestroy(
        JNIEnv* env,
        jobject /* this */,
        jlong handle) {
    if (handle != 0) {
        auto *ctx = reinterpret_cast<ChromaprintContext *>(handle);
        chromaprint_free(ctx);
    }
}

static std::string JStringToStdString(JNIEnv *env, jstring input) {
    if (!input) {
        return {};
    }
    const char *chars = env->GetStringUTFChars(input, nullptr);
    if (!chars) {
        return {};
    }
    std::string result(chars);
    env->ReleaseStringUTFChars(input, chars);
    return result;
}

#ifdef ENABLE_ANDROID_FFMPEG_FALLBACK
extern "C" JNIEXPORT jstring JNICALL
Java_com_flutter_1rust_1bridge_audio_1core_ChromaprintNative_nativeGetFingerprintFromFileFfmpeg(
        JNIEnv* env,
        jobject /* this */,
        jstring path) {
    const auto fileName = JStringToStdString(env, path);
    if (fileName.empty()) {
        return nullptr;
    }

    chromaprint::FFmpegAudioReader reader;
    if (!reader.Open(fileName)) {
        return nullptr;
    }

    ChromaprintContext *ctx = chromaprint_new(CHROMAPRINT_ALGORITHM_DEFAULT);
    if (!ctx) {
        return nullptr;
    }

    const int sampleRate = reader.GetSampleRate();
    const int channels = reader.GetChannels();
    if (sampleRate <= 0 || channels <= 0 || !chromaprint_start(ctx, sampleRate, channels)) {
        chromaprint_free(ctx);
        return nullptr;
    }

    const size_t targetFrames = static_cast<size_t>(sampleRate) * 20;
    size_t processedFrames = 0;

    while (!reader.IsFinished() && processedFrames < targetFrames) {
        const int16_t *frameData = nullptr;
        size_t frameSize = 0;
        if (!reader.Read(&frameData, &frameSize)) {
            chromaprint_free(ctx);
            return nullptr;
        }

        if (!frameData || frameSize == 0) {
            continue;
        }

        const size_t framesToProcess = std::min(frameSize, targetFrames - processedFrames);
        if (!chromaprint_feed(
                ctx,
                frameData,
                static_cast<int>(framesToProcess * static_cast<size_t>(channels)))) {
            chromaprint_free(ctx);
            return nullptr;
        }

        processedFrames += framesToProcess;
    }

    if (!chromaprint_finish(ctx)) {
        chromaprint_free(ctx);
        return nullptr;
    }

    char *fp = nullptr;
    if (chromaprint_get_fingerprint(ctx, &fp) != 1 || !fp) {
        chromaprint_free(ctx);
        return nullptr;
    }

    jstring result = env->NewStringUTF(fp);
    chromaprint_dealloc(fp);
    chromaprint_free(ctx);
    return result;
}

extern "C" JNIEXPORT jdoubleArray JNICALL
Java_com_flutter_1rust_1bridge_audio_1core_ChromaprintNative_nativeGetWaveformFromFileFfmpeg(
        JNIEnv* env,
        jobject /* this */,
        jstring path,
        jint expectedChunks) {
    const auto fileName = JStringToStdString(env, path);
    if (fileName.empty()) {
        __android_log_print(ANDROID_LOG_WARN, LOG_TAG, "getWaveform: empty path");
        return nullptr;
    }

    __android_log_print(
            ANDROID_LOG_INFO,
            LOG_TAG,
            "getWaveform: opening path=%s expectedChunks=%d",
            fileName.c_str(),
            expectedChunks);

    chromaprint::FFmpegAudioReader reader;
    if (!reader.Open(fileName)) {
        __android_log_print(
                ANDROID_LOG_WARN,
                LOG_TAG,
                "getWaveform: FFmpegAudioReader.Open failed path=%s error=%s code=%d",
                fileName.c_str(),
                reader.GetError().c_str(),
                reader.GetErrorCode());
        return nullptr;
    }

    __android_log_print(
            ANDROID_LOG_INFO,
            LOG_TAG,
            "getWaveform: open success path=%s channels=%d sampleRate=%d",
            fileName.c_str(),
            reader.GetChannels(),
            reader.GetSampleRate());

    constexpr size_t kWindowFrames = 1024;
    std::vector<double> waveform;
    waveform.reserve(expectedChunks > 0 ? static_cast<size_t>(expectedChunks) : 256);

    double sum = 0.0;
    size_t frameCount = 0;

    while (!reader.IsFinished()) {
        const int16_t *frameData = nullptr;
        size_t frameSize = 0;
        if (!reader.Read(&frameData, &frameSize)) {
            __android_log_print(
                    ANDROID_LOG_WARN,
                    LOG_TAG,
                    "getWaveform: reader.Read failed path=%s frameCount=%zu waveformChunks=%zu error=%s code=%d",
                    fileName.c_str(),
                    frameCount,
                    waveform.size(),
                    reader.GetError().c_str(),
                    reader.GetErrorCode());
            return nullptr;
        }

        if (!frameData || frameSize == 0) {
            continue;
        }

        const int channels = std::max(1, reader.GetChannels());
        for (size_t frameIndex = 0; frameIndex < frameSize; ++frameIndex) {
            double mono = 0.0;
            for (int channel = 0; channel < channels; ++channel) {
                mono += static_cast<double>(frameData[frameIndex * channels + channel]);
            }
            mono /= static_cast<double>(channels);
            sum += std::abs(mono) / 32768.0;
            ++frameCount;

            if (frameCount >= kWindowFrames) {
                waveform.push_back(sum / static_cast<double>(frameCount));
                sum = 0.0;
                frameCount = 0;
            }
        }
    }

    if (frameCount > 0) {
        waveform.push_back(sum / static_cast<double>(frameCount));
    }

    if (waveform.empty()) {
        __android_log_print(
                ANDROID_LOG_WARN,
                LOG_TAG,
                "getWaveform: waveform empty after decode path=%s",
                fileName.c_str());
        waveform.push_back(0.0);
    }

    __android_log_print(
            ANDROID_LOG_INFO,
            LOG_TAG,
            "getWaveform: finished path=%s chunks=%zu",
            fileName.c_str(),
            waveform.size());

    jdoubleArray result = env->NewDoubleArray(static_cast<jsize>(waveform.size()));
    if (!result) {
        return nullptr;
    }
    env->SetDoubleArrayRegion(result, 0, static_cast<jsize>(waveform.size()), waveform.data());
    return result;
}
#else
extern "C" JNIEXPORT jstring JNICALL
Java_com_flutter_1rust_1bridge_audio_1core_ChromaprintNative_nativeGetFingerprintFromFileFfmpeg(
        JNIEnv*,
        jobject,
        jstring) {
    return nullptr;
}

extern "C" JNIEXPORT jdoubleArray JNICALL
Java_com_flutter_1rust_1bridge_audio_1core_ChromaprintNative_nativeGetWaveformFromFileFfmpeg(
        JNIEnv*,
        jobject,
        jstring,
        jint) {
    return nullptr;
}
#endif
