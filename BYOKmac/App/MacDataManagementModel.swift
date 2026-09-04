import BYOKchatProviderCore
import Foundation
import Observation

@MainActor
@Observable
final class MacDataManagementModel {
  private(set) var isBusy = false
  var statusMessage: String?
  var errorMessage: String?

  private unowned let app: MacAppModel
  private let service: ProjectAwareDataPortabilityService
  private let providerWorkspace: ProviderWorkspaceStore
  private let conversations: ConversationStore
  private let accountManager: ProviderAccountManager
  private let mcpRuntime: MCPRemoteRuntime
  private let mcpWorkspace: MCPWorkspaceStore

  init(app: MacAppModel, services: BYOKCoreServices) {
    self.app = app
    service = services.dataPortability
    providerWorkspace = services.providerWorkspace
    conversations = services.conversationStore
    accountManager = services.accountManager
    mcpRuntime = services.mcpRuntime
    mcpWorkspace = services.mcpWorkspace
  }

  func makeBackupData() async -> Data? {
    await performResult {
      try await service.exportBackup(defaultSystemPrompt: app.preferences.defaultSystemPrompt)
    }
  }

  func makeProviderConfigurationData() async -> Data? {
    await performResult {
      try await providerWorkspace.exportConfiguration()
    }
  }

  func importBackup(from url: URL, strategy: ProviderImportStrategy) async {
    await perform("Backup imported. Re-enter credentials for imported connections and MCP servers.") {
      let data = try await Self.readSecurityScopedData(from: url)
      let existingDefaultPrompt = app.preferences.defaultSystemPrompt
      await app.stopAllGenerations()

      let summary: BYOKchatImportSummary
      do {
        summary = try await service.importBackup(data, strategy: strategy)
      } catch {
        // Library restoration can fail after the transactional provider/chat
        // restore has already committed. Reflect the effective stored state
        // before reporting that partial-restoration error.
        try? await app.reloadAfterDataMutation()
        throw error
      }

      switch strategy {
      case .replaceExisting:
        app.preferences.defaultSystemPrompt = summary.defaultSystemPrompt
      case .keepExisting:
        if existingDefaultPrompt.isEmpty {
          app.preferences.defaultSystemPrompt = summary.defaultSystemPrompt
        }
      }

      try await app.reloadAfterDataMutation()

      var cleanupMessages: [String] = []
      if !summary.credentialCleanupFailures.isEmpty {
        cleanupMessages.append(
          ProviderError.credentialCleanupFailed(summary.credentialCleanupFailures).localizedDescription
        )
      }
      if !summary.mcpCredentialCleanupFailures.isEmpty {
        cleanupMessages.append(
          "The backup was restored, but Keychain cleanup failed for MCP servers: "
            + summary.mcpCredentialCleanupFailures.map(\.rawValue).joined(separator: ", ")
        )
      }
      if !cleanupMessages.isEmpty {
        errorMessage = cleanupMessages.joined(separator: "\n\n")
      }
    }
  }

  func importProviderConfiguration(from url: URL, strategy: ProviderImportStrategy) async {
    await perform("Connection configuration imported. Credentials were not included.") {
      let data = try await Self.readSecurityScopedData(from: url)
      await app.stopAllGenerations()
      do {
        let cleanupFailures = try await service.importProviderConfiguration(data, strategy: strategy)
        try await app.reloadAfterDataMutation()
        if !cleanupFailures.isEmpty {
          errorMessage = ProviderError.credentialCleanupFailed(cleanupFailures).localizedDescription
        }
      } catch {
        try? await app.reloadAfterDataMutation()
        throw error
      }
    }
  }

  func deleteAllConversations() async {
    await perform("All conversations deleted") {
      await app.stopAllGenerations()
      let conversationIDs = await conversations.conversationSummaries().map(\.id)

      // Commit the primary destructive operation first. Chat-specific MCP and
      // project references are secondary metadata and must never make a failed
      // cleanup look like the conversations themselves were not deleted.
      try await conversations.deleteAllConversations()

      var cleanupWarnings: [String] = []
      for id in conversationIDs {
        do {
          try await mcpWorkspace.removeChatConfiguration(conversationID: id)
        } catch {
          cleanupWarnings.append("MCP cleanup for \(id.rawValue): \(error.localizedDescription)")
        }
      }

      try await app.reloadAfterDataMutation()
      if !cleanupWarnings.isEmpty {
        errorMessage =
          "All conversations were deleted, but some stale tool configuration could not be removed:\n\n"
          + cleanupWarnings.joined(separator: "\n")
      }
    }
  }

  func deleteAllCredentials() async {
    await perform("All provider and MCP credentials removed") {
      await app.stopAllGenerations()
      var cleanupWarnings: [String] = []

      do {
        try await accountManager.removeAllCredentials()
      } catch {
        cleanupWarnings.append("Provider credentials: \(error.localizedDescription)")
      }

      let servers = await mcpRuntime.servers()
      for server in servers {
        do {
          try await mcpRuntime.saveServer(server, credential: "")
        } catch {
          cleanupWarnings.append("MCP credential for \(server.name): \(error.localizedDescription)")
        }
      }

      try await app.reloadAfterDataMutation()
      if !cleanupWarnings.isEmpty {
        errorMessage =
          "Credential removal completed with warnings:\n\n"
          + cleanupWarnings.joined(separator: "\n")
      }
    }
  }

  func resetApplicationDataKeepingBackup() async {
    isBusy = true
    errorMessage = nil
    statusMessage = nil
    defer { isBusy = false }

    do {
      await app.stopAllGenerations()
      let result = try await MacStorageRecovery.resetApplicationDataKeepingBackup(
        environment: app.storageEnvironment,
        telemetryRecorder: app.coreServices?.telemetryRecorder
      )
      app.preferences.defaultSystemPrompt = ""
      app.recordRecoveryBackup(result.backupURL)
      await app.restartAfterReset()

      if result.cleanupWarnings.isEmpty {
        app.dataManagement?.statusMessage = result.backupURL == nil
          ? "Application data reset"
          : "Application data reset. The previous workspace is available as a recovery backup."
      } else {
        app.dataManagement?.errorMessage =
          "The application data was reset, but some cleanup steps need attention:\n\n"
          + result.cleanupWarnings.joined(separator: "\n\n")
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private nonisolated static func readSecurityScopedData(from url: URL) async throws -> Data {
    try await Task.detached(priority: .userInitiated) {
      let accessed = url.startAccessingSecurityScopedResource()
      defer { if accessed { url.stopAccessingSecurityScopedResource() } }
      return try Data(contentsOf: url, options: .mappedIfSafe)
    }.value
  }

  private func perform(
    _ success: String,
    operation: @MainActor () async throws -> Void
  ) async {
    isBusy = true
    errorMessage = nil
    statusMessage = nil
    defer { isBusy = false }
    do {
      try await operation()
      if errorMessage == nil { statusMessage = success }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func performResult<Value: Sendable>(
    _ operation: @MainActor () async throws -> Value
  ) async -> Value? {
    isBusy = true
    errorMessage = nil
    statusMessage = nil
    defer { isBusy = false }
    do {
      return try await operation()
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }
}
