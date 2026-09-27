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
  private let projectWorkspace: ProjectWorkspaceStore
  private let libraryStore: LibraryStore
  private let conversations: ConversationStore
  private let accountManager: ProviderAccountManager
  private let mcpRuntime: MCPRemoteRuntime
  private let mcpWorkspace: MCPWorkspaceStore
  private let restrictions: MacProResourceRestrictions

  init(
    app: MacAppModel,
    services: BYOKCoreServices,
    restrictions: MacProResourceRestrictions = MacPurchaseStore.restrictions
  ) {
    self.app = app
    service = services.dataPortability
    providerWorkspace = services.providerWorkspace
    projectWorkspace = services.projectWorkspace
    libraryStore = services.libraryStore
    conversations = services.conversationStore
    accountManager = services.accountManager
    mcpRuntime = services.mcpRuntime
    mcpWorkspace = services.mcpWorkspace
    self.restrictions = restrictions
  }

  func makeBackupData() async -> Data? {
    await performResult(errorCode: "backup_export_failed") {
      try await service.exportBackup(defaultSystemPrompt: app.preferences.defaultSystemPrompt)
    }
  }

  func makeProviderConfigurationData() async -> Data? {
    await performResult(errorCode: "provider_config_export_failed") {
      try await providerWorkspace.exportConfiguration()
    }
  }

  func importBackup(from url: URL, strategy: ProviderImportStrategy) async {
    await perform(
      "Backup imported. Re-enter credentials for imported connections and MCP servers.",
      errorCode: "backup_import_failed"
    ) {
      let data = try await Self.readSecurityScopedData(from: url)
      let existingDefaultPrompt = app.preferences.defaultSystemPrompt
      let resourcesBefore = await resourceSnapshot()
      await app.stopAllGenerations()

      let summary: BYOKchatImportSummary
      do {
        summary = try await service.importBackup(data, strategy: strategy)
      } catch {
        // A failed full-backup import now rolls persistent workspaces back as one logical
        // transaction. Reload best-effort so the presentation reflects that restored state.
        try? await app.reloadAfterDataMutation()
        throw error
      }

      let resourcesAfter = await resourceSnapshot()
      restrictions.recordFullBackupImport(
        before: resourcesBefore,
        after: resourcesAfter,
        strategy: strategy,
        entitlement: MacProAccess.entitlementAccess
      )

      switch strategy {
      case .replaceExisting:
        app.preferences.defaultSystemPrompt = summary.defaultSystemPrompt
      case .keepExisting:
        if existingDefaultPrompt.isEmpty {
          app.preferences.defaultSystemPrompt = summary.defaultSystemPrompt
        }
      }

      do {
        try await app.reloadAfterDataMutation()
      } catch {
        MacAppAnalytics.reportError("post_import_refresh_failed", component: "data")
        // Persistent restore is authoritative. A presentation refresh failure must not tell
        // the user the backup failed and invite a dangerous retry of an already-committed import.
        statusMessage =
          "Backup imported, but the app could not refresh its views: \(error.localizedDescription)"
      }

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
    await perform(
      "Connection configuration imported. Credentials were not included.",
      errorCode: nil
    ) {
      let data = try await Self.readSecurityScopedData(from: url)
      let imported = try JSONDecoder().decode(ProviderWorkspaceState.self, from: data)
      let existingState = await providerWorkspace.snapshot()
      let existing = existingState.accounts.map(\.id)

      switch MacProAccess.providerConfigurationImportDecision(
        existingIDs: existing,
        importedIDs: imported.accounts.map(\.id),
        strategy: strategy
      ) {
      case .allowed:
        break
      case .checking:
        throw ProviderError.invalidRequest(
          "Checking your BYOK Pro status before importing additional connections. Try again in a moment."
        )
      case .requiresPro:
        MacProAccess.requestUpgrade(.providerAccounts)
        throw ProviderError.invalidRequest(
          "This connection import would exceed the Free 1-connection limit. Upgrade to BYOK Pro to import it."
        )
      }

      await app.stopAllGenerations()
      do {
        let cleanupFailures = try await service.importProviderConfiguration(data, strategy: strategy)
        do {
          try await app.reloadAfterDataMutation()
        } catch {
          MacAppAnalytics.reportError("post_import_refresh_failed", component: "data")
          statusMessage =
            "Connection configuration imported, but the app could not refresh its views: \(error.localizedDescription)"
        }
        if !cleanupFailures.isEmpty {
          errorMessage = ProviderError.credentialCleanupFailed(cleanupFailures).localizedDescription
        }
      } catch {
        MacAppAnalytics.reportError("provider_config_import_failed", component: "data")
        try? await app.reloadAfterDataMutation()
        throw error
      }
    }
  }

  func deleteAllConversations() async {
    await perform("All conversations deleted", errorCode: "delete_conversations_failed") {
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
    await perform(
      "All provider and MCP credentials removed",
      errorCode: "delete_credentials_failed"
    ) {
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
      restrictions.clear()
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
      MacAppAnalytics.reportError("reset_application_failed", component: "data")
      errorMessage = error.localizedDescription
    }
  }

  private func resourceSnapshot() async -> MacProResourceSnapshot {
    let providers = await providerWorkspace.snapshot()
    let projects = await projectWorkspace.snapshot()
    let mcp = await mcpWorkspace.snapshot()
    let library = await libraryStore.entries()

    return MacProResourceSnapshot(
      providerAccountIDs: providers.accounts.map { $0.id.rawValue },
      projectIDs: projects.projects.map { $0.id.rawValue },
      mcpServerIDs: mcp.servers.map { $0.id.rawValue },
      libraryEntryIDs: library.map { $0.id.rawValue }
    )
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
    errorCode: String?,
    operation: @MainActor () async throws -> Void
  ) async {
    isBusy = true
    errorMessage = nil
    statusMessage = nil
    defer { isBusy = false }
    do {
      try await operation()
      if errorMessage == nil, statusMessage == nil { statusMessage = success }
    } catch {
      if let errorCode {
        MacAppAnalytics.reportError(errorCode, component: "data")
      }
      errorMessage = error.localizedDescription
    }
  }

  private func performResult<Value: Sendable>(
    errorCode: String,
    _ operation: @MainActor () async throws -> Value
  ) async -> Value? {
    isBusy = true
    errorMessage = nil
    statusMessage = nil
    defer { isBusy = false }
    do {
      return try await operation()
    } catch {
      MacAppAnalytics.reportError(errorCode, component: "data")
      errorMessage = error.localizedDescription
      return nil
    }
  }
}