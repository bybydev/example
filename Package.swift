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
    .target(
      name: "BYOKchatProviderCore",
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
