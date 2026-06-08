#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: ./build-ffmpeg-linux.sh [--clean] [--jobs N] [--prefix PATH]

Options:
  --clean        Remove previous build and install directories before building.
  --jobs N       Number of parallel jobs for make. Defaults to CPU count.
  --prefix PATH  Install directory. Defaults to build/ffmpeg-linux/install.
  -h, --help     Show this help message.
EOF
}

clean=false
jobs=""
prefix=""

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
    --prefix)
      prefix="$2"
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

if [[ -z "$jobs" ]]; then
  if command -v nproc >/dev/null 2>&1; then
    jobs="$(nproc)"
  elif command -v sysctl >/dev/null 2>&1; then
    jobs="$(sysctl -n hw.ncpu)"
  else
    jobs=1
  fi
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$script_dir"
build_root="$repo_root/build/ffmpeg-linux"
install_root="${prefix:-$build_root/install}"

log() {
  printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"
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
      \( -exec test -x '{}/configure' \; -o -exec test -f '{}/CMakeLists.txt' \; \) \
      -print | sort
  )

  return 1
}

require_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: required command not found: $cmd" >&2
    exit 1
  fi
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

require_command make
require_command pkg-config
require_command cc
require_command ar
require_command ranlib
require_command ln

ffmpeg_root="$(find_source_dir FFmpeg || find_source_dir ffmpeg || true)"
lame_root="$(find_source_dir lame || true)"
opus_root="$(find_source_dir opus || true)"
fdk_aac_root="$(find_source_dir fdk-aac || find_source_dir fdk_aac || true)"

[[ -z "$ffmpeg_root" ]] && { echo "Error: FFmpeg source not found in $repo_root" >&2; exit 1; }
[[ -z "$lame_root" ]] && { echo "Error: LAME source not found in $repo_root" >&2; exit 1; }
[[ -z "$opus_root" ]] && { echo "Error: Opus source not found in $repo_root" >&2; exit 1; }
[[ -z "$fdk_aac_root" ]] && { echo "Error: fdk-aac source not found in $repo_root" >&2; exit 1; }

lame_build_root="$build_root/lame"
opus_build_root="$build_root/opus"
fdk_build_root="$build_root/fdk-aac"
ffmpeg_build_root="$build_root/ffmpeg"

lame_install_root="$lame_build_root/install"
opus_install_root="$opus_build_root/install"
fdk_install_root="$fdk_build_root/install"

if $clean; then
  rm -rf "$lame_build_root" "$opus_build_root" "$fdk_build_root" "$ffmpeg_build_root" "$install_root"
fi

mkdir -p "$build_root"

log "Using FFmpeg source: $ffmpeg_root"
log "Using LAME source: $lame_root"
log "Using Opus source: $opus_root"
log "Using fdk-aac source: $fdk_aac_root"

export CFLAGS="${CFLAGS:-} -fPIC"
export CXXFLAGS="${CXXFLAGS:-} -fPIC"

log "Building libmp3lame..."
mkdir -p "$lame_build_root"
pushd "$lame_build_root" >/dev/null
"$lame_root/configure" \
  --prefix="$lame_install_root" \
  --disable-shared \
  --enable-static \
  --disable-frontend
make -j"$jobs"
make install
popd >/dev/null

log "Building libopus..."
mkdir -p "$opus_build_root"
pushd "$opus_build_root" >/dev/null
"$opus_root/configure" \
  --prefix="$opus_install_root" \
  --disable-shared \
  --enable-static \
  --disable-maintainer-mode \
  --disable-extra-programs \
  --disable-doc
make -j"$jobs"
make install
popd >/dev/null

log "Building libfdk-aac..."
mkdir -p "$fdk_build_root"
pushd "$fdk_build_root" >/dev/null
cmake -S "$fdk_aac_root" -B "$fdk_build_root" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$fdk_install_root" \
  -DBUILD_SHARED_LIBS=OFF \
  -DBUILD_PROGRAMS=OFF \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON
cmake --build "$fdk_build_root" --parallel "$jobs"
cmake --install "$fdk_build_root"
popd >/dev/null

mapfile -t builtin_audio_decoders < <(extract_builtin_audio_decoders "$ffmpeg_root")

if [[ ${#builtin_audio_decoders[@]} -eq 0 ]]; then
  echo "Error: failed to discover built-in audio decoders from $ffmpeg_root" >&2
  exit 1
fi

log "Discovered ${#builtin_audio_decoders[@]} built-in audio decoders"

mkdir -p "$ffmpeg_build_root" "$install_root"
pushd "$ffmpeg_build_root" >/dev/null

export PKG_CONFIG_PATH="$fdk_install_root/lib/pkgconfig:$lame_install_root/lib/pkgconfig:$opus_install_root/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

configure_args=(
  --prefix="$install_root"
  --pkg-config-flags="--static"
  --extra-cflags="-I$fdk_install_root/include -I$lame_install_root/include -I$opus_install_root/include -I$opus_install_root/include/opus"
  --extra-ldflags="-L$fdk_install_root/lib -L$lame_install_root/lib -L$opus_install_root/lib"

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
  --enable-small
  --enable-pic
  --enable-static
  --disable-shared
  --enable-nonfree
  --enable-swresample
  --enable-swscale
  --enable-avcodec
  --enable-avformat
  --enable-avfilter
  --enable-avutil
  --enable-libfdk-aac
  --enable-libmp3lame
  --enable-libopus

  --enable-protocol=file
  --enable-protocol=pipe

  --enable-filter=aformat
  --enable-filter=anull
  --enable-filter=aresample

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

  --enable-encoder=libfdk_aac
  --enable-encoder=flac
  --enable-encoder=libopus
  --enable-encoder=libmp3lame
)

for decoder in "${builtin_audio_decoders[@]}"; do
  configure_args+=("--enable-decoder=$decoder")
done

log "Configuring FFmpeg..."
"$ffmpeg_root/configure" "${configure_args[@]}"

log "Building FFmpeg static libraries..."
make -j"$jobs"
make install
popd >/dev/null

log "Linking merged shared library..."
component_static_libs=(
  "$install_root/lib/libavutil.a"
  "$install_root/lib/libswresample.a"
  "$install_root/lib/libswscale.a"
  "$install_root/lib/libavcodec.a"
  "$install_root/lib/libavformat.a"
  "$install_root/lib/libavfilter.a"
)

for lib in "${component_static_libs[@]}"; do
  if [[ ! -f "$lib" ]]; then
    echo "Error: expected FFmpeg static library not found: $lib" >&2
    exit 1
  fi
done

IFS=' ' read -r -a pkg_link_flags <<< "$(
  PKG_CONFIG_PATH="$install_root/lib/pkgconfig:$PKG_CONFIG_PATH" \
    pkg-config --static --libs libavutil libswresample libswscale libavcodec libavformat libavfilter
)"

rm -f "$install_root/lib"/libffmpeg.so "$install_root/lib"/libavcodec.so "$install_root/lib"/libavformat.so \
  "$install_root/lib"/libavutil.so "$install_root/lib"/libswresample.so "$install_root/lib"/libswscale.so \
  "$install_root/lib"/libavfilter.so

cc -shared \
  -Wl,-soname,libffmpeg.so \
  -o "$install_root/lib/libffmpeg.so" \
  -Wl,--whole-archive \
  "${component_static_libs[@]}" \
  -Wl,--no-whole-archive \
  "${pkg_link_flags[@]}"

for alias in libavcodec.so libavformat.so libavutil.so libswresample.so libswscale.so libavfilter.so; do
  ln -sf libffmpeg.so "$install_root/lib/$alias"
done

log "Build finished."
log "Merged dynamic library: $install_root/lib/libffmpeg.so"
log "Compatibility symlinks: $install_root/lib/libavcodec.so, libavformat.so, libavutil.so, libswresample.so, libswscale.so, libavfilter.so"
