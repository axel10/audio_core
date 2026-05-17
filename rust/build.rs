use std::env;
use std::path::PathBuf;

fn link_optional_library(lib_dir: &PathBuf, name: &str) {
    let static_lib = lib_dir.join(format!("lib{}.a", name));
    let dynamic_lib = lib_dir.join(format!("lib{}.dylib", name));

    if static_lib.exists() {
        println!("cargo:rustc-link-lib=static={}", name);
    } else if dynamic_lib.exists() {
        println!("cargo:rustc-link-lib=dylib={}", name);
    }
}

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
        let (platform_dir, arch_dir) = if target.contains("aarch64-apple-ios-sim") {
            ("ios", "arm64-sim")
        } else if target.contains("aarch64-apple-ios") {
            ("ios", "arm64")
        } else if target.contains("x86_64-apple-ios") {
            ("ios", "x86_64")
        } else if target.contains("aarch64-apple-darwin") {
            ("macos", "arm64")
        } else if target.contains("x86_64-apple-darwin") {
            ("macos", "x86_64")
        } else {
            ("", "")
        };

        if platform_dir.is_empty() || arch_dir.is_empty() {
            return None;
        }

        // 拼接路径：audio_core/$platform/ffmpeg_lib/$arch
        let path = project_root.join(platform_dir).join("ffmpeg_lib").join(arch_dir);
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

            // 设置 rpath，方便开发阶段直接运行程序
            println!("cargo:rustc-link-arg=-Wl,-rpath,{}", lib_dir.display());

            // iOS uses static archives while macOS typically ships dynamic libraries.
            // Pick the available format so Rust links against the right variant.
            link_optional_library(&lib_dir, "mp3lame");
            link_optional_library(&lib_dir, "opus");
        }
    }
}
