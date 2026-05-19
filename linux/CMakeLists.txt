# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

# Project-level configuration.
set(PROJECT_NAME "audio_core")
project(${PROJECT_NAME} LANGUAGES CXX)

include("../cargokit/cmake/cargokit.cmake")
apply_cargokit(${PROJECT_NAME} ../rust audio_core "")

# List of absolute paths to libraries that should be bundled with the plugin.
# This list could contain prebuilt libraries, or libraries created by an
# external build triggered from this build file.
set(audio_core_bundled_libraries
  "${${PROJECT_NAME}_cargokit_lib}"
)

set(LOCAL_FFMPEG_LIB_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../build/ffmpeg-linux/install/lib")
get_filename_component(LOCAL_FFMPEG_LIB_DIR "${LOCAL_FFMPEG_LIB_DIR}" REALPATH)
if (EXISTS "${LOCAL_FFMPEG_LIB_DIR}")
    file(GLOB FFMPEG_LIBS "${LOCAL_FFMPEG_LIB_DIR}/*.so*")
    list(APPEND audio_core_bundled_libraries ${FFMPEG_LIBS})
endif()

set(audio_core_bundled_libraries
  ${audio_core_bundled_libraries}
  PARENT_SCOPE
)
