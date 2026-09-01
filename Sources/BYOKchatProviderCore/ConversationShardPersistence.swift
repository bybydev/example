import Foundation

/// Persistence for the sharded conversation layout: a dedicated directory
/// holding one file per conversation plus a lightweight startup index.
///
/// - Shard files are named `<conversationID>.json` and hold one versioned
///   `ConversationShardRecord` (attachment bytes excluded; blob files carry them).
/// - `index.json` is the startup/list catalog. Full message history is loaded
///   from a shard only when a feature actually needs that conversation.
public protocol ConversationWorkspacePersistence: Sendable {
  func loadIndex() async throws -> Data?
  func saveIndex(_ data: Data) async throws
  func shardIDs() async throws -> [String]
  func loadShard(id: String) async throws -> Data?
  func saveShard(id: String, data: Data) async throws
  func deleteShard(id: String) async throws
  func deleteAllShards() async throws
  /// Moves a genuinely unreadable shard aside so one bad conversation cannot
  /// break the workspace. Unsupported/newer formats must never be quarantined.
  func quarantineShard(id: String) async throws -> Bool
}

public actor InMemoryConversationWorkspacePersistence: ConversationWorkspacePersistence {
  private var index: Data?
  private var shards: [String: Data]
  private var quarantined: [String: Data] = [:]
  private var shardReadCount = 0

  public init() { shards = [:] }

  /// Seeds shards directly, e.g. to exercise decoding of hand-written JSON.
  public init(shards: [String: Data]) {
    self.shards = shards
  }

  public func loadIndex() -> Data? { index }
  public func saveIndex(_ data: Data) { index = data }
  public func shardIDs() -> [String] { Array(shards.keys).sorted() }
  public func loadShard(id: String) -> Data? {
    shardReadCount += 1
    return shards[id]
  }
  public func saveShard(id: String, data: Data) { shards[id] = data }
  public func deleteShard(id: String) { shards.removeValue(forKey: id) }
  public func deleteAllShards() { shards.removeAll() }
  public func quarantineShard(id: String) -> Bool {
    guard let data = shards.removeValue(forKey: id) else { return false }
    quarantined[id] = data
    return true
  }

  /// Test/diagnostic hook proving normal startup did not read full shards.
  public func shardLoadCount() -> Int { shardReadCount }
}

public actor JSONFileConversationWorkspacePersistence: ConversationWorkspacePersistence {
  public let directory: URL

  private static let indexFileName = "index.json"

  private var indexURL: URL { directory.appendingPathComponent(Self.indexFileName) }

  public init(directory: URL) { self.directory = directory }

  private func shardURL(id: String) -> URL {
    directory.appendingPathComponent("\(id).json")
  }

  private func ensureDirectory() throws {
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
  }

  public func loadIndex() throws -> Data? {
    guard FileManager.default.fileExists(atPath: indexURL.path) else { return nil }
    return try Data(contentsOf: indexURL)
  }

  public func saveIndex(_ data: Data) throws {
    try ensureDirectory()
    try data.write(to: indexURL, options: .atomic)
  }

  public func shardIDs() throws -> [String] {
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    let contents = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey]
    )
    return contents.compactMap { url -> String? in
      guard url.pathExtension == "json", url.lastPathComponent != Self.indexFileName else {
        return nil
      }
      return url.deletingPathExtension().lastPathComponent
    }.sorted()
  }

  public func loadShard(id: String) throws -> Data? {
    let url = shardURL(id: id)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try Data(contentsOf: url)
  }

  public func saveShard(id: String, data: Data) throws {
    try ensureDirectory()
    try data.write(to: shardURL(id: id), options: .atomic)
  }

  public func deleteShard(id: String) throws {
    let url = shardURL(id: id)
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    try FileManager.default.removeItem(at: url)
  }

  public func deleteAllShards() throws {
    for id in try shardIDs() {
      try deleteShard(id: id)
    }
    if FileManager.default.fileExists(atPath: indexURL.path) {
      try FileManager.default.removeItem(at: indexURL)
    }
  }

  public func quarantineShard(id: String) throws -> Bool {
    let url = shardURL(id: id)
    guard FileManager.default.fileExists(atPath: url.path) else { return false }
    let destination = directory.appendingPathComponent("\(id).json.corrupt")
    if FileManager.default.fileExists(atPath: destination.path) {
      try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.moveItem(at: url, to: destination)
    return true
  }
}
