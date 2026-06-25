cmake_minimum_required(VERSION 3.22.1)

project("my_exoplayer")

add_library( # Sets the name of the library.
        my_exoplayer

        # Sets the library as a shared library.
        SHARED

        # Provides a relative path to your source file(s).
        native-lib.cpp
        EqualizerEngine.cpp)

find_library( # Sets the name of the path variable.
        log-lib

        # Specifies the name of the NDK library that
        # you want CMake to locate.
        log)

set(AUDIO_CONVERTER_FFMPEG_ROOT
        ${CMAKE_CURRENT_SOURCE_DIR}/../../../ffmpeg_lib/${CMAKE_ANDROID_ARCH_ABI}
        CACHE PATH "FFmpeg root directory for Android fallback"
)
set(FFMPEG_AVCODEC_LIB ${AUDIO_CONVERTER_FFMPEG_ROOT}/lib/libavcodec.so)
set(FFMPEG_AVUTIL_LIB ${AUDIO_CONVERTER_FFMPEG_ROOT}/lib/libavutil.so)
set(FFMPEG_SWRESAMPLE_LIB ${AUDIO_CONVERTER_FFMPEG_ROOT}/lib/libswresample.so)

set(MEDIA3_FFMPEG_JNI_SOURCE
        ${CMAKE_CURRENT_SOURCE_DIR}/../../../media3-src/decoder_ffmpeg/src/main/jni/ffmpeg_jni.cc)
if(EXISTS "${MEDIA3_FFMPEG_JNI_SOURCE}"
        AND EXISTS "${AUDIO_CONVERTER_FFMPEG_ROOT}/include/libavcodec/avcodec.h"
        AND EXISTS "${AUDIO_CONVERTER_FFMPEG_ROOT}/lib/libavcodec.so")
    add_library(ffmpegJNI SHARED ${MEDIA3_FFMPEG_JNI_SOURCE})
    set_target_properties(ffmpegJNI PROPERTIES CXX_STANDARD 11 CXX_STANDARD_REQUIRED YES)
    target_include_directories(ffmpegJNI PRIVATE ${AUDIO_CONVERTER_FFMPEG_ROOT}/include)

    target_link_libraries(ffmpegJNI
            PRIVATE
            android
            ${FFMPEG_AVCODEC_LIB}
            ${FFMPEG_AVUTIL_LIB}
            ${FFMPEG_SWRESAMPLE_LIB}
            ${log-lib})

    if(CMAKE_ANDROID_ARCH_ABI STREQUAL "arm64-v8a")
        target_link_options(ffmpegJNI PRIVATE "-Wl,-Bsymbolic")
    endif()

    target_link_options(ffmpegJNI PRIVATE "-Wl,-z,max-page-size=16384")
else()
    message(STATUS "Media3 FFmpeg JNI disabled for ABI ${CMAKE_ANDROID_ARCH_ABI}")
endif()

target_link_libraries( # Specifies the target library.
        my_exoplayer

        # Links the target library to the log library
        # included in the NDK.
        ${log-lib})
