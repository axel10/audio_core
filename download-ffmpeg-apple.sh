#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$script_dir"
target_dir="$repo_root/darwin/FFmpeg.xcframework"

if [[ -d "$target_dir" ]]; then
  echo "FFmpeg Apple framework already exists at $target_dir, skipping download."
  exit 0
fi

download_url="https://github.com/axel10/audio_core/releases/download/0.6/ffmpeg_lib_apple.tar.gz"
temp_file="$repo_root/ffmpeg_lib_apple_temp.tar.gz"

echo "Downloading precompiled FFmpeg Apple libraries from $download_url..."
if command -v curl >/dev/null 2>&1; then
  curl -L -o "$temp_file" "$download_url"
elif command -v wget >/dev/null 2>&1; then
  wget -O "$temp_file" "$download_url"
else
  echo "Error: curl or wget is required to download binaries." >&2
  exit 1
fi

echo "Extracting FFmpeg binaries..."
mkdir -p "$repo_root/darwin"
tar -xzf "$temp_file" -C "$repo_root/darwin"
rm -f "$temp_file"

echo "FFmpeg Apple libraries downloaded and configured successfully!"
