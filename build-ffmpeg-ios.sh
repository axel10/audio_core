#!/usr/bin/env bash
set -euo pipefail

DEPLOYMENT_TARGET="11.0"
ARCHS=("arm64" "arm64-sim")
usage() {
  cat <<EOF
Usage: ./build-ffmpeg-ios.sh [--clean] [--jobs N] [--arch "arch1 arch2"]
Options:
  --clean      Remove the build directory before configuring.
  --jobs N     Number of parallel jobs for make. Defaults to CPU count.
  --arch       Target architectures. Options: arm64, arm64-sim, x86_64.
               Defaults to "arm64 arm64-sim".
  -h, --help   Show this help message.
EOF
}
clean=false
jobs=""
while (($#)); do
  case "$1" in
    --clean) clean=true; shift ;;
    --jobs) jobs="$2"; shift 2 ;;
    --arch) IFS=' ' read -r -a ARCHS <<< "$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done
if [[ -z "$jobs" ]]; then
  jobs="$(sysctl -n hw.ncpu || echo 1)"
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
log() {
  printf "[$(date +%H:%M:%S)] %s\n" "$*"
}
[[ -z "$ffmpeg_root" ]] && { echo "Error: FFmpeg source not found in $repo_root" >&2; exit 1; }
for arch in "${ARCHS[@]}"; do
  log "Targeting architecture: $arch"
  
  if [[ "$arch" == "arm64" ]]; then
    sdk="iphoneos"
    ff_arch="arm64"
    cc_arch="arm64"
    ff_cpu="armv8-a"
    extra_flags="-arch arm64 -miphoneos-version-min=$DEPLOYMENT_TARGET"
  elif [[ "$arch" == "arm64-sim" ]]; then
    sdk="iphonesimulator"
    ff_arch="arm64"
    cc_arch="arm64"
    ff_cpu="armv8-a"
    extra_flags="-arch arm64 -miphonesimulator-version-min=$DEPLOYMENT_TARGET"
  elif [[ "$arch" == "x86_64" ]]; then
    sdk="iphonesimulator"
    ff_arch="x86_64"
    cc_arch="x86_64"
    ff_cpu="x86-64"
    extra_flags="-arch x86_64 -miphonesimulator-version-min=$DEPLOYMENT_TARGET"
  else
    echo "Unsupported architecture: $arch" >&2; exit 1
  fi
  sdk_path=$(xcrun -sdk "$sdk" --show-sdk-path)
  cc="xcrun -sdk $sdk clang -arch $cc_arch"
  cxx="xcrun -sdk $sdk clang++ -arch $cc_arch"
  ar="xcrun -sdk $sdk ar"
  nm="xcrun -sdk $sdk nm"
  ranlib="xcrun -sdk $sdk ranlib"
  strip="xcrun -sdk $sdk strip"
  build_root="$repo_root/build/ffmpeg-ios-$arch"
  install_root="$repo_root/ios/ffmpeg_lib/$arch"
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
  "$ffmpeg_root/configure" "${configure_args[@]}"
  make -j"$jobs"
  make install

  # 合并所有静态库为一个 libffmpeg.a
  log "Merging all static libraries into libffmpeg.a for $arch..."
  libs=$(find "$install_root/lib" -name "*.a" ! -name "libffmpeg.a")
  libtool -static -o "$install_root/lib/libffmpeg.a" $libs

  log "Build finished for $arch. Output: $install_root"
  log "Single static library created at: $install_root/lib/libffmpeg.a"
done

log "Generating XCFramework..."

xcframework_path="$repo_root/ios/FFmpeg.xcframework"
rm -rf "$xcframework_path"

# 定义真机路径
ios_lib="$repo_root/ios/ffmpeg_lib/arm64/lib/libffmpeg.a"
ios_headers="$repo_root/ios/ffmpeg_lib/arm64/include"

# 处理模拟器库 (可能包含 arm64-sim 和 x86_64)
sim_libs=()
[[ -f "$repo_root/ios/ffmpeg_lib/arm64-sim/lib/libffmpeg.a" ]] && sim_libs+=("$repo_root/ios/ffmpeg_lib/arm64-sim/lib/libffmpeg.a")
[[ -f "$repo_root/ios/ffmpeg_lib/x86_64/lib/libffmpeg.a" ]] && sim_libs+=("$repo_root/ios/ffmpeg_lib/x86_64/lib/libffmpeg.a")

sim_final_lib=""
sim_headers=""

if [ ${#sim_libs[@]} -gt 0 ]; then
    sim_out_dir="$repo_root/build/simulator_fat"
    mkdir -p "$sim_out_dir"
    sim_final_lib="$sim_out_dir/libffmpeg.a"
    
    # 获取模拟器头文件路径 (取第一个可用的模拟器架构)
    sim_headers="$(dirname "$(dirname "${sim_libs[0]}")")/include"

    if [ ${#sim_libs[@]} -eq 1 ]; then
        cp "${sim_libs[0]}" "$sim_final_lib"
    else
        log "Merging simulator architectures (${#sim_libs[@]}) using lipo..."
        lipo -create "${sim_libs[@]}" -output "$sim_final_lib"
    fi
fi

# 构建命令行
cmd=(xcodebuild -create-xcframework)
if [[ -f "$ios_lib" ]]; then
    cmd+=(-library "$ios_lib" -headers "$ios_headers")
fi
if [[ -n "$sim_final_lib" && -f "$sim_final_lib" ]]; then
    cmd+=(-library "$sim_final_lib" -headers "$sim_headers")
fi
cmd+=(-output "$xcframework_path")

# 执行构建
if [[ ${#cmd[@]} -gt 3 ]]; then
    log "Running: ${cmd[*]}"
    "${cmd[@]}"
    log "SUCCESS: XCFramework created at: $xcframework_path"
else
    log "ERROR: Not enough libraries built to create XCFramework. (Expected at least one device or simulator build)"
    exit 1
fi

log "All iOS builds finished. Output directory: $repo_root/ios"
