// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "LLMRuntime",
    platforms: [.macOS(.v15), .iOS(.v26)],
    products: [.library(name: "LLMRuntime", targets: ["LLMRuntime"])],
    dependencies: [
        .package(path: "../InkribeModelAssets"),
        .package(url: "https://github.com/apple/swift-log", exact: "1.11.0")
    ],
    targets: [
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b10964/llama-b10964-xcframework.zip",
            checksum: "b342a31c3160095d02777cbf1719013d4e6ff7556a1d46ab9eb5df0a93d13c47"
        ),
        .target(
            name: "LLMRuntime",
            dependencies: [
                "llama",
                .product(name: "InkribeModelAssets", package: "InkribeModelAssets"),
                .product(name: "Logging", package: "swift-log")
            ]
        ),
        .testTarget(
            name: "LLMRuntimeTests",
            dependencies: ["LLMRuntime"]
        )
    ],
    swiftLanguageModes: [.v6]
)
