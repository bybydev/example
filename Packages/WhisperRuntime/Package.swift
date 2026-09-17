// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "WhisperRuntime",
    platforms: [.macOS(.v15), .iOS(.v26)],
    products: [.library(name: "WhisperRuntime", targets: ["WhisperRuntime"])],
    dependencies: [
        .package(path: "../InkribeModelAssets"),
        .package(url: "https://github.com/apple/swift-log", exact: "1.11.0")
    ],
    targets: [
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/b5130/whisper-b5130-xcframework.zip",
            checksum: "033a43b0174e8cf9b366f72e4a428cdcf126f93ad1c87d3fa119a96bed6f231a"
        ),
        .target(
            name: "WhisperRuntime",
            dependencies: [
                "whisper",
                .product(name: "InkribeModelAssets", package: "InkribeModelAssets"),
                .product(name: "Logging", package: "swift-log")
            ]
        ),
        .testTarget(
            name: "WhisperRuntimeTests",
            dependencies: ["WhisperRuntime"]
        )
    ],
    swiftLanguageModes: [.v6]
)
