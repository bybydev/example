// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "InkribeAudio",
    platforms: [.macOS(.v15), .iOS(.v26)],
    products: [.library(name: "InkribeAudio", targets: ["InkribeAudio"])],
    targets: [
        .target(name: "InkribeAudio"),
        .testTarget(name: "InkribeAudioTests", dependencies: ["InkribeAudio"])
    ],
    swiftLanguageModes: [.v6]
)
