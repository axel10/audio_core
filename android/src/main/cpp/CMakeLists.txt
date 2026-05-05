cmake_minimum_required(VERSION 3.22.1)

project("my_exoplayer")

# Chromaprint Configuration for Android
set(FFT_LIB "kissfft" CACHE STRING "FFT library to use" FORCE)
set(AUDIO_PROCESSOR_LIB "" CACHE STRING "Library to use for audio processing" FORCE)
set(BUILD_TESTS OFF CACHE BOOL "Build test suite" FORCE)
set(BUILD_TOOLS OFF CACHE BOOL "Build command line tools" FORCE)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "Build shared libraries" FORCE)

# Fix for add_subdirectory() overriding CMAKE_SOURCE_DIR in FindKissFFT
set(KISSFFT_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/chromaprint/src/3rdparty/kissfft" CACHE PATH "KissFFT root directory" FORCE)
set(KISSFFT_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/chromaprint/src/3rdparty/kissfft" CACHE PATH "KissFFT source directory" FORCE)

add_subdirectory(chromaprint)

add_library( # Sets the name of the library.
        my_exoplayer

        # Sets the library as a shared library.
        SHARED

        # Provides a relative path to your source file(s).
        native-lib.cpp
        EqualizerEngine.cpp)

# Make sure our code can find chromaprint.h
target_include_directories(my_exoplayer PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/chromaprint/src)

set(AUDIO_CONVERTER_FFMPEG_ROOT
        ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../audio_converter/android/ffmpeg_lib/${CMAKE_ANDROID_ARCH_ABI}
        CACHE PATH "FFmpeg root directory for Android fallback"
)
if(EXISTS "${AUDIO_CONVERTER_FFMPEG_ROOT}/include/libavcodec/avcodec.h"
        AND EXISTS "${AUDIO_CONVERTER_FFMPEG_ROOT}/lib/libavcodec.so")
    target_compile_definitions(my_exoplayer PRIVATE ENABLE_ANDROID_FFMPEG_FALLBACK=1)
    target_compile_definitions(my_exoplayer PRIVATE USE_SWRESAMPLE=1)
    target_include_directories(my_exoplayer PRIVATE ${AUDIO_CONVERTER_FFMPEG_ROOT}/include)

    set(FFMPEG_AVCODEC_LIB ${AUDIO_CONVERTER_FFMPEG_ROOT}/lib/libavcodec.so)
    set(FFMPEG_AVFORMAT_LIB ${AUDIO_CONVERTER_FFMPEG_ROOT}/lib/libavformat.so)
    set(FFMPEG_AVUTIL_LIB ${AUDIO_CONVERTER_FFMPEG_ROOT}/lib/libavutil.so)
    set(FFMPEG_SWRESAMPLE_LIB ${AUDIO_CONVERTER_FFMPEG_ROOT}/lib/libswresample.so)
else()
    message(STATUS "Android FFmpeg fallback disabled for ABI ${CMAKE_ANDROID_ARCH_ABI}")
endif()

find_library( # Sets the name of the path variable.
        log-lib

        # Specifies the name of the NDK library that
        # you want CMake to locate.
        log)

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
        chromaprint
        ${FFMPEG_AVCODEC_LIB}
        ${FFMPEG_AVFORMAT_LIB}
        ${FFMPEG_AVUTIL_LIB}
        ${FFMPEG_SWRESAMPLE_LIB}
        ${log-lib})
