import Foundation

public enum BYOKStorageStoreKind: String, Sendable, CaseIterable {
  case providers
  case conversations
  case projects
  case mcp
  case library
}

public enum BYOKStorageMigrationError: LocalizedError, Sendable, Equatable {
  case invalidJSON(store: String)
  case invalidRoot(store: String)
  case invalidSchemaVersion(store: String)
  case newerVersion(store: String, stored: Int, supported: Int)
  case unavailableMigration(store: String, from: Int, to: Int)
  case invalidMigrationOutput(store: String, message: String)

  public var errorDescription: String? {
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

/// Shared bootstrap for versioned workspace files. Conversation shards own
/// their own per-shard compatibility/migration path in ConversationStore, so
/// they are intentionally not registered as a monolithic workspace here.
public enum BYOKStorageBootstrap {
  private struct StoreDescriptor: Sendable {
    let kind: BYOKStorageStoreKind
    let fileURL: URL
    let currentSchemaVersion: Int
  }

  public static func prepare(environment: BYOKStorageEnvironment) async throws {
    let root = environment.rootDirectory
    try await Task.detached(priority: .userInitiated) {
      try prepareSynchronously(root: root)
    }.value
  }

  /// Test hook for migration behavior without touching the filesystem.
  public static func migrateDataForTesting(
    _ data: Data,
    kind: BYOKStorageStoreKind,
    currentSchemaVersion: Int
  ) throws -> Data {
    try migratedDataIfNeeded(
      data,
      descriptor: StoreDescriptor(
        kind: kind,
        fileURL: URL(fileURLWithPath: "/test.json"),
        currentSchemaVersion: currentSchemaVersion
      )
    ) ?? data
  }

  private static func descriptors(layout: BYOKStorageLayout) -> [StoreDescriptor] {
    [
      StoreDescriptor(
        kind: .providers,
        fileURL: layout.providersFile,
        currentSchemaVersion: ProviderWorkspaceState.currentSchemaVersion
      ),
      StoreDescriptor(
        kind: .projects,
        fileURL: layout.projectsFile,
        currentSchemaVersion: ProjectWorkspaceState.currentSchemaVersion
      ),
      StoreDescriptor(
        kind: .mcp,
        fileURL: layout.mcpServersFile,
        currentSchemaVersion: MCPWorkspaceState.currentSchemaVersion
      ),
      StoreDescriptor(
        kind: .library,
        fileURL: layout.libraryFile,
        currentSchemaVersion: LibraryWorkspaceState.currentSchemaVersion
      ),
    ]
  }

  private static func prepareSynchronously(root: URL) throws {
    let fileManager = FileManager.default
    let layout = BYOKStorageLayout(rootDirectory: root)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

    var migrationBackupDirectory: URL?
    for descriptor in descriptors(layout: layout) {
      guard fileManager.fileExists(atPath: descriptor.fileURL.path) else { continue }
      let original = try Data(contentsOf: descriptor.fileURL, options: .mappedIfSafe)
      guard let migrated = try migratedDataIfNeeded(original, descriptor: descriptor) else {
        continue
      }

      try validate(
        data: migrated,
        kind: descriptor.kind,
        expectedSchemaVersion: descriptor.currentSchemaVersion
      )
      if migrationBackupDirectory == nil {
        migrationBackupDirectory = try newBackupDirectory(
          recoveryDirectory: layout.recoveryDirectory,
          group: "MigrationBackups"
        )
      }
      try original.write(
        to: migrationBackupDirectory!.appendingPathComponent(descriptor.fileURL.lastPathComponent),
        options: .atomic
      )
      try migrated.write(to: descriptor.fileURL, options: .atomic)
    }

    try pruneBackups(
      recoveryDirectory: layout.recoveryDirectory,
      directory: "MigrationBackups",
      keeping: 3
    )
  }

  private static func migratedDataIfNeeded(
    _ data: Data,
    descriptor: StoreDescriptor
  ) throws -> Data? {
    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: data)
    } catch {
      throw BYOKStorageMigrationError.invalidJSON(store: descriptor.kind.rawValue)
    }
    guard var root = object as? [String: Any] else {
      throw BYOKStorageMigrationError.invalidRoot(store: descriptor.kind.rawValue)
    }

    let storedVersion: Int
    if let raw = root["schemaVersion"] {
      guard let number = raw as? NSNumber else {
        throw BYOKStorageMigrationError.invalidSchemaVersion(store: descriptor.kind.rawValue)
      }
      storedVersion = number.intValue
    } else {
      storedVersion = 0
    }

    guard storedVersion <= descriptor.currentSchemaVersion else {
      throw BYOKStorageMigrationError.newerVersion(
        store: descriptor.kind.rawValue,
        stored: storedVersion,
        supported: descriptor.currentSchemaVersion
      )
    }
    guard storedVersion < descriptor.currentSchemaVersion else { return nil }

    var version = storedVersion
    while version < descriptor.currentSchemaVersion {
      root = try migrateOneStep(
        root,
        kind: descriptor.kind,
        from: version,
        to: version + 1
      )
      version += 1
    }

    let migrated = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    do {
      try validate(
        data: migrated,
        kind: descriptor.kind,
        expectedSchemaVersion: descriptor.currentSchemaVersion
      )
    } catch {
      throw BYOKStorageMigrationError.invalidMigrationOutput(
        store: descriptor.kind.rawValue,
        message: error.localizedDescription
      )
    }
    return migrated
  }

  private static func migrateOneStep(
    _ root: [String: Any],
    kind: BYOKStorageStoreKind,
    from: Int,
    to: Int
  ) throws -> [String: Any] {
    guard from == 0, to == 1 else {
      throw BYOKStorageMigrationError.unavailableMigration(
        store: kind.rawValue,
        from: from,
        to: to
      )
    }

    var value = root
    value["schemaVersion"] = 1
    switch kind {
    case .providers:
      if value["customProviders"] == nil { value["customProviders"] = [] }
      if value["accounts"] == nil { value["accounts"] = [] }
      if value["modelRecords"] == nil { value["modelRecords"] = [] }
      if value["providerDefaultAccountIDs"] == nil { value["providerDefaultAccountIDs"] = [:] }
      if value["tombstones"] == nil { value["tombstones"] = [:] }
    case .conversations:
      if value["conversations"] == nil { value["conversations"] = [] }
      if value["tombstones"] == nil { value["tombstones"] = [:] }
    case .projects:
      if value["projects"] == nil { value["projects"] = [] }
      if value["conversationProjectIDs"] == nil { value["conversationProjectIDs"] = [:] }
      if value["tombstones"] == nil { value["tombstones"] = [:] }
    case .mcp:
      if value["servers"] == nil { value["servers"] = [] }
      if value["snapshots"] == nil { value["snapshots"] = [] }
      if value["tombstones"] == nil { value["tombstones"] = [:] }
    case .library:
      if value["entries"] == nil { value["entries"] = [] }
      if value["tombstones"] == nil { value["tombstones"] = [:] }
    }
    return value
  }

  private static func validate(
    data: Data,
    kind: BYOKStorageStoreKind,
    expectedSchemaVersion: Int
  ) throws {
    switch kind {
    case .providers:
      let value = try JSONDecoder().decode(ProviderWorkspaceState.self, from: data)
      guard value.schemaVersion == expectedSchemaVersion else {
        throw BYOKStorageMigrationError.invalidSchemaVersion(store: kind.rawValue)
      }
      try WorkspaceImportValidator.validateProviderWorkspace(value)
    case .conversations:
      let value = try JSONDecoder().decode(ConversationWorkspaceState.self, from: data)
      guard value.schemaVersion == expectedSchemaVersion else {
        throw BYOKStorageMigrationError.invalidSchemaVersion(store: kind.rawValue)
      }
    case .projects:
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      let value = try decoder.decode(ProjectWorkspaceState.self, from: data)
      guard value.schemaVersion == expectedSchemaVersion else {
        throw BYOKStorageMigrationError.invalidSchemaVersion(store: kind.rawValue)
      }
    case .mcp:
      let value = try JSONDecoder().decode(MCPWorkspaceState.self, from: data)
      guard value.schemaVersion == expectedSchemaVersion else {
        throw BYOKStorageMigrationError.invalidSchemaVersion(store: kind.rawValue)
      }
      try MCPWorkspaceStore.validate(value)
    case .library:
      let value = try JSONDecoder().decode(LibraryWorkspaceState.self, from: data)
      guard value.schemaVersion == expectedSchemaVersion else {
        throw BYOKStorageMigrationError.invalidSchemaVersion(store: kind.rawValue)
      }
    }
  }

  private static func newBackupDirectory(
    recoveryDirectory: URL,
    group: String
  ) throws -> URL {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let safeDate = formatter.string(from: .now).replacingOccurrences(of: ":", with: "-")
    let directory = recoveryDirectory
      .appendingPathComponent(group, isDirectory: true)
      .appendingPathComponent("\(safeDate)-\(UUID().uuidString.lowercased())", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private static func pruneBackups(
    recoveryDirectory: URL,
    directory: String,
    keeping count: Int
  ) throws {
    let root = recoveryDirectory.appendingPathComponent(directory, isDirectory: true)
    guard FileManager.default.fileExists(atPath: root.path) else { return }
    let urls = try FileManager.default.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: [.skipsHiddenFiles]
    )
    let sorted = try urls.sorted {
      let lhs = try $0.resourceValues(forKeys: [.contentModificationDateKey])
        .contentModificationDate ?? .distantPast
      let rhs = try $1.resourceValues(forKeys: [.contentModificationDateKey])
        .contentModificationDate ?? .distantPast
      return lhs > rhs
    }
    for url in sorted.dropFirst(count) {
      try? FileManager.default.removeItem(at: url)
    }
  }
}
