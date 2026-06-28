// swift-tools-version: 5.9
import PackageDescription
import Foundation

let packageDir = URL(fileURLWithPath: #file).resolvingSymlinksInPath().deletingLastPathComponent()
let sfbPath = packageDir.appendingPathComponent("../../SFBAudioEngine").path

let package = Package(
    name: "audio_core",
    platforms: [
        .iOS("15.0"),
        .macOS("13.0")
    ],
    products: [
        .library(name: "audio-core", type: .dynamic, targets: ["audio_core"])
    ],
    dependencies: [
        .package(path: sfbPath)
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
