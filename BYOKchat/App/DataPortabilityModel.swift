import BYOKchatProviderCore
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
  static let byokMarkdown = UTType(filenameExtension: "md") ?? .plainText
}

struct JSONExportDocument: FileDocument, Sendable {
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

struct MarkdownExportDocument: FileDocument, Sendable {
  static var readableContentTypes: [UTType] { [.byokMarkdown, .plainText] }
  var data: Data

  init(data: Data = Data()) { self.data = data }

  init(configuration: ReadConfiguration) throws {
    data = configuration.file.regularFileContents ?? Data()
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}

private enum DataManagementError: LocalizedError {
  case combined(String)

  var errorDescription: String? {
    switch self {
    case .combined(let message): message
    }
  }
}

@MainActor
@Observable
final class DataPortabilityModel {
  private let conversations: ConversationStore
  private let accountManager: ProviderAccountManager
  private let preferences: AppPreferencesModel
  private let providersModel: ProviderManagementModel
  private let chatsModel: ChatManagementModel
  private let projectsModel: ProjectManagementModel
  private let mcpModel: MCPManagementModel
  private let storageEnvironment: BYOKStorageEnvironment?
  private let fileBlobStore: FileAttachmentBlobStore?

  var onConversationsDeleted: (@MainActor () async -> Void)?
  var isBusy = false
  var isMeasuringStorage = false
  var storageReport: BYOKStorageUsageReport?
  var statusMessage: String?
  var errorMessage: String?

  init(
    conversations: ConversationStore,
    accountManager: ProviderAccountManager,
    preferences: AppPreferencesModel,
    providersModel: ProviderManagementModel,
    chatsModel: ChatManagementModel,
    projectsModel: ProjectManagementModel,
    mcpModel: MCPManagementModel,
    storageEnvironment: BYOKStorageEnvironment? = nil,
    fileBlobStore: FileAttachmentBlobStore? = nil
  ) {
    self.conversations = conversations
    self.accountManager = accountManager
    self.preferences = preferences
    self.providersModel = providersModel
    self.chatsModel = chatsModel
    self.projectsModel = projectsModel
    self.mcpModel = mcpModel
    self.storageEnvironment = storageEnvironment
    self.fileBlobStore = fileBlobStore
  }

  func refreshStorageUsage() async {
    guard let storageEnvironment, !isMeasuringStorage else { return }
    isMeasuringStorage = true
    defer { isMeasuringStorage = false }
    let layout = storageEnvironment.layout
    let telemetryDir = storageEnvironment.telemetryDirectory
    let report = await Task.detached(priority: .utility) {
      layout.measureUsage(telemetryDirectory: telemetryDir)
    }.value
    storageReport = report
  }

  func clearThumbnailCache() async {
    await perform("Cached thumbnails cleared.") {
      _ = await fileBlobStore?.clearDerivedCache()
      AttachmentThumbnailLoader.clearMemoryCache()
      await refreshStorageUsage()
    }
  }

  func clearSearchIndex() async {
    await perform("Search index cleared.") {
      try await chatsModel.clearSearchIndex()
      await refreshStorageUsage()
    }
  }

  func purgeQuarantinedConversations() async {
    await perform("Unreadable chat files removed.") {
      _ = try await conversations.purgeQuarantinedShards()
      await chatsModel.reloadFromStorage()
      await refreshStorageUsage()
    }
  }

  func deleteAllConversations() async {
    await perform("All conversations deleted.") {
      await chatsModel.stopAllGenerations()
      try await conversations.deleteAllConversations()
      preferences.clearPinnedConversations()
      await chatsModel.reloadFromStorage()
      await projectsModel.reconcile(conversations: chatsModel.conversations)

      var cleanupError: (any Error)?
      do {
        try await mcpModel.removeAllChatConfigurations()
      } catch {
        cleanupError = error
        await mcpModel.reloadFromStorage()
      }
      await onConversationsDeleted?()
      await refreshStorageUsage()
      if let cleanupError {
        throw cleanupError
      }
    }
  }

  func deleteAllCredentials() async {
    await perform("All credentials removed.") {
      await chatsModel.stopAllGenerations()

      var failureMessages: [String] = []
      do {
        try await accountManager.removeAllCredentials()
      } catch {
        failureMessages.append(error.localizedDescription)
      }

      do {
        try await mcpModel.deleteAllCredentials()
      } catch {
        failureMessages.append(error.localizedDescription)
      }

      await providersModel.reloadFromStorage()
      if !failureMessages.isEmpty {
        throw DataManagementError.combined(failureMessages.joined(separator: "\n\n"))
      }
    }
  }

  private func perform(
    _ success: String,
    operation: @MainActor () async throws -> Void
  ) async {
    guard !isBusy else { return }
    isBusy = true
    errorMessage = nil
    defer { isBusy = false }
    do {
      try await operation()
      statusMessage = success
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}
