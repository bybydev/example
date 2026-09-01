import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Metadata-only description of a stored blob. Lets list surfaces show name,
/// size, and type without loading any bytes (the HEAD-request analog).
public struct AttachmentBlobMetadata: Codable, Sendable, Equatable {
  public var filename: String
  public var mimeType: String
  public var byteCount: Int
  public var createdAt: Date

  public init(filename: String, mimeType: String, byteCount: Int, createdAt: Date) {
    self.filename = filename
    self.mimeType = mimeType
    self.byteCount = byteCount
    self.createdAt = createdAt
  }
}

public extension AttachmentBlobMetadata {
  /// Placeholder metadata for a blob whose index row was never written (older
  /// writes, crashes between blob and index). Size is unknown until read.
  static func unknown(mimeType: String = "application/octet-stream") -> Self {
    AttachmentBlobMetadata(filename: "", mimeType: mimeType, byteCount: 0, createdAt: .distantPast)
  }
}

/// Stores attachment byte payloads as individual files keyed by ID so
/// workspace JSON stays metadata-only (see `ConversationStore.persist`).
/// Reads are on demand — the "remote image" model: rows carry IDs and
/// metadata only, and bytes (originals or downsampled derivatives) are
/// fetched when a surface actually displays or sends them.
public protocol AttachmentBlobStoring: Sendable {
  /// Writes the payload unless the ID is already stored. Idempotent; safe to
  /// call on every persist. `metadata` is optional; when supplied it feeds
  /// the index so lists can describe the file without reading bytes.
  func writeIfAbsent(
    _ id: String,
    data: Data,
    metadata: AttachmentBlobMetadata?
  ) async throws
  /// Returns nil when no blob exists for the ID.
  func loadData(_ id: String) async throws -> Data?
  /// Index lookup without touching bytes. nil when the blob is not stored.
  func metadata(for id: String) async throws -> AttachmentBlobMetadata?
  /// Downsampled variant generated from the original on first request and
  /// persisted under the derived directory afterwards. nil when the original
  /// is missing or cannot be decoded as an image.
  func thumbnailData(_ id: String, maxPixelSize: CGFloat) async throws -> Data?
  func deleteIDs(_ ids: Set<String>) async throws
  func storedIDs() async throws -> Set<String>
}

public extension AttachmentBlobStoring {
  /// Back-compat overload for callers that have no metadata (tests, imports
  /// of byte-only payloads).
  func writeIfAbsent(_ id: String, data: Data) async throws {
    try await writeIfAbsent(id, data: data, metadata: nil)
  }
}

/// One shared index for the blob directory: id → metadata, written
/// atomically alongside blob mutations and rebuilt from the directory
/// listing when missing or unreadable. The directory stays authoritative —
/// the index is a cache, never trusted over what is on disk (the same rule
/// as the conversations index cache).
struct AttachmentBlobIndex: Codable, Sendable {
  var schemaVersion: Int = 1
  var entries: [String: AttachmentBlobMetadata] = [:]
}

private enum AttachmentBlobIndexSupport {
  static func decode(_ data: Data) -> AttachmentBlobIndex? {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(AttachmentBlobIndex.self, from: data)
  }

  static func encode(_ index: AttachmentBlobIndex) -> Data? {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return try? encoder.encode(index)
  }
}

public actor FileAttachmentBlobStore: AttachmentBlobStoring {
  static let derivedDirectoryName = "derived"
  static let indexFileName = "index.json"

  private let directory: URL
  private let fileManager: FileManager
  /// Lazily-seeded cache of what is on disk so repeated writes during stream
  /// persistence never stat the directory.
  private var knownIDs: Set<String>?
  private var index: AttachmentBlobIndex?

  public init(directory: URL, fileManager: FileManager = .default) {
    self.directory = directory
    self.fileManager = fileManager
  }

  public func writeIfAbsent(
    _ id: String,
    data: Data,
    metadata: AttachmentBlobMetadata?
  ) async throws {
    guard !data.isEmpty else { return }
    guard Self.isValidID(id) else {
      throw ProviderError.invalidRequest("Attachment blob ID is not usable as a file name.")
    }
    var known = knownIDs ?? Self.blobIDs(
      fromContents: (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
    )
    if known.contains(id) { return }

    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let target = url(for: id)
    if !fileManager.fileExists(atPath: target.path) {
      try data.write(to: target, options: .atomic)
    }
    known.insert(id)
    knownIDs = known

    // Index last: a crash between blob and index leaves the blob as an
    // orphan (cleaned by the sweep), never metadata pointing at nothing.
    if let metadata {
      updateIndex { $0.entries[id] = metadata }
    }
  }

  public func loadData(_ id: String) async throws -> Data? {
    guard Self.isValidID(id) else { return nil }
    guard fileManager.fileExists(atPath: url(for: id).path) else { return nil }
    return try Data(contentsOf: url(for: id), options: .mappedIfSafe)
  }

  public func metadata(for id: String) async throws -> AttachmentBlobMetadata? {
    guard Self.isValidID(id) else { return nil }
    guard try await storedIDs().contains(id) else { return nil }
    if let existing = currentIndex().entries[id], existing.byteCount > 0,
      !existing.filename.isEmpty
    {
      return existing
    }
    // Legacy blob written before the index existed, or a placeholder row
    // from an index rebuild: fill what we can from file attributes (never
    // reading the bytes) and persist it so later lookups are cheap.
    var filled = currentIndex().entries[id] ?? .unknown()
    if let attributes = try? fileManager.attributesOfItem(atPath: url(for: id).path) {
      if let size = attributes[.size] as? Int, size > 0 { filled.byteCount = size }
      if let created = attributes[.creationDate] as? Date { filled.createdAt = created }
    }
    updateIndex { $0.entries[id] = filled }
    return filled
  }

  public func thumbnailData(_ id: String, maxPixelSize: CGFloat) async throws -> Data? {
    guard Self.isValidID(id), maxPixelSize > 0 else { return nil }
    let clamped = Int(maxPixelSize.rounded(.up))
    let derivedURL = derivedURL(for: id, maxPixelSize: clamped)
    if let cached = try? Data(contentsOf: derivedURL, options: .mappedIfSafe), !cached.isEmpty {
      return cached
    }
    guard let original = try await loadData(id), !original.isEmpty else { return nil }
    guard let thumbnail = Self.downsampledThumbnail(from: original, maxPixelSize: CGFloat(clamped)) else {
      return nil
    }
    try? fileManager.createDirectory(at: derivedDirectory, withIntermediateDirectories: true)
    try? thumbnail.write(to: derivedURL, options: .atomic)
    return thumbnail
  }

  public func deleteIDs(_ ids: Set<String>) async throws {
    guard !ids.isEmpty else { return }
    let validIDs = Set(ids.filter(Self.isValidID))
    guard !validIDs.isEmpty else { return }

    for id in validIDs {
      try? fileManager.removeItem(at: url(for: id))
      knownIDs?.remove(id)
    }

    // Thumbnail files are named `<blob-id>-<pixel-size>`. Enumerate once so a
    // bulk orphan sweep remains O(files + deleted IDs), and parse the numeric
    // size suffix instead of using a raw prefix match (which could collide
    // with another imported ID that happens to start with the same text).
    let derivedNames = (try? fileManager.contentsOfDirectory(atPath: derivedDirectory.path)) ?? []
    for name in derivedNames {
      let ownerID = Self.derivedBlobID(from: name)
      let isLegacyExactName = validIDs.contains(name)
      guard isLegacyExactName || ownerID.map(validIDs.contains) == true else { continue }
      try? fileManager.removeItem(
        at: derivedDirectory.appendingPathComponent(name, isDirectory: false)
      )
    }

    updateIndex { index in
      for id in validIDs { index.entries.removeValue(forKey: id) }
    }
  }

  public func storedIDs() async throws -> Set<String> {
    if let knownIDs { return knownIDs }
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let contents = try fileManager.contentsOfDirectory(atPath: directory.path)
    let ids = Self.blobIDs(fromContents: contents)
    knownIDs = ids
    return ids
  }

  /// Directory contents minus the derived subdirectory and the index file,
  /// which live alongside the blobs but are not blobs.
  private static func blobIDs(fromContents contents: [String]) -> Set<String> {
    Set(contents.filter { $0 != derivedDirectoryName && $0 != indexFileName })
  }

  /// Rebuilds a missing/unreadable index from the directory listing. Sizes
  /// are unknown without reading each blob, so rows carry placeholder
  /// metadata; `metadata(for:)` fills real sizes from file attributes on
  /// demand. Invoked by the app once at startup.
  public func rebuildIndexIfMissing() async throws {
    guard currentIndex().entries.isEmpty else { return }
    let ids = try await storedIDs()
    guard !ids.isEmpty else { return }
    var rebuilt = AttachmentBlobIndex()
    let existing = index?.entries ?? [:]
    for id in ids {
      rebuilt.entries[id] = existing[id] ?? .unknown()
    }
    index = rebuilt
    persistIndex()
  }

  /// Backfills placeholder index rows with real file sizes (attributes, not
  /// byte reads). Safe to call repeatedly; only placeholder rows are touched.
  public func fillUnknownMetadata() async throws {
    let current = currentIndex()
    guard current.entries.contains(where: { $0.value.byteCount == 0 }) else { return }
    var updated = current
    for (id, entry) in updated.entries where entry.byteCount == 0 {
      guard let attributes = try? fileManager.attributesOfItem(atPath: url(for: id).path),
        let size = attributes[.size] as? Int, size > 0
      else { continue }
      updated.entries[id]?.byteCount = size
    }
    index = updated
    persistIndex()
  }

  // MARK: - Index

  private func currentIndex() -> AttachmentBlobIndex {
    if let index { return index }
    let loaded: AttachmentBlobIndex
    if let data = try? Data(contentsOf: indexURL),
      let decoded = AttachmentBlobIndexSupport.decode(data)
    {
      loaded = decoded
    } else {
      loaded = AttachmentBlobIndex()
    }
    index = loaded
    return loaded
  }

  private func updateIndex(_ mutation: (inout AttachmentBlobIndex) -> Void) {
    var value = currentIndex()
    mutation(&value)
    index = value
    persistIndex()
  }

  private func persistIndex() {
    guard let data = AttachmentBlobIndexSupport.encode(currentIndex()) else { return }
    try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    try? data.write(to: indexURL, options: .atomic)
  }

  // MARK: - Derived thumbnails

  /// ImageIO downsample so a 20 MB JPEG never materializes as a full-size
  /// bitmap just to fill a small tile. Output re-encodes as PNG to keep the
  /// derived file self-describing regardless of the source format.
  static func downsampledThumbnail(from data: Data, maxPixelSize: CGFloat) -> Data? {
    let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
      return nil
    }
    let thumbnailOptions = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
    ] as CFDictionary
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
      return nil
    }
    let outputData = NSMutableData()
    let output = CGImageDestinationCreateWithData(
      outputData,
      UTType.png.identifier as CFString,
      1,
      nil
    )
    guard let output else { return nil }
    CGImageDestinationAddImage(output, cgImage, nil)
    guard CGImageDestinationFinalize(output) else { return nil }
    return outputData as Data
  }

  private static func derivedBlobID(from fileName: String) -> String? {
    guard let separator = fileName.lastIndex(of: "-") else { return nil }
    let id = String(fileName[..<separator])
    let suffix = fileName[fileName.index(after: separator)...]
    guard !id.isEmpty, !suffix.isEmpty, suffix.allSatisfy({ $0.isNumber }), isValidID(id) else {
      return nil
    }
    return id
  }

  private func derivedURL(for id: String, maxPixelSize: Int) -> URL {
    derivedDirectory
      .appendingPathComponent("\(id)-\(maxPixelSize)", isDirectory: false)
  }

  private var derivedDirectory: URL {
    directory.appendingPathComponent(Self.derivedDirectoryName, isDirectory: true)
  }

  private var indexURL: URL {
    directory.appendingPathComponent(Self.indexFileName, isDirectory: false)
  }

  private func url(for id: String) -> URL {
    directory.appendingPathComponent(id, isDirectory: false)
  }

  /// Blob names are generated UUIDs. Imported payloads could carry hostile
  /// strings, so anything outside the lowercase-hex/dash alphabet (UUID
  /// lowercase format) never touches disk.
  private static func isValidID(_ id: String) -> Bool {
    !id.isEmpty && id.count <= 64 && id.allSatisfy { character in
      ("a"..."z").contains(character) || ("0"..."9").contains(character) || character == "-"
    }
  }
}

public actor InMemoryAttachmentBlobStore: AttachmentBlobStoring {
  private var blobs: [String: Data]
  private var metadataByID: [String: AttachmentBlobMetadata]

  public init(
    initial: [String: Data] = [:],
    initialMetadata: [String: AttachmentBlobMetadata] = [:]
  ) {
    blobs = initial
    metadataByID = initialMetadata
  }

  public func writeIfAbsent(
    _ id: String,
    data: Data,
    metadata: AttachmentBlobMetadata?
  ) async throws {
    guard !data.isEmpty else { return }
    if blobs[id] == nil {
      blobs[id] = data
      if let metadata { metadataByID[id] = metadata }
    }
  }

  public func loadData(_ id: String) async throws -> Data? {
    blobs[id]
  }

  public func metadata(for id: String) async throws -> AttachmentBlobMetadata? {
    guard blobs[id] != nil else { return nil }
    return metadataByID[id]
  }

  public func thumbnailData(_ id: String, maxPixelSize: CGFloat) async throws -> Data? {
    guard let original = blobs[id], !original.isEmpty else { return nil }
    return FileAttachmentBlobStore.downsampledThumbnail(from: original, maxPixelSize: maxPixelSize)
  }

  public func deleteIDs(_ ids: Set<String>) async throws {
    for id in ids {
      blobs.removeValue(forKey: id)
      metadataByID.removeValue(forKey: id)
    }
  }

  public func storedIDs() async throws -> Set<String> {
    Set(blobs.keys)
  }
}
