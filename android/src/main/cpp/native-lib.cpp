#include <jni.h>
#include <android/log.h>

#define LOG_TAG "MyExoplayerNative"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)

extern "C"
JNIEXPORT void JNICALL
Java_com_flutter_1rust_1bridge_audio_1core_MyExoplayerPlugin_sayHelloFromCpp(JNIEnv *env, jobject thiz) {
    LOGI("Hello from C++!");
}
