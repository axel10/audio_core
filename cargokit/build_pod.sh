#!/bin/sh
set -e

BASEDIR=$(dirname "$0")

# Workaround for https://github.com/dart-lang/pub/issues/4010
BASEDIR=$(cd "$BASEDIR" ; pwd -P)

# Remove XCode SDK from path. Otherwise this breaks tool compilation when building iOS project
NEW_PATH=`echo $PATH | tr ":" "\n" | grep -v "Contents/Developer/" | tr "\n" ":"`

export PATH=${NEW_PATH%?} # remove trailing :

env

# Platform name (macosx, iphoneos, iphonesimulator)
export CARGOKIT_DARWIN_PLATFORM_NAME=$PLATFORM_NAME

# Arctive architectures (arm64, armv7, x86_64), space separated.
export CARGOKIT_DARWIN_ARCHS=$ARCHS

# Current build configuration (Debug, Release)
export CARGOKIT_CONFIGURATION=$CONFIGURATION

# Path to directory containing Cargo.toml.
export CARGOKIT_MANIFEST_DIR=$PODS_TARGET_SRCROOT/$1

# Temporary directory for build artifacts.
export CARGOKIT_TARGET_TEMP_DIR=$TARGET_TEMP_DIR

# Output directory for final artifacts.
export CARGOKIT_OUTPUT_DIR=$PODS_CONFIGURATION_BUILD_DIR/$PRODUCT_NAME

# Directory to store built tool artifacts.
export CARGOKIT_TOOL_TEMP_DIR=$TARGET_TEMP_DIR/build_tool

# Directory inside root project. Not necessarily the top level directory of root project.
export CARGOKIT_ROOT_PROJECT_DIR=$SRCROOT

# Locate SFBAudioEngine directory robustly (supports local checkouts, SPM in DerivedData, and SPM global cache)
SFBAUDIOENGINE_DIR=""
if [ -d "$BASEDIR/../SFBAudioEngine" ]; then
  SFBAUDIOENGINE_DIR="$BASEDIR/../SFBAudioEngine"
fi

if [ -z "$SFBAUDIOENGINE_DIR" ] && [ -n "$OBJROOT" ]; then
  CURRENT_DIR="$OBJROOT"
  while [ "$CURRENT_DIR" != "/" ] && [ "$CURRENT_DIR" != "." ]; do
    if [ -d "$CURRENT_DIR/SourcePackages/checkouts/SFBAudioEngine" ]; then
      SFBAUDIOENGINE_DIR="$CURRENT_DIR/SourcePackages/checkouts/SFBAudioEngine"
      break
    elif [ -d "$CURRENT_DIR/SourcePackages/checkouts/sfbaudioengine" ]; then
      SFBAUDIOENGINE_DIR="$CURRENT_DIR/SourcePackages/checkouts/sfbaudioengine"
      break
    fi
    CURRENT_DIR=$(dirname "$CURRENT_DIR")
  done
fi

if [ -z "$SFBAUDIOENGINE_DIR" ]; then
  GLOBAL_SPM_DIR="$HOME/Library/Caches/org.swift.swiftpm/checkouts"
  if [ -d "$GLOBAL_SPM_DIR/SFBAudioEngine" ]; then
    SFBAUDIOENGINE_DIR="$GLOBAL_SPM_DIR/SFBAudioEngine"
  elif [ -d "$GLOBAL_SPM_DIR/sfbaudioengine" ]; then
    SFBAUDIOENGINE_DIR="$GLOBAL_SPM_DIR/sfbaudioengine"
  fi
fi

if [ -z "$SFBAUDIOENGINE_DIR" ] || [ ! -d "$SFBAUDIOENGINE_DIR" ]; then
  echo "Error: SFBAudioEngine dependency directory not found!" >&2
  exit 1
fi

# Give ffmpeg-sys-next a concrete prebuilt FFmpeg root for cross-compilation or local builds.
SRC_DIR=""
LINK_NAME=""

case "$PLATFORM_NAME" in
  iphoneos)
    SRC_DIR="$SFBAUDIOENGINE_DIR/macos/Frameworks/FFmpeg.xcframework/ios-arm64"
    LINK_NAME="ios-arm64"
    ;;
  iphonesimulator)
    SRC_DIR="$SFBAUDIOENGINE_DIR/macos/Frameworks/FFmpeg.xcframework/ios-arm64-simulator"
    LINK_NAME="ios-sim-arm64"
    ;;
  macosx)
    SRC_DIR="$SFBAUDIOENGINE_DIR/macos/Frameworks/FFmpeg.xcframework/macos-arm64_x86_64"
    LINK_NAME="macos-universal"
    ;;
esac

if [ -n "$SRC_DIR" ] && [ -d "$SRC_DIR" ]; then
  TARGET_LINK_DIR="$BASEDIR/../build/ffmpeg-link-sdk/$LINK_NAME"
  mkdir -p "$TARGET_LINK_DIR/lib"
  
  # Symlink include directory to Headers
  ln -sfn "$SRC_DIR/Headers" "$TARGET_LINK_DIR/include"
  
  # Symlink libffmpeg.a as individual static libraries to satisfy ffmpeg-sys-next
  ln -sf "$SRC_DIR/libffmpeg.a" "$TARGET_LINK_DIR/lib/libavcodec.a"
  ln -sf "$SRC_DIR/libffmpeg.a" "$TARGET_LINK_DIR/lib/libavformat.a"
  ln -sf "$SRC_DIR/libffmpeg.a" "$TARGET_LINK_DIR/lib/libavutil.a"
  ln -sf "$SRC_DIR/libffmpeg.a" "$TARGET_LINK_DIR/lib/libswresample.a"
  ln -sf "$SRC_DIR/libffmpeg.a" "$TARGET_LINK_DIR/lib/libswscale.a"
  
  export FFMPEG_DIR="$TARGET_LINK_DIR"
fi

FLUTTER_EXPORT_BUILD_ENVIRONMENT=(
  "$PODS_ROOT/../Flutter/ephemeral/flutter_export_environment.sh" # macOS
  "$PODS_ROOT/../Flutter/flutter_export_environment.sh" # iOS
)

for path in "${FLUTTER_EXPORT_BUILD_ENVIRONMENT[@]}"
do
  if [[ -f "$path" ]]; then
    source "$path"
  fi
done

sh "$BASEDIR/run_build_tool.sh" build-pod "$@"

# Make a symlink from built framework to phony file, which will be used as input to
# build script. This should force rebuild (podspec currently doesn't support alwaysOutOfDate
# attribute on custom build phase)
ln -fs "$OBJROOT/XCBuildData/build.db" "${BUILT_PRODUCTS_DIR}/cargokit_phony"
ln -fs "${BUILT_PRODUCTS_DIR}/${EXECUTABLE_PATH}" "${BUILT_PRODUCTS_DIR}/cargokit_phony_out"
