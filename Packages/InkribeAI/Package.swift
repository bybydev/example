// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "InkribeAI",
    platforms: [.macOS(.v15), .iOS(.v26)],
    products: [.library(name: "InkribeAI", targets: ["InkribeAI"])],
    dependencies: [
        .package(path: "../InkribeCore"),
        .package(path: "../LLMRuntime")
    ],
    targets: [
        .target(name: "InkribeAI", dependencies: ["InkribeCore", "LLMRuntime"]),
        .testTarget(
            name: "InkribeAITests",
            dependencies: ["InkribeAI", "InkribeCore", "LLMRuntime"]
        )
    ],
    swiftLanguageModes: [.v6]
)
