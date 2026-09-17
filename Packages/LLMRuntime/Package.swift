// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "LLMRuntime",
    platforms: [.macOS(.v15), .iOS(.v26)],
    products: [.library(name: "LLMRuntime", targets: ["LLMRuntime"])],
    dependencies: [
        .package(path: "../InkribeModelAssets")
    ],
    targets: [
        .target(
            name: "LLMRuntime",
            dependencies: [
                .product(name: "InkribeModelAssets", package: "InkribeModelAssets")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
