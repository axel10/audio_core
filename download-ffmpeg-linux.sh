#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$script_dir"
target_dir="$repo_root/build/ffmpeg-linux/install"

if [[ -f "$target_dir/lib/pkgconfig/libavcodec.pc" ]]; then
  echo "FFmpeg Linux binaries already exist at $target_dir, skipping download."
  exit 0
fi

download_url="https://github.com/axel10/audio_core/releases/download/0.6/ffmpeg_lib_linux.tar.gz"
temp_file="$repo_root/ffmpeg_lib_linux_temp.tar.gz"

echo "Downloading precompiled FFmpeg Linux libraries from $download_url..."
if command -v curl >/dev/null 2>&1; then
  curl -L -o "$temp_file" "$download_url"
elif command -v wget >/dev/null 2>&1; then
  wget -O "$temp_file" "$download_url"
else
  echo "Error: curl or wget is required to download binaries." >&2
  exit 1
fi

echo "Extracting FFmpeg binaries..."
mkdir -p "$target_dir"
tar -xzf "$temp_file" -C "$target_dir"
rm -f "$temp_file"

echo "Fixing pkgconfig prefix paths..."
for pc in "$target_dir/lib/pkgconfig"/*.pc; do
  if [[ -f "$pc" ]]; then
    sed -i "s|^prefix=.*|prefix=$target_dir|g" "$pc"
    sed -i "s|/workspace/build/ffmpeg-linux/install|\${prefix}|g" "$pc"
  fi
done

echo "FFmpeg Linux binaries downloaded and configured successfully!"
