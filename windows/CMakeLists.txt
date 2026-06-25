# The Flutter tooling requires that developers have a version of Visual Studio
# installed that includes CMake 3.14 or later. You should not increase this
# version, as doing so will cause the plugin to fail to compile for some
# customers of the plugin.
cmake_minimum_required(VERSION 3.14)

# Project-level configuration.
set(PROJECT_NAME "audio_core")
project(${PROJECT_NAME} LANGUAGES CXX)

set(FFMPEG_DIR "${CMAKE_CURRENT_SOURCE_DIR}/third_party/ffmpeg")

if(NOT EXISTS "${FFMPEG_DIR}/bin/avcodec-62.dll")
  message(STATUS "Precompiled FFmpeg Windows binaries not found at ${FFMPEG_DIR}. Downloading...")
  set(DOWNLOAD_SCRIPT "${CMAKE_CURRENT_SOURCE_DIR}/../download-ffmpeg-windows.ps1")
  get_filename_component(DOWNLOAD_SCRIPT "${DOWNLOAD_SCRIPT}" REALPATH)
  execute_process(
    COMMAND powershell -ExecutionPolicy Bypass -File "${DOWNLOAD_SCRIPT}"
    RESULT_VARIABLE DOWNLOAD_RESULT
  )
  if(NOT DOWNLOAD_RESULT EQUAL 0)
    message(FATAL_ERROR "Failed to download FFmpeg dependencies via download-ffmpeg-windows.ps1")
  endif()
endif()

include("../cargokit/cmake/cargokit.cmake")
apply_cargokit(${PROJECT_NAME} ../rust audio_core "")

# List of absolute paths to libraries that should be bundled with the plugin.
# This list could contain prebuilt libraries, or libraries created by an
# external build triggered from this build file.
set(audio_core_bundled_libraries
  "${${PROJECT_NAME}_cargokit_lib}"
  "${FFMPEG_DIR}/bin/avcodec-62.dll"
  "${FFMPEG_DIR}/bin/avfilter-11.dll"
  "${FFMPEG_DIR}/bin/avformat-62.dll"
  "${FFMPEG_DIR}/bin/avutil-60.dll"
  "${FFMPEG_DIR}/bin/libmp3lame.dll"
  "${FFMPEG_DIR}/bin/opus.dll"
  "${FFMPEG_DIR}/bin/swresample-6.dll"
  PARENT_SCOPE
)
