use std::env;
use std::path::PathBuf;

fn main() {
    // 告诉 Cargo 如果环境变量变化了重新运行
    println!("cargo:rerun-if-env-changed=FFMPEG_DIR");
    println!("cargo:rerun-if-changed=build.rs");

    let target = env::var("TARGET").unwrap_or_default();
    let target_os = env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();

    // 仅针对 macOS 和 iOS 进行处理
    if target_os != "macos" && target_os != "ios" {
        return;
    }

    // 1. 自动推导 FFMPEG_DIR
    // 优先使用手动设置的环境变量，如果没有则尝试自动推导
    let ffmpeg_dir = env::var("FFMPEG_DIR").ok().map(PathBuf::from).or_else(|| {
        let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
        let project_root = manifest_dir.parent().unwrap(); // audio_core 根目录

        // 根据编译目标三元组 (Target Triple) 映射到你的构建目录名
        let arch_dir = if target.contains("aarch64-apple-ios-sim") {
            "arm64-sim"
        } else if target.contains("aarch64-apple-ios") {
            "arm64"
        } else if target.contains("x86_64-apple-ios") {
            "x86_64"
        } else if target.contains("aarch64-apple-darwin") {
            "arm64" // macOS 环境
        } else {
            ""
        };

        if arch_dir.is_empty() {
            return None;
        }

        // 拼接路径：audio_core/ios/ffmpeg_lib/$arch
        let path = project_root.join("ios/ffmpeg_lib").join(arch_dir);
        if path.exists() {
            Some(path)
        } else {
            None
        }
    });

    // 2. 配置链接参数
    if let Some(dir) = ffmpeg_dir {
        let lib_dir = dir.join("lib");
        
        if lib_dir.exists() {
            println!("cargo:rustc-link-search=native={}", lib_dir.display());
            
            // 设置环境变量，供当前 crate 及其可能的子过程使用
            println!("cargo:rustc-env=FFMPEG_DIR={}", dir.display());

            // 链接 LAME 静态库
            if lib_dir.join("libmp3lame.a").exists() {
                println!("cargo:rustc-link-lib=static=mp3lame");
            }

            // 链接 Opus 静态库
            if lib_dir.join("libopus.a").exists() {
                println!("cargo:rustc-link-lib=static=opus");
            }
        }
    }
}
