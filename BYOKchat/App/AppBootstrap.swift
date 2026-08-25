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

  func start(model: AppModel) async {
    guard !didStart else { return }
    didStart = true

    do {
      state = .loading(.preparingStorage)
      try await AppStorageBootstrap.prepare()

      state = .loading(.loadingProviders)
      await model.providers.load()
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
      await model.projects.reconcile(conversations: model.chats.conversations)
      try Self.throwIfModelFailed(model.projects.errorMessage, stage: .reconciling)
      await model.mcp.reloadFromStorage()
      try Self.throwIfModelFailed(model.mcp.errorMessage, stage: .reconciling)

      // Self-healing GC pass: removes bytes orphaned by any missed decrement.
      await model.sweepOrphanFiles()

      state = .ready

      // iCloud is optional and can continue after the local app is usable.
      await model.projectSync.load()
    } catch {
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
    case .loadingProviders, .loadingProjects, .loadingTools, .loadingChats, .reconciling:
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

enum AppStorageMigrationError: LocalizedError, Sendable, Equatable {
  case invalidJSON(store: String)
  case invalidRoot(store: String)
  case invalidSchemaVersion(store: String)
  case newerVersion(store: String, stored: Int, supported: Int)
  case unavailableMigration(store: String, from: Int, to: Int)
  case invalidMigrationOutput(store: String, message: String)

  var errorDescription: String? {
    switch self {
    case .invalidJSON(let store):
      "The \(store) data file is not valid JSON."
    case .invalidRoot(let store):
      "The \(store) data file has an invalid structure."
    case .invalidSchemaVersion(let store):
      "The \(store) data file has an invalid schema version."
    case .newerVersion(let store, let stored, let supported):
      "The \(store) data was created by a newer version of BYOKchat (schema \(stored); this app supports \(supported))."
    case .unavailableMigration(let store, let from, let to):
      "BYOKchat cannot migrate \(store) data from schema \(from) to \(to)."
    case .invalidMigrationOutput(let store, let message):
      "The migrated \(store) data could not be validated: \(message)"
    }
  }
}

enum AppStorageBootstrap {
  enum StoreKind: String, Sendable, CaseIterable {
    case providers
    case conversations
    case projects
    case mcp
  }

  struct StoreDescriptor: Sendable {
    let kind: StoreKind
    let fileName: String
    let currentSchemaVersion: Int
  }

  static let stores: [StoreDescriptor] = [
    .init(kind: .providers, fileName: "providers-v1.json", currentSchemaVersion: ProviderWorkspaceState.currentSchemaVersion),
    // Conversations are sharded under conversations-v1/ and carry no monolith
    // migration; see ConversationShardPersistence.swift.
    .init(kind: .projects, fileName: "projects-v1.json", currentSchemaVersion: ProjectWorkspaceState.currentSchemaVersion),
    .init(kind: .mcp, fileName: "mcp-servers-v1.json", currentSchemaVersion: MCPWorkspaceState.currentSchemaVersion),
  ]

  static func prepare() async throws {
    try await Task.detached(priority: .userInitiated) {
      try prepareSynchronously(root: applicationSupportDirectory())
    }.value
  }

  static func makeRecoveryDocument(failure: AppBootstrapFailure) async throws -> AppRecoveryPackageDocument {
    let diagnostics = failure.diagnosticText
    let files = try await Task.detached(priority: .userInitiated) {
      try recoveryFiles(root: applicationSupportDirectory(), diagnostics: diagnostics)
    }.value
    return AppRecoveryPackageDocument(files: files)
  }

  static func resetLocalData() async throws {
    let root = applicationSupportDirectory()
    try await Task.detached(priority: .userInitiated) {
      try createResetBackup(root: root)
      try removeLocalFiles(root: root)
    }.value

    #if canImport(Security)
      try await KeychainCredentialVault().removeAllSecrets()
      try await KeychainMCPCredentialVault().removeAllCredentials()
    #endif

    await TelemetryRecorder.shared.clearAllTelemetry()
    let defaults = UserDefaults.standard
    defaults.set(false, forKey: "byokchat.projectSync.enabled.v1")
    defaults.set(false, forKey: "byokchat.onboarding.completed.v1")
  }

  static func migrateDataForTesting(
    _ data: Data,
    kind: StoreKind,
    currentSchemaVersion: Int
  ) throws -> Data {
    try migratedDataIfNeeded(
      data,
      descriptor: .init(kind: kind, fileName: "test.json", currentSchemaVersion: currentSchemaVersion)
    ) ?? data
  }

  private static func prepareSynchronously(root: URL) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

    var migrationBackupDirectory: URL?
    for descriptor in stores {
      let fileURL = root.appendingPathComponent(descriptor.fileName)
      guard fileManager.fileExists(atPath: fileURL.path) else { continue }
      let original = try Data(contentsOf: fileURL, options: .mappedIfSafe)
      guard let migrated = try migratedDataIfNeeded(original, descriptor: descriptor) else { continue }

      try validate(data: migrated, kind: descriptor.kind, expectedSchemaVersion: descriptor.currentSchemaVersion)
      if migrationBackupDirectory == nil {
        migrationBackupDirectory = try newBackupDirectory(root: root, group: "MigrationBackups")
      }
      try original.write(
        to: migrationBackupDirectory!.appendingPathComponent(descriptor.fileName),
        options: .atomic
      )
      try migrated.write(to: fileURL, options: .atomic)
    }
    try pruneBackups(root: root, directory: "MigrationBackups", keeping: 3)
  }

  private static func migratedDataIfNeeded(
    _ data: Data,
    descriptor: StoreDescriptor
  ) throws -> Data? {
    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: data)
    } catch {
      throw AppStorageMigrationError.invalidJSON(store: descriptor.kind.rawValue)
    }
    guard var root = object as? [String: Any] else {
      throw AppStorageMigrationError.invalidRoot(store: descriptor.kind.rawValue)
    }

    let storedVersion: Int
    if let raw = root["schemaVersion"] {
      if let number = raw as? NSNumber {
        storedVersion = number.intValue
      } else {
        throw AppStorageMigrationError.invalidSchemaVersion(store: descriptor.kind.rawValue)
      }
    } else {
      storedVersion = 0
    }

    guard storedVersion <= descriptor.currentSchemaVersion else {
      throw AppStorageMigrationError.newerVersion(
        store: descriptor.kind.rawValue,
        stored: storedVersion,
        supported: descriptor.currentSchemaVersion
      )
    }
    guard storedVersion < descriptor.currentSchemaVersion else { return nil }

    var version = storedVersion
    while version < descriptor.currentSchemaVersion {
      root = try migrateOneStep(root, kind: descriptor.kind, from: version, to: version + 1)
      version += 1
    }

    let migrated = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    do {
      try validate(data: migrated, kind: descriptor.kind, expectedSchemaVersion: descriptor.currentSchemaVersion)
    } catch {
      throw AppStorageMigrationError.invalidMigrationOutput(
        store: descriptor.kind.rawValue,
        message: error.localizedDescription
      )
    }
    return migrated
  }

  private static func migrateOneStep(
    _ root: [String: Any],
    kind: StoreKind,
    from: Int,
    to: Int
  ) throws -> [String: Any] {
    guard from == 0, to == 1 else {
      throw AppStorageMigrationError.unavailableMigration(store: kind.rawValue, from: from, to: to)
    }

    var value = root
    value["schemaVersion"] = 1
    switch kind {
    case .providers:
      if value["customProviders"] == nil { value["customProviders"] = [] }
      if value["accounts"] == nil { value["accounts"] = [] }
      if value["modelRecords"] == nil { value["modelRecords"] = [] }
      if value["providerDefaultAccountIDs"] == nil { value["providerDefaultAccountIDs"] = [:] }
    case .conversations:
      if value["conversations"] == nil { value["conversations"] = [] }
    case .projects:
      if value["projects"] == nil { value["projects"] = [] }
      if value["conversationProjectIDs"] == nil { value["conversationProjectIDs"] = [:] }
    case .mcp:
      if value["servers"] == nil { value["servers"] = [] }
      if value["snapshots"] == nil { value["snapshots"] = [] }
    }
    return value
  }

  private static func validate(data: Data, kind: StoreKind, expectedSchemaVersion: Int) throws {
    switch kind {
    case .providers:
      let value = try JSONDecoder().decode(ProviderWorkspaceState.self, from: data)
      guard value.schemaVersion == expectedSchemaVersion else {
        throw AppStorageMigrationError.invalidSchemaVersion(store: kind.rawValue)
      }
      try WorkspaceImportValidator.validateProviderWorkspace(value)
    case .conversations:
      let value = try JSONDecoder().decode(ConversationWorkspaceState.self, from: data)
      guard value.schemaVersion == expectedSchemaVersion else {
        throw AppStorageMigrationError.invalidSchemaVersion(store: kind.rawValue)
      }
    case .projects:
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      let value = try decoder.decode(ProjectWorkspaceState.self, from: data)
      guard value.schemaVersion == expectedSchemaVersion else {
        throw AppStorageMigrationError.invalidSchemaVersion(store: kind.rawValue)
      }
    case .mcp:
      let value = try JSONDecoder().decode(MCPWorkspaceState.self, from: data)
      guard value.schemaVersion == expectedSchemaVersion else {
        throw AppStorageMigrationError.invalidSchemaVersion(store: kind.rawValue)
      }
      try MCPWorkspaceStore.validate(value)
    }
  }

  private static func applicationSupportDirectory(fileManager: FileManager = .default) -> URL {
    let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.temporaryDirectory
    return base.appendingPathComponent("BYOKchat", isDirectory: true)
  }

  private static func recoveryDirectory(root: URL) -> URL {
    root.appendingPathComponent("Recovery", isDirectory: true)
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
    stores.map { root.appendingPathComponent($0.fileName) }
      + [
        root.appendingPathComponent("project-sync-local-v1.json"),
        root.appendingPathComponent("library-v1.json"),
        // Pre-sharding conversations file; kept so resets on older installs
        // still clean it up.
        root.appendingPathComponent("conversations-v1.json"),
      ]
  }

  /// Byte payloads live in shared per-store directories next to the JSON
  /// workspaces. `files-v1` holds all file bytes (chat attachments, library
  /// entries, project reference files); the other two are pre-unification
  /// locations kept so resets on older installs still clean them up.
  private static func blobDirectoryURLs(root: URL) -> [URL] {
    [
      root.appendingPathComponent("files-v1", isDirectory: true),
      root.appendingPathComponent("attachments-v1", isDirectory: true),
      root.appendingPathComponent("library-v1", isDirectory: true),
      root.appendingPathComponent("conversations-v1", isDirectory: true),
    ]
  }

  private static func removeLocalFiles(root: URL) throws {
    let fileManager = FileManager.default
    for url in localDataURLs(root: root) where fileManager.fileExists(atPath: url.path) {
      try fileManager.removeItem(at: url)
    }
    for directory in blobDirectoryURLs(root: root)
    where fileManager.fileExists(atPath: directory.path) {
      try fileManager.removeItem(at: directory)
    }
  }

  private static func recoveryFiles(root: URL, diagnostics: String) throws -> [String: Data] {
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

    let telemetry = TelemetryRecorder.defaultDatabaseURL()
    for url in [telemetry, URL(fileURLWithPath: telemetry.path + "-wal"), URL(fileURLWithPath: telemetry.path + "-shm")]
      where fileManager.fileExists(atPath: url.path)
    {
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
