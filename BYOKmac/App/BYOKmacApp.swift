import BYOKchatProviderCore
import Foundation
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
      let environment = Self.storageEnvironment
      try await BYOKStorageBootstrap.prepare(environment: environment)

      // Keep this target intentionally tiny, but exercise the same host-owned
      // telemetry composition as iOS so Bundle.main never decides persistence.
      let telemetry = environment.makeTelemetryRecorder()
      await telemetry.performMaintenance()
      let health = await telemetry.health()
      status = health.isAvailable
        ? "Shared storage + telemetry ready"
        : "Shared storage ready; telemetry unavailable"
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
