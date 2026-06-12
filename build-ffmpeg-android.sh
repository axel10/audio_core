#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: ./build-ffmpeg-android.sh [--clean] [--jobs N] [--sdk PATH] [--api LEVEL] [--abi ABI]

Options:
  --clean      Remove the build directory before configuring.
  --jobs N     Number of parallel jobs for make. Defaults to the CPU count.
  --sdk PATH   Path to the Android SDK. Defaults to ~/Android/Sdk.
  --api LEVEL  Android API level. Defaults to 21.
  --abi ABI    Target ABI. Can be specified multiple times. Defaults to arm64-v8a and armeabi-v7a.
  -h, --help   Show this help message.
EOF
}

clean=false
jobs=""
if [[ "$(uname)" == "Darwin" ]]; then
  sdk_root="/Users/axel10/Library/Android/sdk"
else
  sdk_root="$HOME/Android/Sdk"
fi
api_level=21
abis=()

while (($#)); do
  case "$1" in
    --clean)
      clean=true
      shift
      ;;
    --jobs)
      jobs="$2"
      shift 2
      ;;
    --sdk)
      sdk_root="$2"
      shift 2
      ;;
    --api)
      api_level="$2"
      shift 2
      ;;
    --abi)
      abis+=("$2")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ ${#abis[@]} -eq 0 ]]; then
  abis=("arm64-v8a" "armeabi-v7a")
fi

if [[ -z "$jobs" ]]; then
  if command -v nproc >/dev/null 2>&1; then
    jobs="$(nproc)"
  elif command -v sysctl >/dev/null 2>&1; then
    jobs="$(sysctl -n hw.ncpu)"
  else
    jobs=1
  fi
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$script_dir"
ffmpeg_root="$repo_root/ffmpeg-8.1"
if [[ ! -d "$ffmpeg_root" && -d "$repo_root/ffmpeg" ]]; then
  ffmpeg_root="$repo_root/ffmpeg"
fi
lame_root="$repo_root/lame-3.100"

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

opus_root="$(find_source_dir opus || true)"

log() {
  printf "[$(date +%H:%M:%S)] %s\n" "$*"
}

extract_builtin_audio_decoders() {
  local allcodecs_file="$1/libavcodec/allcodecs.c"

  if [[ ! -f "$allcodecs_file" ]]; then
    echo "Error: allcodecs.c not found at $allcodecs_file" >&2
    exit 1
  fi

  awk '
    /\/\* audio codecs \*\// { in_audio = 1; next }
    /\/\* subtitles \*\// { in_audio = 0 }
    in_audio && /extern const FFCodec ff_.*_decoder;/ {
      name = $4
      sub(/^ff_/, "", name)
      sub(/_decoder;$/, "", name)
      print name
    }
  ' "$allcodecs_file"
}

# Find NDK
ndk_root="$sdk_root/ndk"
if [[ ! -d "$ndk_root" ]]; then
  # Try ndk-bundle
  if [[ -d "$sdk_root/ndk-bundle" ]]; then
    ndk_root="$sdk_root/ndk-bundle"
  else
    echo "Error: Android NDK not found in $sdk_root/ndk or $sdk_root/ndk-bundle" >&2
    exit 1
  fi
fi

# Get the latest version if multiple exist (under ndk/ version folders)
if ls "$ndk_root" | grep -qE '^[0-9.]+'; then
  latest_ndk=$(ls -d "$ndk_root"/* 2>/dev/null | sort -V | tail -n 1)
  ndk_root="$latest_ndk"
fi

log "Using NDK: $ndk_root"

if [[ "$(uname)" == "Darwin" ]]; then
  host_os="darwin-x86_64"
else
  host_os="linux-x86_64"
fi
toolchain_bin="$ndk_root/toolchains/llvm/prebuilt/$host_os/bin"

if [[ ! -d "$toolchain_bin" ]]; then
  echo "Error: Toolchain bin directory not found at $toolchain_bin" >&2
  exit 1
fi

mapfile -t builtin_audio_decoders < <(extract_builtin_audio_decoders "$ffmpeg_root")

if [[ ${#builtin_audio_decoders[@]} -eq 0 ]]; then
  echo "Error: failed to discover built-in audio decoders from $ffmpeg_root" >&2
  exit 1
fi

log "Discovered ${#builtin_audio_decoders[@]} built-in audio decoders"

for abi in "${abis[@]}"; do
  build_root="$repo_root/build/ffmpeg-android-$abi"
  install_root="$repo_root/android/ffmpeg_lib/$abi"
  jni_libs_root="$repo_root/android/src/main/jniLibs/$abi"

  log "Building for ABI: $abi"

  case "$abi" in
  arm64-v8a)
    arch="aarch64"
    cpu="armv8-a"
    tool_prefix="aarch64-linux-android"
    ;;
  armeabi-v7a)
    arch="arm"
    cpu="armv7-a"
    tool_prefix="armv7a-linux-androideabi"
    ;;
  x86_64)
    arch="x86_64"
    cpu="x86-64"
    tool_prefix="x86_64-linux-android"
    ;;
  x86)
    arch="x86"
    cpu="i686"
    tool_prefix="i686-linux-android"
    ;;
  *)
    echo "Unsupported ABI: $abi" >&2
    exit 1
    ;;
esac

cc="${toolchain_bin}/${tool_prefix}${api_level}-clang"
cxx="${toolchain_bin}/${tool_prefix}${api_level}-clang++"
ar="${toolchain_bin}/llvm-ar"
nm="${toolchain_bin}/llvm-nm"
ranlib="${toolchain_bin}/llvm-ranlib"
strip="${toolchain_bin}/llvm-strip"

if [[ ! -f "$cc" ]]; then
  echo "Error: Compiler not found at $cc" >&2
  exit 1
fi

if $clean && [[ -e "$build_root" ]]; then
  rm -rf "$build_root"
fi

if $clean && [[ -e "$install_root" ]]; then
  rm -rf "$install_root"
fi

if $clean && [[ -e "$jni_libs_root" ]]; then
  rm -rf "$jni_libs_root"
fi

# Build LAME
lame_build_root="$repo_root/build/lame-android-$abi"
lame_install_root="$lame_build_root/install"

if [[ ! -d "$lame_root" ]]; then
  echo "Error: LAME source not found at $lame_root" >&2
  exit 1
fi

if [[ -z "$opus_root" ]]; then
  echo "Error: Opus source not found. Expected a directory like $repo_root/opus-1.5.2" >&2
  exit 1
fi

log "Using Opus source: $opus_root"

if $clean && [[ -e "$lame_build_root" ]]; then
  rm -rf "$lame_build_root"
fi

mkdir -p "$lame_build_root"
cd "$lame_build_root"

log "Configuring LAME for $abi"
# Adjust host for LAME
lame_host="$tool_prefix"
if [[ "$abi" == "armeabi-v7a" ]]; then
  lame_host="arm-linux-androideabi"
fi

# LAME configure needs to be run from its source or with a path
# But it's better to run it in the build dir
env \
  CC="$cc" \
  AR="$ar" \
  RANLIB="$ranlib" \
  CFLAGS="-fPIC" \
  "$lame_root/configure" \
  --prefix="$lame_install_root" \
  --host="$lame_host" \
  --disable-shared \
  --enable-static \
  --disable-frontend

log "Building LAME for $abi"
make -j"$jobs"
make install

# Build Opus
opus_build_root="$repo_root/build/opus-android-$abi"
opus_install_root="$opus_build_root/install"

if $clean && [[ -e "$opus_build_root" ]]; then
  rm -rf "$opus_build_root"
fi

mkdir -p "$opus_build_root"
cd "$opus_build_root"

log "Configuring Opus for $abi"
# Opus configure host
opus_host="$tool_prefix"
if [[ "$abi" == "armeabi-v7a" ]]; then
  opus_host="arm-linux-androideabi"
fi

env \
  CC="$cc" \
  AR="$ar" \
  RANLIB="$ranlib" \
  CFLAGS="-fPIC" \
  "$opus_root/configure" \
  --prefix="$opus_install_root" \
  --host="$opus_host" \
  --disable-shared \
  --enable-static \
  --disable-extra-programs \
  --disable-doc \
  --disable-maintainer-mode

log "Building Opus for $abi"
make -j"$jobs"
make install

mkdir -p "$build_root" "$install_root"
cd "$build_root"

ffmpeg_cc="$cc"
ffmpeg_cxx="$cxx"

if command -v ccache >/dev/null 2>&1; then
  export CCACHE_DIR="${CCACHE_DIR:-$repo_root/.cache/ffmpeg-android/ccache}"
  mkdir -p "$CCACHE_DIR"
  ffmpeg_cc="ccache $cc"
  ffmpeg_cxx="ccache $cxx"
  log "Using ccache"
fi

configure_args=(
  --prefix="$install_root"
  --target-os=android
  --arch="$arch"
  --cpu="$cpu"
  --enable-cross-compile
  --cc="$ffmpeg_cc"
  --cxx="$ffmpeg_cxx"
  --ar="$ar"
  --nm="$nm"
  --ranlib="$ranlib"
  --strip="$strip"
  --sysroot="$ndk_root/toolchains/llvm/prebuilt/$host_os/sysroot"
  --extra-cflags="-fPIC -I$lame_install_root/include -I$opus_install_root/include/opus"
  --extra-ldflags="-L$lame_install_root/lib -L$opus_install_root/lib"

  --disable-everything
  --disable-autodetect
  --disable-debug
  --disable-doc
  --disable-programs
  --disable-ffmpeg
  --disable-ffplay
  --disable-ffprobe
  --disable-avdevice
  --disable-network
  --disable-filters
  --enable-filter=aformat
  --enable-filter=anull
  --enable-filter=aresample
  --enable-small
  --enable-pic
  --enable-shared
  --disable-static
  --disable-asm
  --disable-x86asm
  --enable-avcodec
  --enable-avformat
  --enable-avutil
  --enable-swresample
  --enable-swscale
  --enable-libmp3lame
  --enable-libopus

  --enable-protocol=file
  --enable-protocol=pipe
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
  --enable-demuxer=matroska
  --enable-demuxer=mov
  --enable-demuxer=mp3
  --enable-demuxer=ogg
  --enable-demuxer=wav
  --enable-muxer=adts
  --enable-muxer=flac
  --enable-muxer=ipod
  --enable-muxer=mp3
  --enable-muxer=ogg
  --enable-muxer=opus
  --enable-muxer=wav
  --enable-encoder=libopus
  --enable-encoder=libmp3lame
  --enable-encoder=flac
)

for decoder in "${builtin_audio_decoders[@]}"; do
  configure_args+=("--enable-decoder=$decoder")
done

log "Starting FFmpeg configure for Android $abi (API $api_level)"

# Ensure pkg-config can find our cross-compiled libraries
export PKG_CONFIG_PATH="$opus_install_root/lib/pkgconfig:$lame_install_root/lib/pkgconfig"

"$ffmpeg_root/configure" --pkg-config-flags="--static" "${configure_args[@]}"

log "Starting make -j${jobs}"
make -j"$jobs"

log "Starting make install"
make install

mkdir -p "$jni_libs_root"
cp -f "$install_root/lib/"*.so "$jni_libs_root/"

  log "Build finished for $abi. Installation at: $install_root"
done

log "All builds finished."
