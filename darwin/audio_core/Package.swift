// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "audio_core",
    platforms: [
        .iOS("15.0"),
        .macOS("11.0")
    ],
    products: [
        .library(name: "audio-core", targets: ["audio_core"])
    ],
    dependencies: [
        .package(path: "/Users/axel10/projects/player_project/SFBAudioEngine")
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
