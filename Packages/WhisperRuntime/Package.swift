// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "WhisperRuntime",
    platforms: [.macOS(.v15), .iOS(.v26)],
    products: [.library(name: "WhisperRuntime", targets: ["WhisperRuntime"])],
    targets: [.target(name: "WhisperRuntime")],
    swiftLanguageModes: [.v6]
)
