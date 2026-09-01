import BYOKchatProviderCore
import Foundation
import SwiftUI

@main
struct BYOKmacApp: App {
  @State private var status = "Preparing shared core…"

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
        await prepareCore()
      }
    }
  }

  @MainActor
  private func prepareCore() async {
    do {
      let environment = Self.storageEnvironment
      try await BYOKStorageBootstrap.prepare(environment: environment)

      // The placeholder intentionally stops at the shared layer. Loading this
      // graph proves the same provider/chat/project/library/MCP composition
      // used by iOS can initialize on macOS without building product UI yet.
      let services = try BYOKCoreServices.secure(environment: environment)
      try await services.loadStoredState()
      await services.telemetryRecorder.performMaintenance()

      let health = await services.telemetryRecorder.health()
      let chatCount = await services.conversationStore.conversationSummaries().count
      status = health.isAvailable
        ? "Shared core ready · \(chatCount) chats"
        : "Shared core ready · telemetry unavailable"
    } catch {
      status = "Core failed: \(error.localizedDescription)"
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
