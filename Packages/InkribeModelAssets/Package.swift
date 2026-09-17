// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "InkribeModelAssets",
    platforms: [.macOS(.v15), .iOS(.v26)],
    products: [
        .library(name: "InkribeModelAssets", targets: ["InkribeModelAssets"]),
        .executable(name: "ModelAssetTool", targets: ["ModelAssetTool"])
    ],
    targets: [
        .target(
            name: "InkribeModelAssets",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "ModelAssetTool",
            dependencies: ["InkribeModelAssets"]
        ),
        .testTarget(
            name: "InkribeModelAssetsTests",
            dependencies: ["InkribeModelAssets"]
        )
    ],
    swiftLanguageModes: [.v6]
)
