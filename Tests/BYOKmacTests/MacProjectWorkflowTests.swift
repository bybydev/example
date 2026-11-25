import AppKit
import BYOKchatProviderCore
import Foundation
import Testing

@testable import BYOKmac

@MainActor
@Suite("macOS Project workflows")
struct MacProjectWorkflowTests {
  @Test("Project account-default target falls back from an unavailable stored default")
  func projectAccountDefaultUsesUsableModelFallback() async throws {
    let context = try await makeMacProjectTestContext()
    defer { context.cleanup() }

    let providerID = try #require(ProviderKind.deepSeek.defaultProviderID)
    let stale = ProviderModel(providerID: providerID, id: "stale-model", displayName: "Stale")
    let available = ProviderModel(providerID: providerID, id: "available-model", displayName: "Available")
    let account = try await context.services.accountManager.createAccount(
      kind: .deepSeek,
      label: "DeepSeek",
      credential: "test-key",
      defaultModelID: stale.id
    )
    try await context.services.providerWorkspace.mergeModels([stale, available], for: account.id)
    try await context.services.providerWorkspace.mergeModels([available], for: account.id)

    let providers = MacProviderModel(services: context.services)
    try await providers.load()
    let project = ChatProject(
      name: "Fallback",
      accountID: account.id,
      modelID: nil
    )

    let target = try #require(resolveMacProjectTarget(project: project, providers: providers))
    #expect(target.accountID == account.id)
    #expect(target.modelID == available.id)
  }

  @Test("Project explicit unavailable model does not silently change targets")
  func explicitUnavailableProjectModelFails() async throws {
    let context = try await makeMacProjectTestContext()
    defer { context.cleanup() }

    let providerID = try #require(ProviderKind.deepSeek.defaultProviderID)
    let available = ProviderModel(providerID: providerID, id: "available-model", displayName: "Available")
    let account = try await context.services.accountManager.createAccount(
      kind: .deepSeek,
      label: "DeepSeek",
      credential: "test-key",
      defaultModelID: available.id
    )
    try await context.services.providerWorkspace.mergeModels([available], for: account.id)

    let providers = MacProviderModel(services: context.services)
    try await providers.load()
    let project = ChatProject(
      name: "Explicit",
      accountID: account.id,
      modelID: "removed-model"
    )

    #expect(resolveMacProjectTarget(project: project, providers: providers) == nil)
  }

  @Test("Focused Mac Project mutations preserve unrelated state")
  func focusedMacProjectMutationsPreserveState() async throws {
    let context = try await makeMacProjectTestContext()
    defer { context.cleanup() }

    let workspace = MacWorkspaceModel(services: context.services)
    await workspace.reload()
    let projectID = try #require(
      await workspace.createProject(
        name: "Product",
        symbolName: "shippingbox.fill",
        accentID: "orange",
        accountID: nil,
        modelID: nil,
        instructions: "Initial",
        files: [],
        mcpConfiguration: MCPChatToolConfiguration(),
        promptPresets: [],
        toolPresets: []
      )
    )

    #expect(
      await workspace.updateProjectIdentity(
        id: projectID,
        name: "Renamed",
        symbolName: "folder.fill",
        accentID: "teal"
      )
    )
    #expect(await workspace.updateProjectInstructions(id: projectID, instructions: "Keep this"))
    let preset = ProjectPromptPreset(name: "Review", prompt: "Review carefully")
    #expect(await workspace.upsertProjectPromptPreset(preset, projectID: projectID))

    let project = try #require(workspace.project(projectID))
    #expect(project.name == "Renamed")
    #expect(project.instructions == "Keep this")
    #expect(project.projectPromptPresets == [preset])
  }

  @Test("Project file detail omits token estimate for binary and image MIME types")
  func projectFileDetailTokenEstimateAccuracy() {
    let textFile = ProjectFile(
      filename: "notes.md",
      mimeType: "text/markdown",
      data: Data(repeating: 0x61, count: 400)
    )
    let jsonFile = ProjectFile(
      filename: "config.json",
      mimeType: "application/json; charset=utf-8",
      data: Data(repeating: 0x7b, count: 200)
    )
    let pngFile = ProjectFile(
      filename: "diagram.png",
      mimeType: "image/png",
      data: Data(repeating: 0x89, count: 4_000)
    )
    let pdfFile = ProjectFile(
      filename: "spec.pdf",
      mimeType: "application/pdf",
      data: Data(repeating: 0x25, count: 4_000)
    )

    #expect(macProjectFileDetail(textFile).contains("tokens"))
    #expect(macProjectFileDetail(jsonFile).contains("tokens"))
    #expect(!macProjectFileDetail(pngFile).contains("tokens"))
    #expect(!macProjectFileDetail(pdfFile).contains("tokens"))
  }

  @Test("Project file import rejects directories, empty files, and >40 MB totals")
  func projectFileImportValidationRejectsInvalidInputs() throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("byok-mac-import-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    // Directory rejection
    #expect(throws: (any Error).self) {
      _ = try MacProjectFileImportSupport.importFiles(
        from: [tempDir],
        existingCount: 0,
        existingBytes: 0
      )
    }

    // Empty file rejection
    let emptyURL = tempDir.appendingPathComponent("empty.txt", isDirectory: false)
    try Data().write(to: emptyURL)
    #expect(throws: ProjectWorkspaceError.emptyFile("empty.txt")) {
      _ = try MacProjectFileImportSupport.importFiles(
        from: [emptyURL],
        existingCount: 0,
        existingBytes: 0
      )
    }

    // >40 MB combined total rejection upfront
    let smallURL = tempDir.appendingPathComponent("notes.txt", isDirectory: false)
    try Data(repeating: 0x61, count: 1_024).write(to: smallURL)
    #expect(throws: ProjectWorkspaceError.filesTooLarge) {
      _ = try MacProjectFileImportSupport.importFiles(
        from: [smallURL],
        existingCount: 1,
        existingBytes: ProjectWorkspaceStore.maxTotalFileBytes - 512
      )
    }
  }

  @Test("Project file import normalizes TIFF images to JPEG via AppKit")
  func projectFileImportNormalizesTIFFToJPEG() throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("byok-mac-tiff-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let rep = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 4,
        pixelsHigh: 4,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      )
    )
    let tiffData = try #require(rep.tiffRepresentation)
    let tiffURL = tempDir.appendingPathComponent("scan.tiff", isDirectory: false)
    try tiffData.write(to: tiffURL)

    let imported = try MacProjectFileImportSupport.importFiles(
      from: [tiffURL],
      existingCount: 0,
      existingBytes: 0
    )
    #expect(imported.count == 1)
    #expect(imported[0].filename == "scan.jpg")
    #expect(imported[0].mimeType == "image/jpeg")
    #expect(imported[0].data.prefix(3) == Data([0xFF, 0xD8, 0xFF]))

    // Minimal valid 1x1 lossless WebP stays preserved without JPEG re-encoding.
    let webpBase64 = "UklGRh4AAABXRUJQVlA4TBEAAAAvAAAAAAfQ//73v/+BiOh/AAA="
    let webpData = try #require(Data(base64Encoded: webpBase64))
    let webpURL = tempDir.appendingPathComponent("sprite.webp", isDirectory: false)
    try webpData.write(to: webpURL)

    let importedWebP = try MacProjectFileImportSupport.importFiles(
      from: [webpURL],
      existingCount: 0,
      existingBytes: 0
    )
    #expect(importedWebP.count == 1)
    #expect(importedWebP[0].filename == "sprite.webp")
    #expect(importedWebP[0].mimeType == "image/webp")
    #expect(importedWebP[0].data == webpData)
  }

  @Test("Library picker capacity notes and preflight validate count, per-file, and total limits")
  func libraryPickerCapacityAndPreflight() {
    #expect(
      MacLibraryAttachmentPickerSupport.capacityNote(existingCount: 0, selectedCount: 0)
        == "You can select up to 8 attachments."
    )
    #expect(
      MacLibraryAttachmentPickerSupport.capacityNote(existingCount: 2, selectedCount: 5)
        == "You can select up to 1 more attachment."
    )
    #expect(
      MacLibraryAttachmentPickerSupport.capacityNote(existingCount: 3, selectedCount: 5)
        == "Maximum of 8 attachments reached."
    )

    #expect(
      MacLibraryAttachmentPickerSupport.preflight(
        existingCount: 7,
        existingBytes: 0,
        selectedByteCounts: [1_024, 1_024]
      ).isValid == false
    )
    #expect(
      MacLibraryAttachmentPickerSupport.preflight(
        existingCount: 0,
        existingBytes: 0,
        selectedByteCounts: [MacAttachmentImporter.maximumFileBytes + 1]
      ).isValid == false
    )
    #expect(
      MacLibraryAttachmentPickerSupport.preflight(
        existingCount: 0,
        existingBytes: 0,
        selectedByteCounts: [
          15 * 1_024 * 1_024,
          15 * 1_024 * 1_024,
          15 * 1_024 * 1_024,
        ]
      ).isValid == false
    )
    #expect(
      MacLibraryAttachmentPickerSupport.preflight(
        existingCount: 1,
        existingBytes: 10 * 1_024 * 1_024,
        selectedByteCounts: [10 * 1_024 * 1_024, 15 * 1_024 * 1_024]
      ).isValid == true
    )
  }

  @Test("Library rename validation rejects invalid paths and warns on extension changes")
  func libraryRenameValidation() {
    #expect(!MacLibraryRenameValidation.evaluate(proposed: "", original: "report.pdf").canSave)
    #expect(!MacLibraryRenameValidation.evaluate(proposed: "report.pdf", original: "report.pdf").canSave)

    let slash = MacLibraryRenameValidation.evaluate(proposed: "dir/report.pdf", original: "report.pdf")
    #expect(!slash.canSave)
    #expect(slash.errorMessage != nil)

    let dot = MacLibraryRenameValidation.evaluate(proposed: ".", original: "report.pdf")
    #expect(!dot.canSave)
    #expect(dot.errorMessage != nil)

    let dotDot = MacLibraryRenameValidation.evaluate(proposed: "..", original: "report.pdf")
    #expect(!dotDot.canSave)
    #expect(dotDot.errorMessage != nil)

    let removedExt = MacLibraryRenameValidation.evaluate(proposed: "report", original: "report.pdf")
    #expect(removedExt.canSave)
    #expect(removedExt.warningMessage != nil)

    let changedExt = MacLibraryRenameValidation.evaluate(proposed: "report.txt", original: "report.pdf")
    #expect(changedExt.canSave)
    #expect(changedExt.warningMessage != nil)

    let sameExt = MacLibraryRenameValidation.evaluate(proposed: "final.pdf", original: "report.pdf")
    #expect(sameExt.canSave)
    #expect(sameExt.errorMessage == nil)
    #expect(sameExt.warningMessage == nil)
  }

  @Test("Project defaults summary flags disabled accounts and unavailable models")
  func projectDefaultsSummaryFlagsUnavailableStates() async throws {
    let context = try await makeMacProjectTestContext()
    defer { context.cleanup() }

    let providerID = try #require(ProviderKind.deepSeek.defaultProviderID)
    let activeModel = ProviderModel(providerID: providerID, id: "active-model", displayName: "Active")
    let staleModel = ProviderModel(providerID: providerID, id: "stale-model", displayName: "Stale")
    let account = try await context.services.accountManager.createAccount(
      kind: .deepSeek,
      label: "DeepSeek",
      credential: "test-key",
      defaultModelID: activeModel.id
    )
    try await context.services.providerWorkspace.mergeModels([activeModel, staleModel], for: account.id)
    try await context.services.providerWorkspace.mergeModels([activeModel], for: account.id)

    let providers = MacProviderModel(services: context.services)
    try await providers.load()

    let appDefault = MacProjectDefaultsSummary.evaluate(
      project: ChatProject(name: "Default"),
      providers: providers
    )
    #expect(!appDefault.hasIssue)
    #expect(appDefault.cardSummary == "App defaults")

    let healthy = MacProjectDefaultsSummary.evaluate(
      project: ChatProject(name: "Healthy", accountID: account.id, modelID: activeModel.id),
      providers: providers
    )
    #expect(!healthy.hasIssue)
    #expect(healthy.cardSummary == "DeepSeek · Active")

    let unavailableModel = MacProjectDefaultsSummary.evaluate(
      project: ChatProject(name: "StaleModel", accountID: account.id, modelID: staleModel.id),
      providers: providers
    )
    #expect(unavailableModel.hasIssue)
    #expect(!unavailableModel.isAccountUnavailable)
    #expect(unavailableModel.isModelUnavailable)

    let missingAccount = MacProjectDefaultsSummary.evaluate(
      project: ChatProject(name: "MissingAccount", accountID: ProviderAccountID(rawValue: "missing")),
      providers: providers
    )
    #expect(missingAccount.hasIssue)
    #expect(missingAccount.isAccountUnavailable)

    var disabledAccount = account
    disabledAccount.isEnabled = false
    try await context.services.accountManager.updateAccount(disabledAccount)
    try await providers.load()
    let disabledStatus = MacProjectDefaultsSummary.evaluate(
      project: ChatProject(name: "DisabledAccount", accountID: account.id, modelID: activeModel.id),
      providers: providers
    )
    #expect(disabledStatus.hasIssue)
    #expect(disabledStatus.isAccountUnavailable)
    #expect(disabledStatus.accountLabel.contains("Disabled"))
  }

  @Test("Project chat date grouper buckets Today, Yesterday, Previous 7 Days, and older months")
  func projectChatDateGrouperBucketsByDayBoundary() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
    let now = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 5, day: 15, hour: 14, minute: 0))
    )
    let todayDate = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 5, day: 15, hour: 8, minute: 0))
    )
    let yesterdayDate = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 5, day: 14, hour: 23, minute: 30))
    )
    let weekDate = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 5, day: 10, hour: 12, minute: 0))
    )
    let olderDate = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 3, day: 20, hour: 12, minute: 0))
    )

    func makeConversation(_ id: String, updatedAt: Date) -> ChatConversation {
      ChatConversation(
        id: ConversationID(rawValue: id),
        title: id,
        createdAt: updatedAt,
        updatedAt: updatedAt,
        providerID: "deepseek",
        accountID: ProviderAccountID(rawValue: "acct"),
        modelID: "m"
      )
    }

    let sections = MacProjectChatDateGrouper.sections(
      for: [
        makeConversation("older", updatedAt: olderDate),
        makeConversation("week", updatedAt: weekDate),
        makeConversation("today", updatedAt: todayDate),
        makeConversation("yesterday", updatedAt: yesterdayDate),
      ],
      now: now,
      calendar: calendar
    )

    #expect(sections.count == 4)
    #expect(sections[0].title == "Today")
    #expect(sections[0].conversations.map(\.id) == ["today"])
    #expect(sections[1].title == "Yesterday")
    #expect(sections[1].conversations.map(\.id) == ["yesterday"])
    #expect(sections[2].title == "Previous 7 Days")
    #expect(sections[2].conversations.map(\.id) == ["week"])
    #expect(sections[3].conversations.map(\.id) == ["older"])
  }

  @Test("Project dropped-image import preserves PNG and normalizes TIFF while enforcing limits")
  func projectDroppedImageImportPreservesAndNormalizes() throws {
    let rep = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 4,
        pixelsHigh: 4,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      )
    )
    let pngData = try #require(rep.representation(using: .png, properties: [:]))
    let tiffData = try #require(rep.tiffRepresentation)

    let imported = try MacProjectFileImportSupport.importDroppedImages(
      [
        MacDroppedImage(data: pngData),
        MacDroppedImage(data: tiffData),
      ],
      existingCount: 0,
      existingBytes: 0
    )

    #expect(imported.count == 2)
    #expect(imported[0].mimeType == "image/png")
    #expect(imported[0].filename.hasSuffix(".png"))
    #expect(imported[1].mimeType == "image/jpeg")
    #expect(imported[1].filename.hasSuffix(".jpg"))
    #expect(imported[1].data.prefix(3) == Data([0xFF, 0xD8, 0xFF]))

    #expect(throws: ProjectWorkspaceError.tooManyFiles) {
      _ = try MacProjectFileImportSupport.importDroppedImages(
        [MacDroppedImage(data: pngData)],
        existingCount: ProjectWorkspaceStore.maxFileCount,
        existingBytes: 0
      )
    }
  }

  @Test("Workspace batch chat assignment and Library lookup stay synchronized")
  func workspaceBatchChatAssignmentAndLibraryLookup() async throws {
    let context = try await makeMacProjectTestContext()
    defer { context.cleanup() }

    let workspace = MacWorkspaceModel(services: context.services)
    await workspace.reload()

    let file = ProjectFile(
      filename: "notes.md",
      mimeType: "text/markdown",
      data: Data("# Notes".utf8)
    )
    let projectID = try #require(
      await workspace.createProject(
        name: "Alpha",
        symbolName: "folder.fill",
        accentID: "blue",
        accountID: nil,
        modelID: nil,
        instructions: "",
        files: [file],
        mcpConfiguration: MCPChatToolConfiguration(),
        promptPresets: [],
        toolPresets: []
      )
    )

    let first: ConversationID = "conv-1"
    let second: ConversationID = "conv-2"
    #expect(await workspace.assignConversations([first, second], to: projectID))
    #expect(workspace.projectID(for: first) == projectID)
    #expect(workspace.projectID(for: second) == projectID)
    #expect(workspace.statusMessage == "Added 2 chats to Alpha")

    #expect(!workspace.isFileInLibrary(file.id))
    #expect(await workspace.saveProjectFileToLibrary(file, projectID: projectID))
    #expect(workspace.isFileInLibrary(file.id))
  }
}

@MainActor
private struct MacProjectTestContext {
  let parent: URL
  let suiteName: String
  let services: BYOKCoreServices

  func cleanup() {
    try? FileManager.default.removeItem(at: parent)
    UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
  }
}

@MainActor
private func makeMacProjectTestContext() async throws -> MacProjectTestContext {
  let parent = FileManager.default.temporaryDirectory
    .appendingPathComponent("byok-mac-project-tests-\(UUID().uuidString)", isDirectory: true)
  let root = parent.appendingPathComponent("Workspace", isDirectory: true)
  let telemetry = parent.appendingPathComponent("Telemetry", isDirectory: true)
  let suiteName = "byok-mac-project-tests-\(UUID().uuidString)"
  let storage = BYOKStorageEnvironment(
    rootDirectory: root,
    userDefaultsSuiteName: suiteName,
    credentialService: "tests.byok.mac.project.credentials.\(UUID().uuidString)",
    mcpCredentialService: "tests.byok.mac.project.mcp.\(UUID().uuidString)",
    telemetryDirectory: telemetry
  )

  try await BYOKStorageBootstrap.prepare(environment: storage)
  let services = try BYOKCoreServices(
    environment: storage,
    credentialVault: InMemoryCredentialVault(),
    mcpCredentialVault: InMemoryMCPCredentialVault()
  )
  try await services.loadStoredState()
  return MacProjectTestContext(parent: parent, suiteName: suiteName, services: services)
}
