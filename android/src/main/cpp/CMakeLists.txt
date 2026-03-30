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

target_link_libraries( # Specifies the target library.
        my_exoplayer

        # Links the target library to the log library
        # included in the NDK.
        ${log-lib})
