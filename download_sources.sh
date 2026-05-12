#!/bin/bash

# URLs
FDK_AAC_URL="https://downloads.sourceforge.net/opencore-amr/fdk-aac-2.0.3.tar.gz"
FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-8.1.tar.xz"
OPUS_URL="https://downloads.xiph.org/releases/opus/opus-1.5.2.tar.gz"
LAME_GIT="https://github.com/axel10/lame-3.100"

# Root directory (script location)
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

echo "Downloading sources to $ROOT_DIR..."

# 1. fdk-aac
if [ ! -d "fdk-aac-2.0.3" ]; then
    echo "Downloading fdk-aac-2.0.3..."
    curl -L "$FDK_AAC_URL" -o fdk-aac-2.0.3.tar.gz
    tar -xzf fdk-aac-2.0.3.tar.gz
    rm fdk-aac-2.0.3.tar.gz
else
    echo "fdk-aac-2.0.3 already exists, skipping."
fi

# 2. FFmpeg
if [ ! -d "ffmpeg-8.1" ]; then
    echo "Downloading FFmpeg 8.1..."
    curl -L "$FFMPEG_URL" -o ffmpeg-8.1.tar.xz
    tar -xJf ffmpeg-8.1.tar.xz
    rm ffmpeg-8.1.tar.xz
else
    echo "ffmpeg-8.1 already exists, skipping."
fi

# 3. libopus
if [ ! -d "opus-1.5.2" ]; then
    echo "Downloading libopus 1.5.2..."
    curl -L "$OPUS_URL" -o opus-1.5.2.tar.gz
    tar -xzf opus-1.5.2.tar.gz
    rm opus-1.5.2.tar.gz
else
    echo "opus-1.5.2 already exists, skipping."
fi

# 4. LAME
if [ ! -d "lame-3.100" ]; then
    echo "Cloning LAME from $LAME_GIT..."
    git clone "$LAME_GIT"
else
    echo "lame-3.100 already exists, skipping."
fi

echo "All sources are ready in $ROOT_DIR."
