import BYOKchatProviderCore
import Foundation
import Observation

actor ICloudProjectSyncStorage: ProjectSyncRemoteStorage {
  private let containerIdentifier: String
  private let relativePath: String

  init(
    containerIdentifier: String = "iCloud.com.hoangbkit.byokchat",
    relativePath: String = "Documents/BYOKchat/project-sync-v1.json"
  ) {
    self.containerIdentifier = containerIdentifier
    self.relativePath = relativePath
  }

  func loadData() throws -> Data? {
    let url = try syncURL(createDirectory: false)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try Data(contentsOf: url, options: .mappedIfSafe)
  }

  func saveData(_ data: Data) throws {
    let url = try syncURL(createDirectory: true)
    try data.write(to: url, options: .atomic)
  }

  private func syncURL(createDirectory: Bool) throws -> URL {
    guard let container = FileManager.default.url(
      forUbiquityContainerIdentifier: containerIdentifier
    ) else {
      throw ProjectSyncError.unavailable
    }
    let url = container.appendingPathComponent(relativePath, isDirectory: false)
    if createDirectory {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
    }
    return url
  }
}

@MainActor
@Observable
final class ProjectSyncModel {
  private static let enabledKey = "byokchat.projectSync.enabled.v1"

  private let service: ProjectSyncService
  private let projects: ProjectManagementModel
  private let mcp: MCPManagementModel
  private let defaults: UserDefaults

  private(set) var isEnabled: Bool
  private(set) var isSyncing = false
  private(set) var lastSyncedAt: Date?
  var errorMessage: String?
  var statusMessage: String?

  init(
    service: ProjectSyncService,
    projects: ProjectManagementModel,
    mcp: MCPManagementModel,
    defaults: UserDefaults = .standard
  ) {
    self.service = service
    self.projects = projects
    self.mcp = mcp
    self.defaults = defaults
    if defaults.object(forKey: Self.enabledKey) == nil {
      self.isEnabled = true
    } else {
      self.isEnabled = defaults.bool(forKey: Self.enabledKey)
    }
  }

  func load() async {
    lastSyncedAt = try? await service.lastSyncedAt()
    guard isEnabled else { return }
    await syncNow(showSuccess: false)
  }

  func setEnabled(_ enabled: Bool) async {
    isEnabled = enabled
    defaults.set(enabled, forKey: Self.enabledKey)
    if enabled {
      await syncNow(showSuccess: true)
    } else {
      statusMessage = "Project sync paused"
    }
  }

  func syncIfEnabled() async {
    guard isEnabled, !isSyncing else { return }
    await syncNow(showSuccess: false)
  }

  func syncNow(showSuccess: Bool = true) async {
    guard !isSyncing else { return }
    isSyncing = true
    errorMessage = nil
    defer { isSyncing = false }

    do {
      let result = try await service.synchronize()
      lastSyncedAt = result.syncedAt
      await projects.reloadFromStorage()
      await mcp.reloadFromStorage()
      if showSuccess {
        statusMessage = syncSummary(result)
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func syncSummary(_ result: ProjectSyncResult) -> String {
    var parts = ["\(result.projectCount) project\(result.projectCount == 1 ? "" : "s") synced"]
    if result.downloadedProjectCount > 0 {
      parts.append("\(result.downloadedProjectCount) downloaded")
    }
    if result.uploadedProjectCount > 0 {
      parts.append("\(result.uploadedProjectCount) uploaded")
    }
    if result.deletedProjectCount > 0 {
      parts.append("\(result.deletedProjectCount) deleted")
    }
    return parts.joined(separator: " · ")
  }
}
