#!/bin/bash

# URLs
FDK_AAC_URL="https://downloads.sourceforge.net/opencore-amr/fdk-aac-2.0.3.tar.gz"
FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-8.1.tar.xz"
OPUS_URL="https://downloads.xiph.org/releases/opus/opus-1.5.2.tar.gz"
LAME_GIT="https://github.com/axel10/lame-3.100"
RUST_FFMPEG_GIT="https://github.com/axel10/rust-ffmpeg"
VCPKG_GIT="https://github.com/microsoft/vcpkg.git"
VCPKG_PORT_NAME="ffmpeg-vibeflow-audio"
VCPKG_TRIPLET="x64-windows-audio"

# Root directory (script location)
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

echo "Downloading sources to $ROOT_DIR..."

is_windows_shell() {
    local uname_value
    uname_value="$(uname -s 2>/dev/null || true)"
    case "$uname_value" in
        MINGW*|MSYS*|CYGWIN*)
            return 0
            ;;
    esac
    case "$OS" in
        Windows_NT)
            return 0
            ;;
    esac
    return 1
}

dir_is_empty() {
    local dir_path="$1"
    [ -d "$dir_path" ] && [ -z "$(find "$dir_path" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]
}

ensure_vcpkg() {
    local vcpkg_root="${VCPKG_ROOT:-$ROOT_DIR/vcpkg}"
    local vcpkg_exe="$vcpkg_root/vcpkg.exe"

    if [ -x "$vcpkg_exe" ]; then
        echo "Using existing vcpkg at $vcpkg_root."
    else
        if [ ! -d "$vcpkg_root" ]; then
            echo "Cloning vcpkg from $VCPKG_GIT..."
            git clone "$VCPKG_GIT" "$vcpkg_root"
        else
            echo "vcpkg directory already exists, reusing $vcpkg_root."
        fi

        echo "Bootstrapping vcpkg..."
        (
            cd "$vcpkg_root" && \
            cmd.exe /c "bootstrap-vcpkg.bat -disableMetrics"
        )
    fi

    VCPKG_ROOT="$vcpkg_root"
}

if is_windows_shell; then
    echo "Windows detected, using vcpkg for FFmpeg dependencies."

    ensure_vcpkg
    export VCPKG_ROOT

    if [ ! -d "$ROOT_DIR/$VCPKG_PORT_NAME" ]; then
        echo "Expected port directory '$VCPKG_PORT_NAME' was not found."
        exit 1
    fi

    echo "Installing $VCPKG_PORT_NAME:$VCPKG_TRIPLET from overlay ports..."
    "$VCPKG_ROOT/vcpkg.exe" install "${VCPKG_PORT_NAME}:${VCPKG_TRIPLET}" \
        --overlay-ports="$ROOT_DIR" \
        --overlay-triplets="$ROOT_DIR/$VCPKG_PORT_NAME/triplets"
else
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
fi

# 5. rust-ffmpeg
if [ ! -d "rust/rust-ffmpeg" ] || dir_is_empty "rust/rust-ffmpeg"; then
    echo "Cloning rust-ffmpeg from $RUST_FFMPEG_GIT..."
    rm -rf "rust/rust-ffmpeg"
    git clone "$RUST_FFMPEG_GIT" "rust/rust-ffmpeg"
else
    echo "rust/rust-ffmpeg already exists, skipping."
fi

echo "All sources are ready in $ROOT_DIR."
