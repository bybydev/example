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
      path: "Sources/CSQLite",
      pkgConfig: "sqlite3",
      providers: [
        .brew(["sqlite3"]),
        .apt(["libsqlite3-dev"]),
      ]
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
