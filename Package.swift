// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "BYOKchatProviderCore",
  platforms: [
    .iOS(.v26),
    .macOS(.v15),
  ],
  products: [
    .library(
      name: "BYOKchatProviderCore",
      targets: ["BYOKchatProviderCore"]
    ),
  ],
  targets: [
    .systemLibrary(
      name: "CSQLite",
      path: "Sources/CSQLite"
    ),
    .target(
      name: "BYOKchatProviderCore",
      dependencies: ["CSQLite"],
      path: "Sources/BYOKchatProviderCore"
    ),
    .testTarget(
      name: "BYOKchatProviderCoreTests",
      dependencies: ["BYOKchatProviderCore"],
      path: "Tests/BYOKchatProviderCoreTests"
    ),
  ],
  swiftLanguageModes: [.v6]
)
