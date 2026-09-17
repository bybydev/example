// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "InkribeTranscription",
    platforms: [.macOS(.v15), .iOS(.v26)],
    products: [.library(name: "InkribeTranscription", targets: ["InkribeTranscription"])],
    dependencies: [
        .package(path: "../InkribeCore"),
        .package(path: "../InkribeAudio"),
        .package(path: "../InkribePersistence"),
        .package(path: "../WhisperRuntime"),
        .package(url: "https://github.com/hoangbkit/JobQueue.git", exact: "1.0.0")
    ],
    targets: [
        .target(
            name: "InkribeTranscription",
            dependencies: [
                "InkribeCore",
                "InkribeAudio",
                "InkribePersistence",
                "WhisperRuntime",
                .product(name: "JobQueue", package: "JobQueue")
            ]
        ),
        .testTarget(
            name: "InkribeTranscriptionTests",
            dependencies: [
                "InkribeTranscription",
                "InkribeCore",
                "InkribeAudio",
                "InkribePersistence",
                "WhisperRuntime",
                .product(name: "JobQueue", package: "JobQueue")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
