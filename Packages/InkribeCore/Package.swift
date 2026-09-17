// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "InkribeCore",
    platforms: [.macOS(.v15), .iOS(.v26)],
    products: [.library(name: "InkribeCore", targets: ["InkribeCore"])],
    targets: [
        .target(name: "InkribeCore"),
        .testTarget(name: "InkribeCoreTests", dependencies: ["InkribeCore"])
    ],
    swiftLanguageModes: [.v6]
)
