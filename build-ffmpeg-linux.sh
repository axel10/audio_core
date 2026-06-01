#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./build-ffmpeg-linux.sh [--clean] [--jobs N]

Options:
  --clean      Remove the build directory before configuring.
  --jobs N     Number of parallel jobs for make. Defaults to the CPU count.
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
      if (($# < 2)); then
        echo "Missing value for --jobs" >&2
        exit 1
      fi
      jobs="$2"
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

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$script_dir"

if [ "${INSIDE_DOCKER:-}" != "true" ]; then
  # Detect docker command and permissions
  if command -v docker >/dev/null 2>&1; then
    if docker ps >/dev/null 2>&1; then
      DOCKER_CMD="docker"
    elif command -v sudo >/dev/null 2>&1; then
      DOCKER_CMD="sudo docker"
    else
      DOCKER_CMD="docker"
    fi
  else
    DOCKER_CMD=""
  fi

  if [ -n "$DOCKER_CMD" ]; then
    echo "Running build inside Ubuntu 22.04 Docker container using $DOCKER_CMD..."
    $DOCKER_CMD run --rm \
      -v "$repo_root":/workspace \
      -w /workspace \
      -e INSIDE_DOCKER=true \
      -e HOST_UID="$(id -u)" \
      -e HOST_GID="$(id -g)" \
      ubuntu:22.04 bash -c "
        apt-get update && \
        apt-get install -y sudo build-essential nasm pkg-config curl git libopus-dev libmp3lame-dev libfdk-aac-dev && \
        ./download_sources.sh && \
        ./build-ffmpeg-linux.sh $* && \
        chown -R \${HOST_UID}:\${HOST_GID} /workspace
      "
    exit 0
  else
    echo "Docker not found or no permissions to run Docker, building natively on host..."
  fi
fi
ffmpeg_root="$repo_root/ffmpeg-8.1"
build_root="$repo_root/build/ffmpeg-linux"
install_root="$build_root/install"

log() {
  printf '[%(%H:%M:%S)T] %s\n' -1 "$*"
}

need_tool() {
  local tool="$1"
  command -v "$tool" >/dev/null 2>&1 || {
    echo "Missing required tool: $tool" >&2
    exit 1
  }
}

need_pkg_config_pkg() {
  local pkg="$1"
  if ! pkg-config --exists "$pkg"; then
    echo "Missing pkg-config package: $pkg" >&2
    exit 1
  fi
}

for path in "$ffmpeg_root" "$ffmpeg_root/configure"; do
  if [[ ! -e "$path" ]]; then
    echo "Missing required file or directory: $path" >&2
    exit 1
  fi
done

# Detect and install missing dependencies
missing_packages=()

check_tool() {
  local tool="$1"
  local pkg="$2"
  if ! command -v "$tool" >/dev/null 2>&1; then
    missing_packages+=("$pkg")
  fi
}

check_tool gcc gcc
check_tool g++ g++
check_tool make make
check_tool nasm nasm
check_tool perl perl
check_tool pkg-config pkg-config

if command -v pkg-config >/dev/null 2>&1; then
  if ! pkg-config --exists opus; then
    missing_packages+=("libopus-dev")
  fi
  if [[ ! -f "/usr/include/lame/lame.h" ]]; then
    missing_packages+=("libmp3lame-dev")
  fi
  if ! pkg-config --exists fdk-aac; then
    missing_packages+=("libfdk-aac-dev")
  fi
else
  missing_packages+=("libopus-dev" "libmp3lame-dev" "libfdk-aac-dev")
fi

if [[ ${#missing_packages[@]} -gt 0 ]]; then
  log "Missing dependencies: ${missing_packages[*]}"
  if command -v apt-get >/dev/null 2>&1; then
    log "Attempting to install missing dependencies using apt-get (sudo password may be required)..."
    sudo apt-get update
    sudo apt-get install -y "${missing_packages[@]}"
  else
    echo "Warning: The following packages are missing and could not be installed automatically (unsupported package manager):" >&2
    echo "  ${missing_packages[*]}" >&2
    echo "Please install them manually using your system package manager." >&2
  fi
fi

need_tool gcc
need_tool g++
need_tool make
need_tool nasm
need_tool perl
need_tool pkg-config

if command -v ccache >/dev/null 2>&1; then
  export CCACHE_DIR="${CCACHE_DIR:-$repo_root/.cache/ffmpeg-linux/ccache}"
  export CCACHE_BASEDIR="$repo_root"
  export CCACHE_NOHASHDIR=1
  export CCACHE_COMPILERCHECK=content
  mkdir -p "$CCACHE_DIR"
  log "Using ccache: $(command -v ccache)"
fi

need_pkg_config_pkg opus
if [[ ! -f "/usr/include/lame/lame.h" ]]; then
  echo "Missing dependency: libmp3lame-dev (header lame/lame.h not found)" >&2
  exit 1
fi
need_pkg_config_pkg fdk-aac

if $clean && [[ -e "$build_root" ]]; then
  rm -rf "$build_root"
elif [[ -f "$build_root/Makefile" ]]; then
  # If we are inside Docker, Makefile source path should contain /workspace.
  # If we are on the host, Makefile source path should NOT contain /workspace.
  has_workspace=false
  if grep -q "include /workspace/" "$build_root/Makefile"; then
    has_workspace=true
  fi
  
  if [ "${INSIDE_DOCKER:-}" = "true" ] && ! $has_workspace; then
    log "Detected stale host paths in build directory inside Docker. Cleaning..."
    rm -rf "$build_root"
  elif [ "${INSIDE_DOCKER:-}" != "true" ] && $has_workspace; then
    log "Detected stale Docker paths in build directory on host. Cleaning..."
    rm -rf "$build_root"
  fi
fi

mkdir -p "$build_root" "$install_root"
cd "$build_root"

if [[ -z "$jobs" ]]; then
  if command -v nproc >/dev/null 2>&1; then
    jobs="$(nproc)"
  else
    jobs=1
  fi
fi

configure_args=(
  --prefix="$install_root"
  --enable-shared
  --disable-static
  --disable-everything
  --disable-autodetect
  --disable-debug
  --disable-doc
  --disable-ffmpeg
  --disable-ffprobe
  --disable-ffplay
  --disable-avdevice
  --disable-filters
  --enable-filter=aresample
  --enable-small
  --enable-gpl
  --enable-nonfree
  --enable-libfdk-aac
  --enable-protocol=file
  --enable-protocol=pipe
  --enable-parser=aac
  --enable-parser=aac_latm
  --enable-parser=flac
  --enable-parser=mpegaudio
  --enable-parser=opus
  --enable-bsf=aac_adtstoasc
  --enable-decoder=aac
  --enable-decoder=aac_latm
  --enable-decoder=flac
  --enable-decoder=mjpeg
  --enable-decoder=mp3
  --enable-decoder=mp3float
  --enable-decoder=opus
  --enable-decoder=pcm_alaw
  --enable-decoder=pcm_f32le
  --enable-decoder=pcm_f64le
  --enable-decoder=pcm_mulaw
  --enable-decoder=pcm_s16le
  --enable-decoder=pcm_s24le
  --enable-decoder=pcm_s32le
  --enable-decoder=pcm_u8
  --enable-encoder=aac
  --enable-encoder=flac
  --enable-encoder=mjpeg
  --enable-encoder=libmp3lame
  --enable-encoder=libopus
  --enable-encoder=libfdk_aac
  --enable-encoder=pcm_s16le
  --enable-encoder=pcm_s24le
  --enable-encoder=pcm_s32le
  --enable-libopus
  --enable-libmp3lame
  --enable-demuxer=aac
  --enable-demuxer=flac
  --enable-demuxer=mp3
  --enable-demuxer=mov
  --enable-demuxer=ffmetadata
  --enable-demuxer=ogg
  --enable-demuxer=wav
  --enable-demuxer=matroska
  --enable-muxer=adts
  --enable-muxer=flac
  --enable-muxer=ipod
  --enable-muxer=matroska
  --enable-muxer=mov
  --enable-muxer=mp3
  --enable-muxer=ogg
  --enable-muxer=opus
  --enable-muxer=wav
)

if command -v ccache >/dev/null 2>&1; then
  configure_args=(
    --cc="ccache gcc"
    --cxx="ccache g++"
    --dep-cc="ccache gcc"
    "${configure_args[@]}"
  )
fi

log "Starting FFmpeg configure"
"$ffmpeg_root/configure" "${configure_args[@]}"

log "Starting make -j${jobs}"
make -j"$jobs"

log "Starting make install"
make install

copy_runtime_shared_libs() {
  local lib_dir="$1"
  local needed_libs=()
  local lib_path dep target_path resolved_source resolved_target

  copy_with_symlinks() {
    local source_path="$1"
    local destination_path="$2"
    local source_dir source_name

    source_dir="$(cd -- "$(dirname -- "$source_path")" && pwd)"
    source_name="$(basename -- "$source_path")"

    if [[ -L "$source_path" ]]; then
      local link_target link_target_path
      link_target="$(readlink "$source_path")"
      mkdir -p "$(dirname -- "$destination_path")"
      ln -sfn "$link_target" "$destination_path"

      if [[ "$link_target" = /* ]]; then
        link_target_path="$link_target"
      else
        link_target_path="$source_dir/$link_target"
      fi

      if [[ -e "$link_target_path" ]]; then
        copy_with_symlinks "$link_target_path" "$(dirname -- "$destination_path")/$(basename -- "$link_target_path")"
      fi
    else
      cp -a "$source_path" "$destination_path"
    fi
  }

  while IFS= read -r -d '' lib_path; do
    while IFS= read -r dep; do
      case "$dep" in
        linux-vdso.so.*|ld-linux*.so.*|libc.so.*|libm.so.*|libgcc_s.so.*|libpthread.so.*|librt.so.*|libdl.so.*|libstdc++.so.*)
          continue
          ;;
      esac

      target_path="$lib_dir/$dep"
      if [[ -e "$target_path" ]]; then
        continue
      fi

      if ldconfig -p >/dev/null 2>&1; then
        resolved_source="$(ldconfig -p | awk -v name="$dep" '$1 == name { print $NF; exit }')"
        if [[ -n "$resolved_source" && -f "$resolved_source" ]]; then
          resolved_target="$(readlink -f "$resolved_source" 2>/dev/null || true)"
          copy_with_symlinks "$resolved_source" "$target_path"
          if [[ -n "$resolved_target" && -f "$resolved_target" && "$resolved_target" != "$resolved_source" ]]; then
            copy_with_symlinks "$resolved_target" "$lib_dir/$(basename -- "$resolved_target")"
          fi
          log "Copied runtime dependency: $dep -> $target_path"
          needed_libs+=("$dep")
          continue
        fi
      fi

      # Fall back to the first matching file on the system if ldconfig did not know it.
      local fallback
      fallback="$(find /usr/lib /lib -name "$dep" 2>/dev/null | head -n 1)"
      if [[ -n "$fallback" && -f "$fallback" ]]; then
        resolved_target="$(readlink -f "$fallback" 2>/dev/null || true)"
        copy_with_symlinks "$fallback" "$target_path"
        if [[ -n "$resolved_target" && -f "$resolved_target" && "$resolved_target" != "$fallback" ]]; then
          copy_with_symlinks "$resolved_target" "$lib_dir/$(basename -- "$resolved_target")"
        fi
        log "Copied runtime dependency: $dep -> $target_path"
        needed_libs+=("$dep")
      fi
    done < <(readelf -d "$lib_path" 2>/dev/null | awk '/NEEDED/ { gsub(/\[|\]/, "", $5); print $5 }')
  done < <(find "$lib_dir" -maxdepth 1 -type f -name '*.so*' -print0)

  if [[ ${#needed_libs[@]} -gt 0 ]]; then
    log "Bundled runtime shared libraries: ${needed_libs[*]}"
  fi
}

copy_runtime_shared_libs "$install_root/lib"

log "Build finished"
