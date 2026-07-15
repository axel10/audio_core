#!/usr/bin/env bash
set -euo pipefail

DEPLOYMENT_TARGET="11.0"
CLEAN=false
JOBS=""

usage() {
  cat <<EOF
Usage: ./build-ffmpeg-apple.sh [--clean] [--jobs N]

Options:
  --clean      Remove all build/install directories before configuring.
  --jobs N     Number of parallel jobs for make. Defaults to CPU count.
  -h, --help   Show this help message.
EOF
}

while (($#)); do
  case "$1" in
    --clean) CLEAN=true; shift ;;
    --jobs) JOBS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -z "$JOBS" ]]; then
  if command -v sysctl >/dev/null 2>&1; then
    JOBS="$(sysctl -n hw.ncpu)"
  else
    JOBS=1
  fi
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$script_dir"

log() {
  printf "[$(date +%H:%M:%S)] %s\n" "$*"
}

find_source_dir() {
  local name="$1"
  local candidate
  while IFS= read -r candidate; do
    if [[ -n "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(
    find "$repo_root" -maxdepth 1 -mindepth 1 -type d \
      \( -name "$name" -o -name "${name}-*" -o -name "${name}_*" -o -name "*${name}*" \) \
      -exec test -x '{}/configure' \; -print | sort
  )
  return 1
}

ffmpeg_root="$(find_source_dir FFmpeg || find_source_dir ffmpeg || true)"
lame_root="$(find_source_dir lame || true)"
opus_root="$(find_source_dir opus || true)"

[[ -z "$ffmpeg_root" ]] && { echo "Error: FFmpeg source not found in $repo_root" >&2; exit 1; }
[[ -z "$lame_root" ]] && { echo "Error: LAME source not found in $repo_root" >&2; exit 1; }
[[ -z "$opus_root" ]] && { echo "Error: Opus source not found in $repo_root" >&2; exit 1; }

log "Found FFmpeg source: $ffmpeg_root"
log "Found LAME source: $lame_root"
log "Found Opus source: $opus_root"

# Platforms, SDKs and Architectures to build
# Format: platform:sdk:arch:host:extra_cflags:install_subpath
TARGETS=(
  "macos:macosx:arm64:aarch64-apple-darwin:-mmacosx-version-min=$DEPLOYMENT_TARGET:macos-arm64"
  "macos:macosx:x86_64:x86_64-apple-darwin:-mmacosx-version-min=$DEPLOYMENT_TARGET:macos-x86_64"
  "ios:iphoneos:arm64:aarch64-apple-darwin:-miphoneos-version-min=$DEPLOYMENT_TARGET:ios-arm64"
  "ios:iphonesimulator:arm64:aarch64-apple-darwin:-miphonesimulator-version-min=$DEPLOYMENT_TARGET:ios-sim-arm64"
  "ios:iphonesimulator:x86_64:x86_64-apple-darwin:-miphonesimulator-version-min=$DEPLOYMENT_TARGET:ios-sim-x86_64"
)

# Compiler/tool locations
CC_PATH="$(xcrun -find clang)"
CXX_PATH="$(xcrun -find clang++)"
AR_PATH="$(xcrun -find ar)"
RANLIB_PATH="$(xcrun -find ranlib)"
STRIP_PATH="$(xcrun -find strip)"
NM_PATH="$(xcrun -find nm)"

for target in "${TARGETS[@]}"; do
  IFS=':' read -r platform sdk arch host extra_flags subpath <<< "$target"
  log "=========================================================="
  log "Building for $platform | $sdk | $arch ($host)"
  log "=========================================================="
  
  sdk_path="$(xcrun -sdk "$sdk" --show-sdk-path)"
  
  build_dir="$repo_root/build/ffmpeg-apple-$subpath"
  install_root="$repo_root/build/ffmpeg-apple-install-$subpath"
  
  lame_build="$repo_root/build/lame-apple-$subpath"
  lame_install="$lame_build/install"
  
  opus_build="$repo_root/build/opus-apple-$subpath"
  opus_install="$opus_build/install"
  
  if $CLEAN; then
    rm -rf "$build_dir" "$install_root" "$lame_build" "$opus_build"
  fi
  
  # 1. Build LAME
  if [[ ! -f "$lame_install/lib/libmp3lame.a" ]]; then
    log "Configuring LAME for $subpath..."
    mkdir -p "$lame_build"
    cd "$lame_build"
    
    # We pass the sysroot and architecture through CFLAGS/LDFLAGS
    env \
      CC="$CC_PATH" \
      CXX="$CXX_PATH" \
      AR="$AR_PATH" \
      RANLIB="$RANLIB_PATH" \
      CFLAGS="-arch $arch -isysroot $sdk_path $extra_flags -fPIC -Wno-implicit-function-declaration -Wno-implicit-int" \
      LDFLAGS="-arch $arch -isysroot $sdk_path $extra_flags" \
      "$lame_root/configure" \
      --prefix="$lame_install" \
      --host="$host" \
      --disable-shared \
      --enable-static \
      --disable-frontend
      
    log "Building LAME for $subpath..."
    make -j"$JOBS"
    make install
  else
    log "Skipping LAME build: already built at $lame_install"
  fi

  # 2. Build Opus
  if [[ ! -f "$opus_install/lib/libopus.a" ]]; then
    log "Configuring Opus for $subpath..."
    mkdir -p "$opus_build"
    cd "$opus_build"
    
    env \
      CC="$CC_PATH" \
      CXX="$CXX_PATH" \
      AR="$AR_PATH" \
      RANLIB="$RANLIB_PATH" \
      CFLAGS="-arch $arch -isysroot $sdk_path $extra_flags -fPIC" \
      LDFLAGS="-arch $arch -isysroot $sdk_path $extra_flags" \
      "$opus_root/configure" \
      --prefix="$opus_install" \
      --host="$host" \
      --disable-shared \
      --enable-static \
      --disable-extra-programs \
      --disable-doc \
      --disable-maintainer-mode
      
    log "Building Opus for $subpath..."
    make -j"$JOBS"
    make install
  else
    log "Skipping Opus build: already built at $opus_install"
  fi

  # 3. Build FFmpeg
  if [[ ! -f "$install_root/lib/libffmpeg.a" ]]; then
    log "Configuring FFmpeg for $subpath..."
    mkdir -p "$build_dir"
    cd "$build_dir"
    
    # Configure compiler wrapper args
    ff_cc="$CC_PATH -arch $arch"
    ff_cxx="$CXX_PATH -arch $arch"
    
    # Map architectures
    ff_arch="$arch"
    if [[ "$arch" == "arm64" ]]; then
      ff_cpu="armv8-a"
    elif [[ "$arch" == "x86_64" ]]; then
      ff_cpu="x86-64"
    fi
    
    configure_args=(
      --prefix="$install_root"
      --target-os=darwin
      --arch="$ff_arch"
      --cpu="$ff_cpu"
      --cc="$ff_cc"
      --cxx="$ff_cxx"
      --ar="$AR_PATH"
      --nm="$NM_PATH"
      --ranlib="$RANLIB_PATH"
      --strip="$STRIP_PATH"
      --enable-cross-compile
      --sysroot="$sdk_path"
      --extra-cflags="-arch $arch $extra_flags -I$lame_install/include -I$opus_install/include/opus"
      --extra-ldflags="-arch $arch $extra_flags -L$lame_install/lib -L$opus_install/lib"
      --disable-everything
      --disable-autodetect
      --disable-debug
      --disable-doc
      --disable-ffplay
      --disable-ffprobe
      --disable-ffmpeg
      --disable-avdevice
      --disable-programs
      --enable-small
      --disable-gpl
      --enable-pic
      --enable-static
      --disable-shared
      --enable-avfilter
      --enable-filter=abuffer
      --enable-filter=abuffersink
      --enable-filter=aformat
      --enable-filter=anull
      --enable-filter=aresample
      
      --enable-protocol=file,pipe
      --enable-bsf=aac_adtstoasc
      --enable-parser=aac
      --enable-parser=aac_latm
      --enable-parser=flac
      --enable-parser=mpegaudio
      --enable-parser=opus
      --enable-parser=vorbis
      
      --enable-demuxer=aac
      --enable-demuxer=aiff
      --enable-demuxer=caf
      --enable-demuxer=flac
      --enable-demuxer=mov
      --enable-demuxer=mp3
      --enable-demuxer=ogg
      --enable-demuxer=wav
      --enable-demuxer=matroska
      
      --enable-decoder=aac
      --enable-decoder=aac_latm
      --enable-decoder=alac
      --enable-decoder=flac
      --enable-decoder=mp3
      --enable-decoder=mp3float
      --enable-decoder=opus
      --enable-decoder=vorbis
      --enable-decoder=pcm_alaw
      --enable-decoder=pcm_f32be
      --enable-decoder=pcm_f32le
      --enable-decoder=pcm_f64be
      --enable-decoder=pcm_f64le
      --enable-decoder=pcm_mulaw
      --enable-decoder=pcm_s16be
      --enable-decoder=pcm_s16le
      --enable-decoder=pcm_s24be
      --enable-decoder=pcm_s24le
      --enable-decoder=pcm_s32be
      --enable-decoder=pcm_s32le
      --enable-decoder=pcm_u8
      
      # Add Encoders, Muxers, and Libs
      --enable-libmp3lame
      --enable-libopus
      --enable-encoder=aac
      --enable-encoder=libmp3lame
      --enable-encoder=libopus
      --enable-encoder=flac
      --enable-muxer=adts
      --enable-muxer=flac
      --enable-muxer=ipod
      --enable-muxer=mp3
      --enable-muxer=ogg
      --enable-muxer=opus
      --enable-muxer=wav
    )
    
    "$ffmpeg_root/configure" "${configure_args[@]}"
    
    log "Building FFmpeg for $subpath..."
    make -j"$JOBS"
    make install
    
    # 4. Copy static dependencies and merge them
    log "Merging static libraries for $subpath..."
    cp -f "$lame_install/lib/libmp3lame.a" "$install_root/lib/"
    cp -f "$opus_install/lib/libopus.a" "$install_root/lib/"
    
    # Find all static libraries except libffmpeg.a and merge them into a new libffmpeg.a
    rm -f "$install_root/lib/libffmpeg.a"
    libs=$(find "$install_root/lib" -name "*.a" ! -name "libffmpeg.a")
    /usr/bin/libtool -static -o "$install_root/lib/libffmpeg.a" $libs
    
    log "Umbrella static library created for $subpath at $install_root/lib/libffmpeg.a"
  else
    log "Skipping FFmpeg build: already built at $install_root"
  fi
done

# 4. Generate fat binaries for macOS and iOS Simulator
log "Creating Universal/Fat libraries..."

# macOS Fat (universal arm64 + x86_64)
macos_fat_dir="$repo_root/build/macos-universal"
mkdir -p "$macos_fat_dir/lib"
lipo -create \
  "$repo_root/build/ffmpeg-apple-install-macos-arm64/lib/libffmpeg.a" \
  "$repo_root/build/ffmpeg-apple-install-macos-x86_64/lib/libffmpeg.a" \
  -output "$macos_fat_dir/lib/libffmpeg.a"
# Copy headers (take from arm64)
cp -R "$repo_root/build/ffmpeg-apple-install-macos-arm64/include" "$macos_fat_dir/include"

# iOS Simulator Fat (universal arm64 + x86_64)
ios_sim_fat_dir="$repo_root/build/ios-sim-universal"
mkdir -p "$ios_sim_fat_dir/lib"
lipo -create \
  "$repo_root/build/ffmpeg-apple-install-ios-sim-arm64/lib/libffmpeg.a" \
  "$repo_root/build/ffmpeg-apple-install-ios-sim-x86_64/lib/libffmpeg.a" \
  -output "$ios_sim_fat_dir/lib/libffmpeg.a"
# Copy headers
cp -R "$repo_root/build/ffmpeg-apple-install-ios-sim-arm64/include" "$ios_sim_fat_dir/include"

# iOS Device static lib (already arm64)
ios_device_dir="$repo_root/build/ffmpeg-apple-install-ios-arm64"

# 5. Package as XCFramework
log "Packaging XCFramework..."
xcframework_path="$repo_root/darwin/FFmpeg.xcframework"
rm -rf "$xcframework_path"

xcodebuild -create-xcframework \
  -library "$ios_device_dir/lib/libffmpeg.a" -headers "$ios_device_dir/include" \
  -library "$ios_sim_fat_dir/lib/libffmpeg.a" -headers "$ios_sim_fat_dir/include" \
  -library "$macos_fat_dir/lib/libffmpeg.a" -headers "$macos_fat_dir/include" \
  -output "$xcframework_path"

log "=========================================================="
log "SUCCESS: Unified FFmpeg.xcframework created at:"
log "  $xcframework_path"
log "=========================================================="
