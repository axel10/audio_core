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

find_library( # Sets the name of the path variable.
        log-lib

        # Specifies the name of the NDK library that
        # you want CMake to locate.
        log)

target_link_libraries( # Specifies the target library.
        my_exoplayer

        # Links the target library to the log library
        # included in the NDK.
        chromaprint
        ${log-lib})
