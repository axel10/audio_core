// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "audio_core",
    platforms: [
        .iOS("15.0"),
        .macOS("13.0")
    ],
    products: [
        .library(name: "audio-core", targets: ["audio_core"])
    ],
    dependencies: [
        .package(url: "https://github.com/sbooth/SFBAudioEngine", branch: "main")
    ],
    targets: [
        .target(
            name: "audio_core",
            dependencies: [
                .product(name: "SFBAudioEngine", package: "SFBAudioEngine")
            ]
        )
    ]
)
