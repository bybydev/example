// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "InkribeExport",
    platforms: [.macOS(.v15), .iOS(.v26)],
    products: [.library(name: "InkribeExport", targets: ["InkribeExport"])],
    dependencies: [.package(path: "../InkribeCore")],
    targets: [.target(name: "InkribeExport", dependencies: ["InkribeCore"])],
    swiftLanguageModes: [.v6]
)
