#include <jni.h>
#include <android/log.h>
#include "EqualizerEngine.h"
#include <memory>

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
