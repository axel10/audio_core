# audio_core

VibeFlow 的音频核心模块，负责播放器控制、转码、波形/频谱分析、封面与元数据处理，以及各平台原生音频能力的接入。

## 平台支持

- Android: Rust + FFmpeg + Media3 FFmpeg fallback
- iOS / macOS: AVFoundation 优先，FFmpeg 兜底
- Linux: Rust native plugin，依赖系统 ALSA 和本地 FFmpeg 产物
- Windows: Rust native plugin

## Linux 构建依赖

Linux 上构建 `audio_core` 时，需要先安装系统开发包，否则 Rust 侧的 `alsa-sys` 会因为找不到 `alsa.pc` 而失败。

### Ubuntu / Debian

```bash
sudo apt-get update
sudo apt-get install -y build-essential cmake pkg-config libasound2-dev
```

### Fedora / RHEL / CentOS

```bash
sudo dnf install -y gcc gcc-c++ make cmake pkgconf-pkg-config alsa-lib-devel
```

### Arch Linux

```bash
sudo pacman -S --needed base-devel cmake pkgconf alsa-lib
```

### 说明

- `pkg-config` 用来让 Rust crate 找到系统库。
- `libasound2-dev` / `alsa-lib-devel` / `alsa-lib` 提供 ALSA 的头文件和 `alsa.pc`。
- 如果系统里缺少这些包，构建日志通常会出现：
  - `The system library 'alsa' required by crate 'alsa-sys' was not found`
  - `The file 'alsa.pc' needs to be installed`

## Linux 构建流程

1. 安装上面的系统依赖。
2. 准备本地 FFmpeg 产物。
3. 再执行 Flutter/Linux 构建。

### 生成 Linux FFmpeg 产物

仓库提供了 Linux FFmpeg 下载脚本：

```bash
cd audio_core
./download-ffmpeg-linux.sh
```

Linux 侧会读取 `build/ffmpeg-linux/install/lib` 下的本地 FFmpeg `.so` 文件。

### 构建 Flutter Linux 应用

```bash
flutter build linux
```

如果是在项目根目录构建，也可以直接走主工程的 Linux 构建命令。

## Android FFmpeg fallback

`audio_core` 可以在 Android 上使用 Media3 的 FFmpeg extension 作为后备解码器。

构建流程：

1. `audio_core` 使用仓库中 vendored 的 FFmpeg 源码构建 Android FFmpeg shared libraries。
2. 构建产物会被复制到 `android/ffmpeg_lib/<abi>`。
3. Android 插件在构建时读取这些共享库，并启用 vendored 的 Media3 FFmpeg renderer。

实际要求：

- 如果你希望在 `audio_core` 中启用 FFmpeg fallback，请先运行仓库里的 FFmpeg 构建脚本，确保 `android/ffmpeg_lib/<abi>` 已生成。
- 如果 FFmpeg 库缺失，`audio_core` 仍然可以构建和运行，但 FFmpeg 扩展会保持关闭，ExoPlayer 会回退到普通的 MediaCodec 路径。

## Apple FFmpeg fallback

在 iOS 和 macOS 上，`audio_core` 会优先使用 `AVFoundation` 处理 `m4a`、`mp3`、`wav` 等主流格式；对于 AVFoundation 无法打开的冷门格式，则回退到 FFmpeg。

实现说明：

- FFmpeg 资源来自仓库生成的本地 `ios/ffmpeg_lib` 和 `macos/ffmpeg_lib` 目录。
- iOS pod 现在要求 iOS 13.0 或更高版本，因为 FFmpeg 资源包也是这个要求。
- 冷门格式播放会先解码为 PCM，再通过 `AVAudioPlayerNode` 调度播放。

## Native bindings

要使用原生代码，需要 Dart 侧绑定。
这些绑定由 `package:ffigen` 根据头文件生成。

重新生成绑定：

```bash
dart run ffigen --config ffigen.yaml
```

## 调用原生代码

非常短的原生函数可以直接从任意 isolate 调用，例如 `lib/audio_core.dart` 里的 `sum`。

较长时间运行的原生函数建议放到辅助 isolate 中执行，避免 Flutter 掉帧，例如 `lib/audio_core.dart` 里的 `sumAsync`。
