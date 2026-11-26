import BYOKchatProviderCore
import Foundation
import Testing

@testable import BYOKmac

@MainActor
@Suite("macOS startup and recovery")
struct MacStartupRecoveryTests {
  @Test("Fresh app reaches ready state with isolated shared services")
  func freshStartupReachesReady() async throws {
    let context = makeMacStartupTestContext()
    defer { context.cleanup() }

    let app = MacAppModel(
      storageEnvironment: context.storage,
      coreServicesFactory: { try makeIsolatedServices(environment: $0) }
    )

    await app.start()

    #expect(app.isReady)
    #expect(app.coreServices != nil)
    #expect(app.providers != nil)
    #expect(app.chats != nil)
    #expect(app.workspace != nil)
    #expect(app.mcp != nil)
  }

  @Test("Repeated start after ready keeps the existing runtime graph")
  func repeatedStartIsIdempotent() async throws {
    let context = makeMacStartupTestContext()
    defer { context.cleanup() }
    var compositions = 0

    let app = MacAppModel(
      storageEnvironment: context.storage,
      coreServicesFactory: { environment in
        compositions += 1
        return try makeIsolatedServices(environment: environment)
      }
    )

    await app.start()
    let initialServices = try #require(app.coreServices)
    let initialProviders = try #require(app.providers)
    let initialChats = try #require(app.chats)

    await app.start()

    #expect(compositions == 1)
    #expect(app.coreServices === initialServices)
    #expect(app.providers === initialProviders)
    #expect(app.chats === initialChats)
    #expect(app.isReady)
  }

  @Test("Startup failure records exact stage and retry can recover")
  func retryAfterCompositionFailure() async throws {
    let context = makeMacStartupTestContext()
    defer { context.cleanup() }
    var attempts = 0

    let app = MacAppModel(
      storageEnvironment: context.storage,
      coreServicesFactory: { environment in
        attempts += 1
        if attempts == 1 {
          throw MacStartupRecoveryTestError.injected
        }
        return try makeIsolatedServices(environment: environment)
      }
    )

    await app.start()
    guard case .failed(let failure) = app.startupState else {
      Issue.record("Expected first startup attempt to fail")
      return
    }
    #expect(failure.stage == .composingServices)
    #expect(!app.isReady)

    await app.retryStartup()

    #expect(attempts == 2)
    #expect(app.isReady)
  }

  @Test("Start fresh moves old workspace aside and starts a usable app")
  func startFreshKeepsRecoveryBackup() async throws {
    let context = makeMacStartupTestContext()
    defer { context.cleanup() }
    try FileManager.default.createDirectory(
      at: context.storage.rootDirectory,
      withIntermediateDirectories: true
    )
    let marker = context.storage.rootDirectory.appendingPathComponent("important.txt")
    try Data("keep me".utf8).write(to: marker)

    let app = MacAppModel(
      storageEnvironment: context.storage,
      coreServicesFactory: { try makeIsolatedServices(environment: $0) }
    )

    await app.startFreshKeepingBackup()

    #expect(app.isReady)
    let backup = try #require(app.lastRecoveryBackupURL)
    #expect(FileManager.default.fileExists(atPath: backup.path))
    let recovered = try Data(contentsOf: backup.appendingPathComponent("important.txt"))
    #expect(recovered == Data("keep me".utf8))
    #expect(FileManager.default.fileExists(atPath: context.storage.rootDirectory.path))
    #expect(!FileManager.default.fileExists(atPath: marker.path))
  }

  @Test("Recovery copies are bounded to three")
  func recoveryCopiesArePruned() async throws {
    let context = makeMacStartupTestContext()
    defer { context.cleanup() }

    for index in 0..<5 {
      try FileManager.default.createDirectory(
        at: context.storage.rootDirectory,
        withIntermediateDirectories: true
      )
      let marker = context.storage.rootDirectory.appendingPathComponent("marker-\(index).txt")
      try Data("\(index)".utf8).write(to: marker)
      _ = try await MacStorageRecovery.moveWorkspaceAside(environment: context.storage)
    }

    let parent = context.storage.rootDirectory.deletingLastPathComponent()
    let backups = try FileManager.default.contentsOfDirectory(
      at: parent,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    ).filter { url in
      url.lastPathComponent.hasPrefix("BYOKchat-Recovery-")
        && ((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true)
    }

    #expect(backups.count == 3)
    #expect(FileManager.default.fileExists(atPath: context.storage.rootDirectory.path))
  }

  @Test("Full reset preserves workspace bytes and recreates an empty root")
  func fullResetKeepsWorkspaceBackup() async throws {
    let context = makeMacStartupTestContext()
    defer { context.cleanup() }
    try FileManager.default.createDirectory(
      at: context.storage.rootDirectory,
      withIntermediateDirectories: true
    )
    let marker = context.storage.rootDirectory.appendingPathComponent("before-reset.txt")
    try Data("recoverable".utf8).write(to: marker)

    let result = try await MacStorageRecovery.resetApplicationDataKeepingBackup(
      environment: context.storage
    )

    let backup = try #require(result.backupURL)
    let recovered = try Data(contentsOf: backup.appendingPathComponent("before-reset.txt"))
    #expect(recovered == Data("recoverable".utf8))
    #expect(FileManager.default.fileExists(atPath: context.storage.rootDirectory.path))
    #expect(!FileManager.default.fileExists(atPath: marker.path))
  }

  @Test("Data-management reset restarts into a fresh usable service graph")
  func dataManagementResetRestartsApp() async throws {
    let context = makeMacStartupTestContext()
    defer { context.cleanup() }

    let app = MacAppModel(
      storageEnvironment: context.storage,
      coreServicesFactory: { try makeIsolatedServices(environment: $0) }
    )
    await app.start()
    let initialServices = try #require(app.coreServices)
    _ = try await initialServices.conversationStore.createConversation(
      providerID: "deepseek",
      accountID: "test-account",
      modelID: "deepseek-v4-flash"
    )
    #expect(!(await initialServices.conversationStore.conversationSummaries()).isEmpty)

    let dataManagement = try #require(app.dataManagement)
    await dataManagement.resetApplicationDataKeepingBackup()

    #expect(app.isReady)
    let restartedServices = try #require(app.coreServices)
    #expect((await restartedServices.conversationStore.conversationSummaries()).isEmpty)
    #expect(app.lastRecoveryBackupURL != nil)
    #expect(app.dataManagement != nil)
  }

  @Test("Startup failure diagnostics include the configured storage environment path")
  func startupFailureDiagnosticsUseEnvironmentPath() async {
    let context = makeMacStartupTestContext()
    defer { context.cleanup() }

    let app = MacAppModel(
      storageEnvironment: context.storage,
      coreServicesFactory: { _ in throw MacStartupRecoveryTestError.injected }
    )

    await app.start()
    guard case .failed(let failure) = app.startupState else {
      Issue.record("Expected startup to fail")
      return
    }
    #expect(failure.dataDirectoryPath == context.storage.rootDirectory.path)
    #expect(failure.diagnosticText.contains(context.storage.rootDirectory.path))
  }

  @Test("Full-text search enablement persists across startup and data-mutation reload")
  func fullTextSearchEnablementSyncsAcrossLifecycle() async throws {
    let context = makeMacStartupTestContext()
    defer { context.cleanup() }

    let app = MacAppModel(
      storageEnvironment: context.storage,
      coreServicesFactory: { try makeIsolatedServices(environment: $0) }
    )

    await app.setFullTextSearchEnabled(true)
    await app.start()

    let services = try #require(app.coreServices)
    #expect(await services.conversationStore.searchIndexStatus().isEnabled)
    let initialGeneration = app.runtimeGeneration
    #expect(initialGeneration > 0)

    try await app.reloadAfterDataMutation()
    #expect(app.runtimeGeneration == initialGeneration + 1)
    #expect(await services.conversationStore.searchIndexStatus().isEnabled)

    await app.setFullTextSearchEnabled(false)
    #expect(!(await services.conversationStore.searchIndexStatus().isEnabled))
  }

  @Test("Flushing pending state persists debounced conversation drafts immediately")
  func flushPendingStatePersistsDebouncedDrafts() async throws {
    let context = makeMacStartupTestContext()
    defer { context.cleanup() }

    let app = MacAppModel(
      storageEnvironment: context.storage,
      coreServicesFactory: { try makeIsolatedServices(environment: $0) }
    )
    await app.start()

    let services = try #require(app.coreServices)
    let chats = try #require(app.chats)
    let conversation = try await services.conversationStore.createConversation(
      providerID: BuiltInProviders.openAIID,
      accountID: ProviderAccountID(rawValue: "acct-draft"),
      modelID: ModelID(rawValue: "gpt-4o")
    )

    chats.setDraft("Unsaved draft before quit", conversationID: conversation.id)
    #expect(app.hasPendingWorkToFlush)

    await app.flushPendingState()
    #expect(!app.hasPendingWorkToFlush)

    let persisted = try await services.conversationStore.conversation(id: conversation.id)
    #expect(persisted.draftText == "Unsaved draft before quit")
  }

  @Test("Idle orphan sweep reclaims unreferenced blobs and derived thumbnails, skipping when busy")
  func idleOrphanSweepRespectsBusyStateAndSweepsDerivatives() async throws {
    let context = makeMacStartupTestContext()
    defer { context.cleanup() }

    let app = MacAppModel(
      storageEnvironment: context.storage,
      coreServicesFactory: { try makeIsolatedServices(environment: $0) }
    )
    await app.start()

    let services = try #require(app.coreServices)
    let workspace = try #require(app.workspace)

    try await services.fileBlobStore.writeIfAbsent(
      "orphan-blob",
      data: Data("orphan".utf8),
      metadata: nil
    )
    let derivedDir = context.storage.layout.derivedThumbnailsDirectory
    try FileManager.default.createDirectory(at: derivedDir, withIntermediateDirectories: true)
    let orphanThumb = derivedDir.appendingPathComponent("orphan-blob-256", isDirectory: false)
    let standaloneOrphanThumb = derivedDir.appendingPathComponent("stale-thumb-only-256", isDirectory: false)
    try Data("thumb".utf8).write(to: orphanThumb)
    try Data("stale".utf8).write(to: standaloneOrphanThumb)

    workspace.isBusy = true
    await app.sweepOrphanFilesIfIdle()
    #expect(try await services.fileBlobStore.storedIDs().contains("orphan-blob"))
    #expect(FileManager.default.fileExists(atPath: orphanThumb.path))
    #expect(FileManager.default.fileExists(atPath: standaloneOrphanThumb.path))

    workspace.isBusy = false
    await app.sweepOrphanFilesIfIdle()
    #expect(!(try await services.fileBlobStore.storedIDs().contains("orphan-blob")))
    #expect(!FileManager.default.fileExists(atPath: orphanThumb.path))
    #expect(!FileManager.default.fileExists(atPath: standaloneOrphanThumb.path))
  }
}

private enum MacStartupRecoveryTestError: Error {
  case injected
}

private struct MacStartupTestContext {
  let parent: URL
  let suiteName: String
  let storage: BYOKStorageEnvironment

  func cleanup() {
    try? FileManager.default.removeItem(at: parent)
    UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
  }
}

private func makeMacStartupTestContext() -> MacStartupTestContext {
  let parent = FileManager.default.temporaryDirectory
    .appendingPathComponent("byok-mac-startup-tests-\(UUID().uuidString)", isDirectory: true)
  let suiteName = "byok-mac-startup-tests-\(UUID().uuidString)"
  let storage = BYOKStorageEnvironment(
    rootDirectory: parent.appendingPathComponent("Workspace", isDirectory: true),
    userDefaultsSuiteName: suiteName,
    credentialService: "tests.byok.mac.startup.credentials.\(UUID().uuidString)",
    mcpCredentialService: "tests.byok.mac.startup.mcp.\(UUID().uuidString)",
    telemetryDirectory: parent.appendingPathComponent("Telemetry", isDirectory: true)
  )
  return MacStartupTestContext(parent: parent, suiteName: suiteName, storage: storage)
}

private func makeIsolatedServices(environment: BYOKStorageEnvironment) throws -> BYOKCoreServices {
  try BYOKCoreServices(
    environment: environment,
    credentialVault: InMemoryCredentialVault(),
    mcpCredentialVault: InMemoryMCPCredentialVault()
  )
}
