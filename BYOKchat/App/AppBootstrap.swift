import BYOKchatProviderCore
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppBootstrapController {
  private(set) var state: AppBootstrapState = .loading(.preparingStorage)
  private var didStart = false

  func start(
    model: AppModel,
    selectInitialConversation: @MainActor (ConversationID?) -> Void = { _ in }
  ) async {
    guard !didStart else { return }
    didStart = true

    if let failure = model.startupCompositionFailure {
      state = .failed(failure)
      return
    }

    do {
      state = .loading(.preparingStorage)
      #if DEBUG
      if let seedConfig = BYOKSeedLaunchOptions.consumePendingLaunchSeed() {
        try await BYOKSeedDataService.seedStorage(
          seedConfig,
          environment: model.storageEnvironment,
          telemetryRecorder: model.telemetryRecorder
        )
      }
      #endif
      try await AppStorageBootstrap.prepare(environment: model.storageEnvironment)

      // Index first: stores read blob metadata (sizes) during their loads.
      // Both steps are best-effort self-healing; a failure just leaves the
      // index as-is for on-demand repair.
      try await model.fileBlobStore.rebuildIndexIfMissing()
      try await model.fileBlobStore.fillUnknownMetadata()

      state = .loading(.loadingProviders)
      await model.providers.load()
      if model.providers.errorMessage != nil {
        BYOKAppAnalytics.reportError("provider_load_failed", component: "provider")
      }
      try Self.throwIfModelFailed(model.providers.errorMessage, stage: .loadingProviders)

      state = .loading(.loadingProjects)
      await model.projects.load()
      try Self.throwIfModelFailed(model.projects.errorMessage, stage: .loadingProjects)

      state = .loading(.loadingTools)
      await model.mcp.load()
      try Self.throwIfModelFailed(model.mcp.errorMessage, stage: .loadingTools)

      state = .loading(.loadingChats)
      await model.chats.load()
      try Self.throwIfModelFailed(model.chats.errorMessage, stage: .loadingChats)

      await model.library.load()
      try Self.throwIfModelFailed(model.library.errorMessage, stage: .loadingChats)

      state = .loading(.reconciling)
      // Stores are fully loaded. Only records explicitly owned by the iOS
      // new-chat lifecycle are eligible; persisted user messages always survive.
      await model.chats.recoverUnsentNewChats()
      try Self.throwIfModelFailed(model.chats.errorMessage, stage: .reconciling)
      await model.projects.reconcile(conversations: model.chats.conversations)
      try Self.throwIfModelFailed(model.projects.errorMessage, stage: .reconciling)
      await model.mcp.reloadFromStorage()
      try Self.throwIfModelFailed(model.mcp.errorMessage, stage: .reconciling)

      // Sweep only at startup, after all reference-owning stores have loaded
      // and before chat preparation or interactive file writes can begin.
      // Live saves may have blobs whose references have not committed yet.
      await model.sweepOrphanFilesAtStartup()

      state = .loading(.preparingChat)
      var initialConversationID: ConversationID?
      if let account = model.providers.resolvedDefaultAccount, model.providers.isReady(account) {
        guard let id = await model.chats.newChat(projectID: nil) else {
          throw AppBootstrapError.modelLoad(
            stage: .preparingChat,
            message: model.chats.errorMessage ?? "Could not open a new chat. Please try again."
          )
        }
        initialConversationID = id
      }
      // Commit the root destination before publishing ready. The main view
      // must never render a setup/open-chat fallback for a usable connection.
      selectInitialConversation(initialConversationID)
      state = .ready
      // Refresh Layer 2 remote model catalog asynchronously after startup so
      // offline launches and slow networks never delay reaching .ready.
      Task(priority: .utility) { @MainActor in
        await model.providers.refreshModelCatalogIfNeeded()
      }
    } catch {
      if case .preparingStorage = currentStage {
        BYOKAppAnalytics.reportError(
          "local_store_open_failed", component: "storage", severity: .fatal
        )
      } else {
        BYOKAppAnalytics.reportError(
          "workspace_recovery_failed", component: "startup", severity: .fatal
        )
      }
      state = .failed(AppBootstrapFailure(stage: currentStage, error: error))
    }
  }

  private var currentStage: AppBootstrapStage {
    if case .loading(let stage) = state { return stage }
    return .preparingStorage
  }

  private static func throwIfModelFailed(_ message: String?, stage: AppBootstrapStage) throws {
    guard let message else { return }
    throw AppBootstrapError.modelLoad(stage: stage, message: message)
  }
}

enum AppBootstrapStage: String, Sendable {
  case preparingStorage = "Preparing local data"
  case loadingProviders = "Loading connections"
  case loadingProjects = "Loading projects"
  case loadingTools = "Loading tools"
  case loadingChats = "Loading chats"
  case reconciling = "Checking references"
  case preparingChat = "Preparing chat"
}

enum AppBootstrapState: Sendable {
  case loading(AppBootstrapStage)
  case ready
  case failed(AppBootstrapFailure)
}

struct AppBootstrapFailure: Sendable, Equatable {
  let stage: AppBootstrapStage
  let message: String
  let details: String
  let occurredAt: Date

  init(stage: AppBootstrapStage, error: any Error, occurredAt: Date = .now) {
    self.stage = stage
    message = error.localizedDescription
    details = String(describing: error)
    self.occurredAt = occurredAt
  }

  var title: String {
    switch stage {
    case .preparingStorage:
      "Couldn't Prepare Your Data"
    case .loadingProviders, .loadingProjects, .loadingTools, .loadingChats, .reconciling, .preparingChat:
      "Couldn't Start BYOKchat"
    }
  }

  var diagnosticText: String {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    return """
    BYOKchat startup failure
    App version: \(version) (\(build))
    Stage: \(stage.rawValue)
    Date: \(occurredAt.ISO8601Format())
    Message: \(message)
    Details: \(details)
    """
  }
}

enum AppBootstrapError: LocalizedError, Sendable, Equatable {
  case modelLoad(stage: AppBootstrapStage, message: String)

  var errorDescription: String? {
    switch self {
    case .modelLoad(_, let message): message
    }
  }
}

enum BYOKBrand {
  static let backgroundAssetName = "BrandBackground"
  static var background: Color { Color(backgroundAssetName) }
}

struct AppRecoveryPackageDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.package] }

  var files: [String: Data]

  init(files: [String: Data]) {
    self.files = files
  }

  init(configuration: ReadConfiguration) throws {
    files = [:]
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    var wrappers: [String: FileWrapper] = [:]
    for (name, data) in files {
      wrappers[name] = FileWrapper(regularFileWithContents: data)
    }
    return FileWrapper(directoryWithFileWrappers: wrappers)
  }
}

typealias AppStorageMigrationError = BYOKStorageMigrationError

enum AppStorageBootstrap {
  typealias StoreKind = BYOKStorageStoreKind

  static func prepare(environment: BYOKStorageEnvironment = AppStorageEnvironment.current) async throws {
    try await BYOKStorageBootstrap.prepare(environment: environment)
  }

  static func makeRecoveryDocument(
    failure: AppBootstrapFailure,
    environment: BYOKStorageEnvironment = AppStorageEnvironment.current
  ) async throws -> AppRecoveryPackageDocument {
    let diagnostics = failure.diagnosticText
    let root = environment.rootDirectory
    let telemetryDatabaseURL = environment.telemetryDatabaseURL
    let files = try await Task.detached(priority: .userInitiated) {
      try recoveryFiles(
        root: root,
        diagnostics: diagnostics,
        telemetryDatabaseURL: telemetryDatabaseURL
      )
    }.value
    return AppRecoveryPackageDocument(files: files)
  }

  static func resetLocalData(
    environment: BYOKStorageEnvironment = AppStorageEnvironment.current,
    telemetryRecorder: TelemetryRecorder? = nil,
    createBackup: Bool = true
  ) async throws {
    let root = environment.rootDirectory
    try await Task.detached(priority: .userInitiated) {
      if createBackup {
        try createResetBackup(root: root)
      }
      try removeLocalFiles(root: root)
    }.value

    #if canImport(Security)
      try await KeychainCredentialVault(service: environment.credentialService).removeAllSecrets()
      try await KeychainMCPCredentialVault(service: environment.mcpCredentialService).removeAllCredentials()
    #endif

    let recorder = telemetryRecorder ?? environment.makeTelemetryRecorder()
    await recorder.clearAllTelemetry()
    let defaults = environment.makeUserDefaults()
    defaults.set(false, forKey: "byokchat.onboarding.completed.v1")
    SidebarPinStore.clear(in: defaults)
    ModelCatalogRegistry.resetToBundled()
  }

  static func migrateDataForTesting(
    _ data: Data,
    kind: StoreKind,
    currentSchemaVersion: Int
  ) throws -> Data {
    try BYOKStorageBootstrap.migrateDataForTesting(
      data,
      kind: kind,
      currentSchemaVersion: currentSchemaVersion
    )
  }

  private static func recoveryDirectory(root: URL) -> URL {
    BYOKStorageLayout(rootDirectory: root).recoveryDirectory
  }

  private static func createResetBackup(root: URL) throws {
    let fileManager = FileManager.default
    let existing = localDataURLs(root: root).filter { fileManager.fileExists(atPath: $0.path) }
    let blobDirectories = blobDirectoryURLs(root: root)
      .filter { fileManager.fileExists(atPath: $0.path) }
      .flatMap { directory -> [URL] in
        (try? fileManager.contentsOfDirectory(
          at: directory,
          includingPropertiesForKeys: [.isRegularFileKey]
        ))?.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
          ?? []
      }
    guard !existing.isEmpty || !blobDirectories.isEmpty else { return }
    let directory = try newBackupDirectory(root: root, group: "ResetBackups")
    for url in existing {
      try fileManager.copyItem(at: url, to: directory.appendingPathComponent(url.lastPathComponent))
    }
    for url in blobDirectories {
      try fileManager.copyItem(at: url, to: directory.appendingPathComponent("blob--\(url.lastPathComponent)"))
    }
    try pruneBackups(root: root, directory: "ResetBackups", keeping: 3)
  }

  private static func newBackupDirectory(root: URL, group: String) throws -> URL {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let safeDate = formatter.string(from: .now).replacingOccurrences(of: ":", with: "-")
    let directory = recoveryDirectory(root: root)
      .appendingPathComponent(group, isDirectory: true)
      .appendingPathComponent("\(safeDate)-\(UUID().uuidString.lowercased())", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private static func pruneBackups(root: URL, directory: String, keeping count: Int) throws {
    let root = recoveryDirectory(root: root).appendingPathComponent(directory, isDirectory: true)
    guard FileManager.default.fileExists(atPath: root.path) else { return }
    let urls = try FileManager.default.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: [.skipsHiddenFiles]
    )
    let sorted = try urls.sorted {
      let lhs = try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
      let rhs = try $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
      return lhs > rhs
    }
    for url in sorted.dropFirst(count) {
      try? FileManager.default.removeItem(at: url)
    }
  }

  private static func localDataURLs(root: URL) -> [URL] {
    let layout = BYOKStorageLayout(rootDirectory: root)
    return [
      layout.providersFile,
      layout.modelCatalogFile,
      layout.modelCatalogMetadataFile,
      layout.projectsFile,
      layout.mcpServersFile,
      layout.libraryFile,
      // Legacy iCloud project-sync state; kept so resets on installs that
      // used sync still clean it up.
      root.appendingPathComponent("project-sync-local-v1.json"),
      // Pre-sharding conversations file; kept so resets on older installs
      // still clean it up.
      root.appendingPathComponent("conversations-v1.json"),
    ]
  }

  /// Byte payloads and conversation shards live in directories next to the
  /// JSON workspaces. The legacy directories remain here only for reset and
  /// recovery compatibility with older installs.
  private static func blobDirectoryURLs(root: URL) -> [URL] {
    let layout = BYOKStorageLayout(rootDirectory: root)
    return [
      layout.filesDirectory,
      root.appendingPathComponent("attachments-v1", isDirectory: true),
      root.appendingPathComponent("library-v1", isDirectory: true),
      layout.conversationsDirectory,
    ]
  }

  private static func removeLocalFiles(root: URL) throws {
    let fileManager = FileManager.default
    let layout = BYOKStorageLayout(rootDirectory: root)
    for url in localDataURLs(root: root) where fileManager.fileExists(atPath: url.path) {
      try fileManager.removeItem(at: url)
    }
    for directory in blobDirectoryURLs(root: root)
    where fileManager.fileExists(atPath: directory.path) {
      try fileManager.removeItem(at: directory)
    }
    if fileManager.fileExists(atPath: layout.searchDirectory.path) {
      try fileManager.removeItem(at: layout.searchDirectory)
    }
  }

  private static func recoveryFiles(
    root: URL,
    diagnostics: String,
    telemetryDatabaseURL: URL
  ) throws -> [String: Data] {
    let fileManager = FileManager.default
    var result: [String: Data] = [
      "diagnostics.txt": Data(diagnostics.utf8),
      "README.txt": Data(
        """
        BYOKchat Recovery Data

        This package contains local configuration/data files and startup diagnostics to help recover from a failed launch.
        API keys and MCP credentials are stored separately in Keychain and are never included in this package.
        """.utf8
      ),
    ]

    for url in localDataURLs(root: root) where fileManager.fileExists(atPath: url.path) {
      result[url.lastPathComponent] = try Data(contentsOf: url, options: .mappedIfSafe)
    }

    // Blob payloads carry the actual attachment/library bytes; without them a
    // post-migration recovery package could not restore chat images.
    for directory in blobDirectoryURLs(root: root) {
      let contents = (try? fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey]
      )) ?? []
      for url in contents
      where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
        result["blobs--\(directory.lastPathComponent)--\(url.lastPathComponent)"] =
          try? Data(contentsOf: url, options: .mappedIfSafe)
      }
    }

    for url in [
      telemetryDatabaseURL,
      URL(fileURLWithPath: telemetryDatabaseURL.path + "-wal"),
      URL(fileURLWithPath: telemetryDatabaseURL.path + "-shm"),
    ] where fileManager.fileExists(atPath: url.path) {
      result["telemetry--\(url.lastPathComponent)"] = try Data(contentsOf: url, options: .mappedIfSafe)
    }

    let recovery = recoveryDirectory(root: root)
    if fileManager.fileExists(atPath: recovery.path) {
      if let enumerator = fileManager.enumerator(
        at: recovery,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      ) {
        for case let url as URL in enumerator {
          guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
          let relative = url.path.replacingOccurrences(of: recovery.path + "/", with: "")
          let safe = relative.replacingOccurrences(of: "/", with: "--")
          result["backup--\(safe)"] = try Data(contentsOf: url, options: .mappedIfSafe)
        }
      }
    }
    return result
  }
}
