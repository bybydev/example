import BYOKchatProviderCore
import Foundation

/// iOS owns sandbox/namespace selection; shared core owns the layout beneath it.
enum AppStorageEnvironment {
  static var current: BYOKStorageEnvironment {
    let fileManager = FileManager.default
    let applicationSupport = fileManager.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first ?? fileManager.temporaryDirectory
    let root = applicationSupport.appendingPathComponent("BYOKchat", isDirectory: true)
    let telemetryNamespace = Bundle.main.bundleIdentifier ?? "com.hoangbkit.byokchat"

    return BYOKStorageEnvironment(
      rootDirectory: root,
      userDefaultsSuiteName: nil,
      credentialService: "com.hoangbkit.byokchat.credentials",
      mcpCredentialService: "com.hoangbkit.byokchat.mcp.credentials",
      telemetryDirectory: applicationSupport
        .appendingPathComponent(telemetryNamespace, isDirectory: true)
        .appendingPathComponent("Telemetry", isDirectory: true)
    )
  }
}
