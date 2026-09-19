// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "DiarizationRuntime",
    platforms: [.macOS(.v15), .iOS(.v26)],
    products: [.library(name: "DiarizationRuntime", targets: ["DiarizationRuntime"])],
    dependencies: [
        .package(path: "../InkribeModelAssets"),
        .package(url: "https://github.com/k2-fsa/sherpa-onnx", exact: "1.13.8"),
        .package(url: "https://github.com/apple/swift-log", exact: "1.11.0")
    ],
    targets: [
        .target(
            name: "DiarizationRuntime",
            dependencies: [
                .product(name: "InkribeModelAssets", package: "InkribeModelAssets"),
                .product(name: "sherpa-onnx", package: "sherpa-onnx"),
                .product(name: "Logging", package: "swift-log")
            ]
        ),
        .testTarget(
            name: "DiarizationRuntimeTests",
            dependencies: ["DiarizationRuntime"]
        )
    ],
    swiftLanguageModes: [.v6]
)
