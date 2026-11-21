import Foundation

/// Host-provided storage policy. App targets decide where their sandbox data
/// lives and which local namespaces they use; shared persistence code decides
/// the canonical layout and file formats below that root.
public struct BYOKStorageEnvironment: Sendable, Equatable {
  public var rootDirectory: URL
  public var userDefaultsSuiteName: String?
  public var credentialService: String
  public var mcpCredentialService: String
  public var telemetryDirectory: URL

  public init(
    rootDirectory: URL,
    userDefaultsSuiteName: String? = nil,
    credentialService: String,
    mcpCredentialService: String,
    telemetryDirectory: URL
  ) {
    self.rootDirectory = rootDirectory
    self.userDefaultsSuiteName = userDefaultsSuiteName
    self.credentialService = credentialService
    self.mcpCredentialService = mcpCredentialService
    self.telemetryDirectory = telemetryDirectory
  }

  public var layout: BYOKStorageLayout {
    BYOKStorageLayout(rootDirectory: rootDirectory)
  }

  public var telemetryDatabaseURL: URL {
    telemetryDirectory.appendingPathComponent("telemetry.sqlite", isDirectory: false)
  }

  public func makeUserDefaults() -> UserDefaults {
    guard let userDefaultsSuiteName, !userDefaultsSuiteName.isEmpty else {
      return .standard
    }
    return UserDefaults(suiteName: userDefaultsSuiteName) ?? .standard
  }

  /// Creates the telemetry recorder for this host environment. App targets
  /// should create one recorder during composition and inject that instance
  /// into runtimes and UI instead of relying on Bundle.main-derived defaults.
  public func makeTelemetryRecorder(
    configuration: TelemetryStoreConfiguration = .default,
    sessionID: String = UUID().uuidString.lowercased()
  ) -> TelemetryRecorder {
    TelemetryRecorder(
      databaseURL: telemetryDatabaseURL,
      configuration: configuration,
      deviceID: TelemetryRecorder.loadOrCreateDeviceID(defaults: makeUserDefaults()),
      sessionID: sessionID
    )
  }
}

/// Canonical on-disk layout shared by every BYOK app target. Targets must not
/// duplicate these filenames when constructing stores.
public struct BYOKStorageLayout: Sendable, Equatable {
  public static let providersFileName = "providers-v1.json"
  public static let conversationsDirectoryName = "conversations-v1"
  public static let libraryFileName = "library-v1.json"
  public static let projectsFileName = "projects-v1.json"
  public static let mcpServersFileName = "mcp-servers-v1.json"
  public static let filesDirectoryName = "files-v1"
  public static let recoveryDirectoryName = "Recovery"

  public var rootDirectory: URL

  public init(rootDirectory: URL) {
    self.rootDirectory = rootDirectory
  }

  public var providersFile: URL {
    rootDirectory.appendingPathComponent(Self.providersFileName, isDirectory: false)
  }

  public var conversationsDirectory: URL {
    rootDirectory.appendingPathComponent(Self.conversationsDirectoryName, isDirectory: true)
  }

  public var libraryFile: URL {
    rootDirectory.appendingPathComponent(Self.libraryFileName, isDirectory: false)
  }

  public var projectsFile: URL {
    rootDirectory.appendingPathComponent(Self.projectsFileName, isDirectory: false)
  }

  public var mcpServersFile: URL {
    rootDirectory.appendingPathComponent(Self.mcpServersFileName, isDirectory: false)
  }

  public var filesDirectory: URL {
    rootDirectory.appendingPathComponent(Self.filesDirectoryName, isDirectory: true)
  }

  public var recoveryDirectory: URL {
    rootDirectory.appendingPathComponent(Self.recoveryDirectoryName, isDirectory: true)
  }

  public var derivedThumbnailsDirectory: URL {
    filesDirectory.appendingPathComponent("derived", isDirectory: true)
  }

  /// Computes a local disk-usage breakdown across chat shards, attachment blobs,
  /// regenerable thumbnails, telemetry SQLite files, and remaining metadata.
  public func measureUsage(
    telemetryDirectory: URL,
    fileManager: FileManager = .default
  ) -> BYOKStorageUsageReport {
    var conversationsBytes: Int64 = 0
    var quarantinedBytes: Int64 = 0
    var quarantinedCount = 0

    if let items = try? fileManager.contentsOfDirectory(
      at: conversationsDirectory,
      includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey]
    ) {
      for url in items {
        let size = Self.fileSize(at: url)
        if url.lastPathComponent.hasSuffix(".json.corrupt") {
          quarantinedBytes += size
          quarantinedCount += 1
        } else {
          conversationsBytes += size
        }
      }
    }

    let thumbnailCacheBytes = Self.directorySize(at: derivedThumbnailsDirectory, fileManager: fileManager)
    let totalFilesBytes = Self.directorySize(at: filesDirectory, fileManager: fileManager)
    let attachmentsBytes = max(0, totalFilesBytes - thumbnailCacheBytes)

    let analyticsBytes = Self.directorySize(at: telemetryDirectory, fileManager: fileManager)

    let metadataURLs = [
      providersFile,
      libraryFile,
      projectsFile,
      mcpServersFile,
    ]
    var otherBytes: Int64 = metadataURLs.reduce(0) { $0 + Self.fileSize(at: $1) }
    otherBytes += Self.directorySize(at: recoveryDirectory, fileManager: fileManager)
    otherBytes += Self.directorySize(
      at: rootDirectory.appendingPathComponent("ResetBackups", isDirectory: true),
      fileManager: fileManager
    )

    let availableDeviceBytes: Int64? = {
      let target = fileManager.fileExists(atPath: rootDirectory.path)
        ? rootDirectory
        : rootDirectory.deletingLastPathComponent()
      let values = try? target.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
      return values?.volumeAvailableCapacityForImportantUsage
    }()

    return BYOKStorageUsageReport(
      conversationsBytes: conversationsBytes,
      quarantinedBytes: quarantinedBytes,
      quarantinedCount: quarantinedCount,
      attachmentsBytes: attachmentsBytes,
      thumbnailCacheBytes: thumbnailCacheBytes,
      analyticsBytes: analyticsBytes,
      otherBytes: otherBytes,
      availableDeviceBytes: availableDeviceBytes
    )
  }

  private static func fileSize(at url: URL) -> Int64 {
    let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey])
    guard values?.isRegularFile == true else { return 0 }
    if let allocated = values?.totalFileAllocatedSize, allocated > 0 {
      return Int64(allocated)
    }
    return Int64(values?.fileSize ?? 0)
  }

  private static func directorySize(at directory: URL, fileManager: FileManager) -> Int64 {
    guard fileManager.fileExists(atPath: directory.path),
      let enumerator = fileManager.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey],
        options: [.skipsHiddenFiles]
      )
    else { return 0 }
    var total: Int64 = 0
    for case let url as URL in enumerator {
      total += fileSize(at: url)
    }
    return total
  }
}

public struct BYOKStorageUsageReport: Sendable, Equatable {
  public static let largeStorageWarningThresholdBytes: Int64 = 500 * 1_024 * 1_024
  public static let lowDeviceSpaceWarningThresholdBytes: Int64 = 250 * 1_024 * 1_024

  public var conversationsBytes: Int64
  public var quarantinedBytes: Int64
  public var quarantinedCount: Int
  public var attachmentsBytes: Int64
  public var thumbnailCacheBytes: Int64
  public var analyticsBytes: Int64
  public var otherBytes: Int64
  public var availableDeviceBytes: Int64?

  public init(
    conversationsBytes: Int64 = 0,
    quarantinedBytes: Int64 = 0,
    quarantinedCount: Int = 0,
    attachmentsBytes: Int64 = 0,
    thumbnailCacheBytes: Int64 = 0,
    analyticsBytes: Int64 = 0,
    otherBytes: Int64 = 0,
    availableDeviceBytes: Int64? = nil
  ) {
    self.conversationsBytes = conversationsBytes
    self.quarantinedBytes = quarantinedBytes
    self.quarantinedCount = quarantinedCount
    self.attachmentsBytes = attachmentsBytes
    self.thumbnailCacheBytes = thumbnailCacheBytes
    self.analyticsBytes = analyticsBytes
    self.otherBytes = otherBytes
    self.availableDeviceBytes = availableDeviceBytes
  }

  public var totalBytes: Int64 {
    conversationsBytes + quarantinedBytes + attachmentsBytes + thumbnailCacheBytes + analyticsBytes + otherBytes
  }

  public var isStorageLarge: Bool {
    totalBytes >= Self.largeStorageWarningThresholdBytes
  }

  public var isDeviceSpaceLow: Bool {
    guard let availableDeviceBytes else { return false }
    return availableDeviceBytes < Self.lowDeviceSpaceWarningThresholdBytes
  }

  public var hasCleanupWarning: Bool {
    isDeviceSpaceLow || isStorageLarge || quarantinedCount > 0
  }
}
