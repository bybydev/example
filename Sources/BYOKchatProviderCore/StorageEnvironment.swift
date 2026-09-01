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
}
