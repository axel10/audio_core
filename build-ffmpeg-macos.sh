#!/usr/bin/env bash
set -euo pipefail

DEPLOYMENT_TARGET="11.0"
ARCHS=("arm64" "x86_64")

usage() {
  cat <<EOF
Usage: ./build-ffmpeg-macos.sh [--clean] [--jobs N] [--arch "arch1 arch2"]

Options:
  --clean      Remove the build directory before configuring.
  --jobs N     Number of parallel jobs for make. Defaults to CPU count.
  --arch       Target architectures. Options: arm64, x86_64.
               Defaults to "arm64 x86_64".
  -h, --help   Show this help message.
EOF
}

clean=false
jobs=""

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
    --arch)
      IFS=' ' read -r -a ARCHS <<< "$2"
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
  if command -v sysctl >/dev/null 2>&1; then
    jobs="$(sysctl -n hw.ncpu)"
  else
    jobs=1
  fi
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$script_dir"

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
ffmpeg_component_libs=(
  libavcodec.a
  libavformat.a
  libavutil.a
  libswresample.a
  libswscale.a
)

log() {
  printf "[$(date +%H:%M:%S)] %s\n" "$*"
}

[[ -z "$ffmpeg_root" ]] && { echo "Error: FFmpeg source not found in $repo_root" >&2; exit 1; }

for arch in "${ARCHS[@]}"; do
  log "Targeting architecture: $arch"

  if [[ "$arch" == "arm64" ]]; then
    sdk="macosx"
    ff_arch="arm64"
    ff_cpu="armv8-a"
    extra_flags="-mmacosx-version-min=$DEPLOYMENT_TARGET"
    install_arch="arm64"
  elif [[ "$arch" == "x86_64" ]]; then
    sdk="macosx"
    ff_arch="x86_64"
    ff_cpu="x86-64"
    extra_flags="-mmacosx-version-min=$DEPLOYMENT_TARGET"
    install_arch="x86_64"
  else
    echo "Unsupported architecture: $arch" >&2
    exit 1
  fi

  sdk_path=$(xcrun -sdk "$sdk" --show-sdk-path)
  cc="xcrun -sdk $sdk clang -arch $arch"
  cxx="xcrun -sdk $sdk clang++ -arch $arch"
  ar="xcrun -sdk $sdk ar"
  nm="xcrun -sdk $sdk nm"
  ranlib="xcrun -sdk $sdk ranlib"
  strip="xcrun -sdk $sdk strip"
  build_root="$repo_root/build/ffmpeg-macos-$arch"
  install_root="$repo_root/macos/ffmpeg_lib/$install_arch"

  if ! $clean && [[ -f "$install_root/lib/libffmpeg.a" ]]; then
    log "Skipping $arch because $install_root already looks built"
    continue
  fi

  if $clean; then
    rm -rf "$build_root" "$install_root"
  fi

  log "Configuring FFmpeg for $arch..."
  mkdir -p "$build_root"
  cd "$build_root"
  configure_args=(
    --prefix="$install_root"
    --target-os=darwin
    --arch="$ff_arch"
    --cpu="$ff_cpu"
    --cc="$cc"
    --cxx="$cxx"
    --ar="$ar"
    --nm="$nm"
    --ranlib="$ranlib"
    --strip="$strip"
    --enable-cross-compile
    --sysroot="$sdk_path"
    --disable-everything
    --disable-autodetect
    --disable-debug
    --disable-doc
    --disable-ffplay
    --disable-ffprobe
    --disable-ffmpeg
    --disable-avdevice
    --disable-filters
    --disable-muxers
    --disable-programs
    --enable-small
    --disable-gpl
    --enable-pic
    --enable-static
    --disable-shared

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
  )

  log "Starting FFmpeg configure for macOS $arch"
  "$ffmpeg_root/configure" "${configure_args[@]}"

  log "Starting make -j${jobs}"
  make -j"$jobs"

  log "Starting make install"
  make install

  log "Removing any stale shared libraries for $arch..."
  find "$install_root/lib" -maxdepth 1 -type f -name '*.dylib' -delete

  log "Creating umbrella static library for $arch..."
  ffmpeg_component_paths=()
  for lib in "${ffmpeg_component_libs[@]}"; do
    if [[ ! -f "$install_root/lib/$lib" ]]; then
      echo "Error: expected static library not found: $install_root/lib/$lib" >&2
      exit 1
    fi
    ffmpeg_component_paths+=("$install_root/lib/$lib")
  done
  rm -f "$install_root/lib/libffmpeg.a"
  /usr/bin/libtool -static -o "$install_root/lib/libffmpeg.a" "${ffmpeg_component_paths[@]}"

  log "Static libraries installed for $arch at: $install_root"
  log "Umbrella library created at: $install_root/lib/libffmpeg.a"

  log "Build finished for $arch. Installation at: $install_root"
done

log "All macOS builds finished."
