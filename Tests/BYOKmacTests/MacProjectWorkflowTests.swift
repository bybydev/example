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
