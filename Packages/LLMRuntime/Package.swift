// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "LLMRuntime",
    platforms: [.macOS(.v15), .iOS(.v26)],
    products: [.library(name: "LLMRuntime", targets: ["LLMRuntime"])],
    targets: [.target(name: "LLMRuntime")],
    swiftLanguageModes: [.v6]
)
