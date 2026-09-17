// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "InkribePersistence",
    platforms: [.macOS(.v15), .iOS(.v26)],
    products: [.library(name: "InkribePersistence", targets: ["InkribePersistence"])],
    dependencies: [.package(path: "../InkribeCore")],
    targets: [
        .target(name: "InkribePersistence", dependencies: ["InkribeCore"]),
        .testTarget(
            name: "InkribePersistenceTests",
            dependencies: ["InkribePersistence", "InkribeCore"]
        )
    ],
    swiftLanguageModes: [.v6]
)
