import BYOKchatProviderCore
import Foundation

enum MacStorageEnvironment {
  static var current: BYOKStorageEnvironment {
    let fileManager = FileManager.default
    let applicationSupport = fileManager.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first ?? fileManager.temporaryDirectory
    let root = applicationSupport.appendingPathComponent("BYOKchat", isDirectory: true)
    let telemetryNamespace = Bundle.main.bundleIdentifier ?? "com.hoangbkit.byokchat"

    return BYOKStorageEnvironment(
      rootDirectory: root,
      userDefaultsSuiteName: nil,
      credentialService: "com.hoangbkit.byokchat.credentials",
      mcpCredentialService: "com.hoangbkit.byokchat.mcp.credentials",
      telemetryDirectory: applicationSupport
        .appendingPathComponent(telemetryNamespace, isDirectory: true)
        .appendingPathComponent("Telemetry", isDirectory: true)
    )
  }
}

struct MacStorageResetResult: Sendable {
  let backupURL: URL?
  let cleanupWarnings: [String]
}

enum MacStorageRecovery {
  private static let recoveryPrefix = "BYOKchat-Recovery-"
  private static let maximumRecoveryCopies = 3

  /// Moves the current local workspace beside Application Support rather than
  /// deleting it. A fresh workspace is recreated at the original path so the
  /// app can start again while the previous bytes remain available for manual
  /// recovery. Keychain credentials and telemetry are intentionally untouched.
  static func moveWorkspaceAside(environment: BYOKStorageEnvironment) async throws -> URL? {
    let root = environment.rootDirectory

    return try await Task.detached(priority: .userInitiated) {
      let fileManager = FileManager.default
      let parent = root.deletingLastPathComponent()
      try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)

      guard fileManager.fileExists(atPath: root.path) else {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return latestRecoveryBackup(parent: parent, fileManager: fileManager)
      }

      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime]
      let timestamp = formatter.string(from: .now)
        .replacingOccurrences(of: ":", with: "-")
      let backup = parent.appendingPathComponent(
        "\(recoveryPrefix)\(timestamp)-\(UUID().uuidString.lowercased())",
        isDirectory: true
      )

      try fileManager.moveItem(at: root, to: backup)
      try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
      try pruneRecoveryBackups(parent: parent, fileManager: fileManager)
      return backup
    }.value
  }

  static func latestRecoveryBackup(environment: BYOKStorageEnvironment) async -> URL? {
    let parent = environment.rootDirectory.deletingLastPathComponent()
    return await Task.detached(priority: .utility) {
      latestRecoveryBackup(parent: parent, fileManager: .default)
    }.value
  }

  /// Full user-requested reset. Workspace bytes are moved aside first. Secret
  /// cleanup is best-effort after that point so the app can always restart into
  /// the fresh workspace even if Keychain or telemetry cleanup reports a problem.
  static func resetApplicationDataKeepingBackup(
    environment: BYOKStorageEnvironment,
    telemetryRecorder: TelemetryRecorder? = nil
  ) async throws -> MacStorageResetResult {
    let backup = try await moveWorkspaceAside(environment: environment)
    var warnings: [String] = []

    #if canImport(Security)
      do {
        try await KeychainCredentialVault(service: environment.credentialService).removeAllSecrets()
      } catch {
        warnings.append("Provider credentials could not all be removed: \(error.localizedDescription)")
      }
      do {
        try await KeychainMCPCredentialVault(service: environment.mcpCredentialService).removeAllCredentials()
      } catch {
        warnings.append("MCP credentials could not all be removed: \(error.localizedDescription)")
      }
    #endif

    let recorder = telemetryRecorder ?? environment.makeTelemetryRecorder()
    await recorder.clearAllTelemetry()
    let telemetryHealth = await recorder.health()
    if telemetryHealth.consecutiveFailureCount > 0 {
      warnings.append(
        "Telemetry could not be fully cleared: "
          + (telemetryHealth.lastFailureDescription ?? "unknown telemetry storage error")
      )
    }

    return MacStorageResetResult(backupURL: backup, cleanupWarnings: warnings)
  }

  private static func recoveryBackups(parent: URL, fileManager: FileManager) -> [URL] {
    let values = (try? fileManager.contentsOfDirectory(
      at: parent,
      includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
      options: [.skipsHiddenFiles]
    )) ?? []
    return values.filter { url in
      guard url.lastPathComponent.hasPrefix(recoveryPrefix) else { return false }
      return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
  }

  private static func latestRecoveryBackup(parent: URL, fileManager: FileManager) -> URL? {
    recoveryBackups(parent: parent, fileManager: fileManager)
      .sorted { lhs, rhs in
        let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return lhsDate > rhsDate
      }
      .first
  }

  private static func pruneRecoveryBackups(parent: URL, fileManager: FileManager) throws {
    let sorted = recoveryBackups(parent: parent, fileManager: fileManager)
      .sorted { lhs, rhs in
        let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return lhsDate > rhsDate
      }
    for url in sorted.dropFirst(maximumRecoveryCopies) {
      try? fileManager.removeItem(at: url)
    }
  }
}
