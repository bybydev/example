import BYOKchatProviderCore
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

struct JSONExportDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.json] }
  var data: Data

  init(data: Data = Data()) { self.data = data }

  init(configuration: ReadConfiguration) throws {
    data = configuration.file.regularFileContents ?? Data()
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}

struct MarkdownExportDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.markdown, .plainText] }
  var data: Data

  init(data: Data = Data()) { self.data = data }

  init(configuration: ReadConfiguration) throws {
    data = configuration.file.regularFileContents ?? Data()
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}

@MainActor
@Observable
final class DataPortabilityModel {
  private let service: DataPortabilityService
  private let providerWorkspace: ProviderWorkspaceStore
  private let conversations: ConversationStore
  private let accountManager: ProviderAccountManager
  private let preferences: AppPreferencesModel
  private let providersModel: ProviderManagementModel
  private let chatsModel: ChatManagementModel

  var isBusy = false
  var statusMessage: String?
  var errorMessage: String?

  init(
    service: DataPortabilityService,
    providerWorkspace: ProviderWorkspaceStore,
    conversations: ConversationStore,
    accountManager: ProviderAccountManager,
    preferences: AppPreferencesModel,
    providersModel: ProviderManagementModel,
    chatsModel: ChatManagementModel
  ) {
    self.service = service
    self.providerWorkspace = providerWorkspace
    self.conversations = conversations
    self.accountManager = accountManager
    self.preferences = preferences
    self.providersModel = providersModel
    self.chatsModel = chatsModel
  }

  func makeBackupDocument() async -> JSONExportDocument? {
    await performResult {
      JSONExportDocument(
        data: try await service.exportBackup(
          defaultSystemPrompt: preferences.defaultSystemPrompt))
    }
  }

  func makeProviderConfigurationDocument() async -> JSONExportDocument? {
    await performResult {
      JSONExportDocument(data: try await providerWorkspace.exportConfiguration())
    }
  }

  func makeConversationDocument(
    conversationID: ConversationID,
    accountLabel: String?
  ) async -> MarkdownExportDocument? {
    await performResult {
      MarkdownExportDocument(
        data: try await service.exportConversationMarkdown(
          conversationID: conversationID,
          accountLabel: accountLabel
        )
      )
    }
  }

  func importBackup(from url: URL, strategy: ProviderImportStrategy) async {
    await perform("Backup imported. Re-enter credentials for imported accounts.") {
      let data = try readSecurityScopedData(from: url)
      let existingDefaultPrompt = preferences.defaultSystemPrompt
      await chatsModel.stopAllGenerations()
      let summary = try await service.importBackup(data, strategy: strategy)
      let replacesExisting: Bool
      switch strategy {
      case .replaceExisting: replacesExisting = true
      case .keepExisting: replacesExisting = false
      }
      if replacesExisting || existingDefaultPrompt.isEmpty {
        preferences.defaultSystemPrompt = summary.defaultSystemPrompt
      }
      await providersModel.reloadFromStorage()
      await chatsModel.reloadFromStorage()
    }
  }

  func importProviderConfiguration(from url: URL, strategy: ProviderImportStrategy) async {
    await perform("Provider configuration imported. Credentials were not included.") {
      let data = try readSecurityScopedData(from: url)
      await chatsModel.stopAllGenerations()
      let previousAccountIDs = await providerWorkspace.allAccounts().map(\.id)
      try await providerWorkspace.importConfiguration(data, strategy: strategy)
      if case .replaceExisting = strategy {
        let importedAccountIDs = await providerWorkspace.allAccounts().map(\.id)
        try await accountManager.removeCredentials(
          accountIDs: previousAccountIDs + importedAccountIDs)
      }
      await providersModel.reloadFromStorage()
    }
  }

  func deleteAllConversations() async {
    await perform("All conversations deleted") {
      await chatsModel.stopAllGenerations()
      try await conversations.deleteAllConversations()
      await chatsModel.reloadFromStorage()
    }
  }

  func deleteAllCredentials() async {
    await perform("All credentials removed") {
      try await accountManager.removeAllCredentials()
      await providersModel.reloadFromStorage()
    }
  }

  private func readSecurityScopedData(from url: URL) throws -> Data {
    let accessed = url.startAccessingSecurityScopedResource()
    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
    return try Data(contentsOf: url, options: .mappedIfSafe)
  }

  private func perform(_ success: String, operation: () async throws -> Void) async {
    isBusy = true
    defer { isBusy = false }
    do {
      try await operation()
      statusMessage = success
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func performResult<Value>(_ operation: () async throws -> Value) async -> Value? {
    isBusy = true
    defer { isBusy = false }
    do {
      return try await operation()
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }
}
