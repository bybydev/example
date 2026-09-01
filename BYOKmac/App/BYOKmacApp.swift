import BYOKchatProviderCore
import SwiftUI

@main
struct BYOKmacApp: App {
  @State private var status = "Preparing shared storage…"

  var body: some Scene {
    WindowGroup {
      VStack(spacing: 12) {
        Text("BYOK")
          .font(.largeTitle.weight(.semibold))
        Text("macOS placeholder")
          .foregroundStyle(.secondary)
        Text(status)
          .font(.callout.monospaced())
          .foregroundStyle(.secondary)
      }
      .frame(minWidth: 520, minHeight: 320)
      .task {
        await prepareStorage()
      }
    }
  }

  @MainActor
  private func prepareStorage() async {
    do {
      try await BYOKStorageBootstrap.prepare(environment: Self.storageEnvironment)
      status = "Shared storage ready"
    } catch {
      status = "Storage failed: \(error.localizedDescription)"
    }
  }

  private static var storageEnvironment: BYOKStorageEnvironment {
    let fileManager = FileManager.default
    let applicationSupport = fileManager.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first ?? fileManager.temporaryDirectory
    let root = applicationSupport.appendingPathComponent("BYOKchat", isDirectory: true)
    let telemetryNamespace = Bundle.main.bundleIdentifier ?? "com.hoangbkit.byokmac"

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
