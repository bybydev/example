import AppKit
import BYOKchatProviderCore
import Foundation
import SwiftUI
import Testing

@testable import BYOKmac

@MainActor
@Suite("macOS attachment workflows")
struct MacAttachmentWorkflowTests {
  @Test("Pending attachment bytes survive store recreation while UI state stays metadata-only")
  func pendingAttachmentSurvivesRelaunch() async throws {
    let context = try makeContext()
    defer { context.cleanup() }

    let store = MacPendingAttachmentStore(
      environment: context.environment,
      blobs: context.blobs
    )
    await store.load()

    let attachment = ChatAttachment(
      id: "pending-file",
      kind: .file,
      filename: "pending.txt",
      mimeType: "text/plain",
      data: Data([1, 2, 3, 4])
    )
    let key = MacPendingAttachmentStore.key(for: nil)
    let staged = try await store.append([attachment], to: key)

    #expect(staged.count == 1)
    #expect(staged[0].data.isEmpty)
    #expect(staged[0].declaredByteCount == 4)
    #expect(try await context.blobs.loadData(attachment.id) == Data([1, 2, 3, 4]))

    let reloaded = MacPendingAttachmentStore(
      environment: context.environment,
      blobs: context.blobs
    )
    await reloaded.load()
    let restoredMetadata = await reloaded.attachments(for: key)
    let restoredSnapshot = await reloaded.snapshot()
    let restoredUI = restoredSnapshot[key] ?? []
    let referencedIDs = await reloaded.referencedIDs()

    #expect(restoredMetadata.count == 1)
    #expect(restoredMetadata[0].id == attachment.id)
    #expect(restoredMetadata[0].data.isEmpty)
    #expect(restoredMetadata[0].declaredByteCount == 4)
    #expect(restoredUI.first?.data.isEmpty == true)
    #expect(referencedIDs == Set([attachment.id]))
  }

  @Test("Fresh pending attachments transfer to the created conversation bucket")
  func pendingAttachmentTransfersToConversation() async throws {
    let context = try makeContext()
    defer { context.cleanup() }

    let store = MacPendingAttachmentStore(
      environment: context.environment,
      blobs: context.blobs
    )
    await store.load()

    let attachment = ChatAttachment(
      id: "transfer-file",
      kind: .file,
      filename: "notes.txt",
      mimeType: "text/plain",
      data: Data("hello".utf8)
    )
    let freshKey = MacPendingAttachmentStore.key(for: nil)
    let conversationID = ConversationID(rawValue: "conversation-a")
    let destinationKey = MacPendingAttachmentStore.key(for: conversationID)

    _ = try await store.append([attachment], to: freshKey)
    let transferred = try await store.transfer(from: freshKey, to: destinationKey)
    let fresh = await store.attachments(for: freshKey)
    let destination = await store.attachments(for: destinationKey)

    #expect(fresh.isEmpty)
    #expect(transferred.map(\.id) == [attachment.id])
    #expect(destination.map(\.id) == [attachment.id])
  }

  @Test("Startup orphan sweep retains blobs referenced only by pending composer state")
  func startupSweepKeepsPendingBlob() async throws {
    let context = try makeContext()
    defer { context.cleanup() }

    let stagedStore = MacPendingAttachmentStore(
      environment: context.environment,
      blobs: context.blobs
    )
    await stagedStore.load()
    let attachment = ChatAttachment(
      id: "pending-before-startup",
      kind: .file,
      filename: "draft.txt",
      mimeType: "text/plain",
      data: Data("draft bytes".utf8)
    )
    let key = MacPendingAttachmentStore.key(for: nil)
    _ = try await stagedStore.append([attachment], to: key)

    let app = MacAppModel(
      storageEnvironment: context.environment,
      coreServicesFactory: { environment in
        try BYOKCoreServices(
          environment: environment,
          credentialVault: InMemoryCredentialVault(),
          mcpCredentialVault: InMemoryMCPCredentialVault()
        )
      }
    )
    await app.start()

    #expect(app.isReady)
    let services = try #require(app.coreServices)
    #expect(try await services.fileBlobStore.loadData(attachment.id) == Data("draft bytes".utf8))
    let pendingStore = try #require(app.pendingAttachmentStore)
    let snapshot = await pendingStore.snapshot()
    #expect(snapshot[key]?.first?.id == attachment.id)
  }

  @Test("Text-like files can use text modality without file modality")
  func textFileCompatibilityUsesTextModality() throws {
    let attachment = ChatAttachment(
      kind: .file,
      filename: "notes.txt",
      mimeType: "text/plain",
      data: Data("hello".utf8)
    )

    try MacAttachmentCompatibility.validate(
      [attachment],
      providerKind: .gemini,
      inputModalities: ["text"]
    )
  }

  @Test("Image is rejected when selected model explicitly lacks image input")
  func imageRequiresImageModality() {
    let attachment = ChatAttachment(
      kind: .image,
      filename: "photo.jpg",
      mimeType: "image/jpeg",
      data: Data([1])
    )

    #expect(throws: ProviderError.self) {
      try MacAttachmentCompatibility.validate(
        [attachment],
        providerKind: .anthropic,
        inputModalities: ["text"]
      )
    }
  }

  @Test("Anthropic binary files are rejected before a turn is persisted")
  func anthropicRejectsUnsupportedBinaryFile() {
    let attachment = ChatAttachment(
      kind: .file,
      filename: "archive.zip",
      mimeType: "application/zip",
      data: Data([1, 2, 3])
    )

    #expect(throws: ProviderError.self) {
      try MacAttachmentCompatibility.validate(
        [attachment],
        providerKind: .anthropic,
        inputModalities: ["text", "image", "file"]
      )
    }
  }

  @Test("Pasteboard heuristic prefers attachments for files and pure images, but preserves rich text paste")
  func pasteboardAttachHeuristic() {
    #expect(
      MacAttachmentImporter.shouldAttachOnPaste(
        hasFileURLs: true,
        hasImageData: false,
        hasPlainText: true
      )
    )
    #expect(
      MacAttachmentImporter.shouldAttachOnPaste(
        hasFileURLs: false,
        hasImageData: true,
        hasPlainText: false
      )
    )
    #expect(
      !MacAttachmentImporter.shouldAttachOnPaste(
        hasFileURLs: false,
        hasImageData: true,
        hasPlainText: true
      )
    )
    #expect(
      !MacAttachmentImporter.shouldAttachOnPaste(
        hasFileURLs: false,
        hasImageData: false,
        hasPlainText: true
      )
    )
  }

  @Test("Composer Return key policy respects IME marked text, newline modifiers, and send readiness")
  func composerReturnKeyPolicy() {
    #expect(
      MacComposerSupport.returnKeyAction(
        modifiers: [],
        hasMarkedText: true,
        canSend: true
      ) == .passThroughToEditor
    )
    #expect(
      MacComposerSupport.returnKeyAction(
        modifiers: .shift,
        hasMarkedText: false,
        canSend: true
      ) == .passThroughToEditor
    )
    #expect(
      MacComposerSupport.returnKeyAction(
        modifiers: .option,
        hasMarkedText: false,
        canSend: true
      ) == .passThroughToEditor
    )
    #expect(
      MacComposerSupport.returnKeyAction(
        modifiers: [],
        hasMarkedText: false,
        canSend: true
      ) == .send
    )
    #expect(
      MacComposerSupport.returnKeyAction(
        modifiers: .command,
        hasMarkedText: false,
        canSend: true
      ) == .send
    )
    #expect(
      MacComposerSupport.returnKeyAction(
        modifiers: [],
        hasMarkedText: false,
        canSend: false
      ) == .swallow
    )
  }

  @Test("Composer attachment compatibility warning handles metadata-only text files, vision limits, and Anthropic limits")
  func composerAttachmentCompatibilityWarning() {
    let textOnlyEvidence: ModelCapabilityEvidence = {
      var evidence = ModelCapabilityEvidence()
      evidence.modalities(["text"], input: true)
      return evidence
    }()
    let textOnlyModel = ProviderModel(
      providerID: BuiltInProviders.anthropicID,
      id: "text-only",
      displayName: "Text Only",
      inputModalities: ["text"],
      capabilityEvidence: textOnlyEvidence
    )
    let textOnlyCapabilities = ModelCapabilityResolver.resolve(
      kind: .anthropic,
      modelID: "text-only",
      model: textOnlyModel
    )

    // Metadata-only pending text file (empty data on UI object) is still allowed on text-only models.
    let pendingTextFile = ChatAttachment(
      kind: .file,
      filename: "notes.md",
      mimeType: "text/markdown",
      data: Data(),
      declaredByteCount: 256
    )
    #expect(
      MacComposerSupport.attachmentCompatibilityWarning(
        attachments: [pendingTextFile],
        providerKind: .anthropic,
        capabilities: textOnlyCapabilities
      ) == nil
    )

    // Image on text-only model surfaces an inline warning.
    let pendingImage = ChatAttachment(
      kind: .image,
      filename: "screen.png",
      mimeType: "image/png",
      data: Data(),
      declaredByteCount: 2_048
    )
    #expect(
      MacComposerSupport.attachmentCompatibilityWarning(
        attachments: [pendingImage],
        providerKind: .anthropic,
        capabilities: textOnlyCapabilities
      ) != nil
    )

    let visionEvidence: ModelCapabilityEvidence = {
      var evidence = ModelCapabilityEvidence()
      evidence.modalities(["text", "image", "file"], input: true)
      return evidence
    }()
    let visionModel = ProviderModel(
      providerID: BuiltInProviders.anthropicID,
      id: "claude-sonnet",
      displayName: "Claude Sonnet",
      inputModalities: ["text", "image", "file"],
      capabilityEvidence: visionEvidence
    )
    let visionCapabilities = ModelCapabilityResolver.resolve(
      kind: .anthropic,
      modelID: "claude-sonnet",
      model: visionModel
    )

    // Auto-transcodable HEIC image under 5 MB does not trigger a false warning.
    let pendingHEIC = ChatAttachment(
      kind: .image,
      filename: "photo.heic",
      mimeType: "image/heic",
      data: Data(),
      declaredByteCount: 1_024 * 1_024
    )
    #expect(
      MacComposerSupport.attachmentCompatibilityWarning(
        attachments: [pendingHEIC],
        providerKind: .anthropic,
        capabilities: visionCapabilities
      ) == nil
    )

    // Image over 5 MB triggers Anthropic's 5 MB limit warning.
    let largeAnthropicImage = ChatAttachment(
      kind: .image,
      filename: "huge.jpg",
      mimeType: "image/jpeg",
      data: Data(),
      declaredByteCount: 6 * 1_024 * 1_024
    )
    #expect(
      MacComposerSupport.attachmentCompatibilityWarning(
        attachments: [largeAnthropicImage],
        providerKind: .anthropic,
        capabilities: visionCapabilities
      )?.contains("5 MB") == true
    )

    // Non-PDF binary triggers Anthropic's format warning.
    let archiveFile = ChatAttachment(
      kind: .file,
      filename: "bundle.zip",
      mimeType: "application/zip",
      data: Data(),
      declaredByteCount: 4_096
    )
    #expect(
      MacComposerSupport.attachmentCompatibilityWarning(
        attachments: [archiveFile],
        providerKind: .anthropic,
        capabilities: visionCapabilities
      )?.contains("PDFs") == true
    )
  }

  @Test("Composer prompt merge trims whitespace and separates existing draft with a blank line")
  func composerPromptMerge() {
    #expect(MacComposerSupport.mergedPromptText(current: "", presetPrompt: "   ") == nil)
    #expect(MacComposerSupport.mergedPromptText(current: "   ", presetPrompt: "Summarize") == "Summarize")
    #expect(
      MacComposerSupport.mergedPromptText(current: "Hello", presetPrompt: "Summarize")
        == "Hello\n\nSummarize"
    )
  }
}

@MainActor
@Suite("macOS Library workflows")
struct MacLibraryWorkflowTests {
  @Test("Mac Library batch add publishes all selected files together")
  func batchAddPublishesTogether() async throws {
    let context = try makeContext()
    defer { context.cleanup() }
    let services = try await makeServices(context)
    let workspace = MacWorkspaceModel(services: services)
    await workspace.reload()

    let attachments = [
      ChatAttachment(
        id: "library-one",
        kind: .file,
        filename: "one.txt",
        mimeType: "text/plain",
        data: Data("one".utf8)
      ),
      ChatAttachment(
        id: "library-two",
        kind: .file,
        filename: "two.txt",
        mimeType: "text/plain",
        data: Data("two".utf8)
      ),
    ]

    #expect(await workspace.addLibraryAttachments(attachments))
    #expect(workspace.libraryEntries.count == 2)
    #expect(workspace.libraryEntries.allSatisfy { $0.source == .manual })

    let reloaded = MacWorkspaceModel(services: services)
    await reloaded.reload()
    #expect(Set(reloaded.libraryEntries.map(\.filename)) == Set(["one.txt", "two.txt"]))
  }

  @Test("Mac Library refuses stale chat attachment metadata when bytes are gone")
  func staleStoredAttachmentIsRejected() async throws {
    let context = try makeContext()
    defer { context.cleanup() }
    let services = try await makeServices(context)
    let workspace = MacWorkspaceModel(services: services)
    await workspace.reload()

    let missing = ChatAttachment(
      id: "missing-library-blob",
      kind: .file,
      filename: "missing.pdf",
      mimeType: "application/pdf",
      data: Data(),
      declaredByteCount: 4_096
    )

    #expect(
      await workspace.saveStoredAttachmentToLibrary(
        missing,
        conversationID: "chat-a",
        messageID: "message-a"
      ) == false
    )
    #expect(workspace.libraryEntries.isEmpty)
    #expect(workspace.errorMessage != nil)
  }

  @Test("Saved chat Library items retain both source chat and source message")
  func savedChatItemRetainsSourceMessage() async throws {
    let context = try makeContext()
    defer { context.cleanup() }
    let services = try await makeServices(context)
    let workspace = MacWorkspaceModel(services: services)
    await workspace.reload()

    let data = Data("source bytes".utf8)
    let attachment = ChatAttachment(
      id: "source-library-blob",
      kind: .file,
      filename: "source.txt",
      mimeType: "text/plain",
      data: data
    )
    try await services.fileBlobStore.writeIfAbsent(
      attachment.id,
      data: data,
      metadata: AttachmentBlobMetadata(
        filename: attachment.filename,
        mimeType: attachment.mimeType,
        byteCount: data.count,
        createdAt: .now
      )
    )

    #expect(
      await workspace.saveStoredAttachmentToLibrary(
        attachment,
        conversationID: "chat-source",
        messageID: "message-source"
      )
    )
    let entry = try #require(workspace.libraryEntries.first)
    #expect(entry.source == .chat(conversationID: "chat-source", messageID: "message-source"))

    let request = MacConversationNavigationRequest(
      conversationID: "chat-source",
      messageID: "message-source"
    )
    #expect(request.conversationID == "chat-source")
    #expect(request.messageID == "message-source")
  }

  @Test("Library file importer preserves original image format and skips folders cleanly")
  func libraryFileImporterPreservesFormatAndSkipsFolders() async throws {
    let context = try makeContext()
    defer { context.cleanup() }

    // 1x1 transparent PNG
    let pngBase64 =
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
    let pngData = try #require(Data(base64Encoded: pngBase64))
    let pngURL = context.root.appendingPathComponent("transparent-icon.png")
    try pngData.write(to: pngURL)

    let folderURL = context.root.appendingPathComponent("Subfolder", isDirectory: true)
    try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

    let result = await MacLibraryFileImporter.importURLs([pngURL, folderURL])
    #expect(result.attachments.count == 1)
    #expect(result.skippedMessages.count == 1)

    let imported = try #require(result.attachments.first)
    #expect(imported.filename == "transparent-icon.png")
    #expect(imported.mimeType == "image/png")
    #expect(imported.kind == .image)
    #expect(imported.data == pngData)
  }

  @Test("Project files can be saved to Library with project provenance")
  func saveProjectFileToLibraryTracksProjectSource() async throws {
    let context = try makeContext()
    defer { context.cleanup() }
    let services = try await makeServices(context)
    let workspace = MacWorkspaceModel(services: services)
    await workspace.reload()

    let data = Data("project reference bytes".utf8)
    let file = ProjectFile(
      id: "project-source-blob",
      filename: "spec.md",
      mimeType: "text/markdown",
      data: data
    )
    try await services.fileBlobStore.writeIfAbsent(
      file.id,
      data: data,
      metadata: AttachmentBlobMetadata(
        filename: file.filename,
        mimeType: file.mimeType,
        byteCount: data.count,
        createdAt: .now
      )
    )

    let projectID = ProjectID(rawValue: "project-alpha")
    #expect(await workspace.saveProjectFileToLibrary(file, projectID: projectID))
    #expect(workspace.statusMessage == "Saved to Library")
    let entry = try #require(workspace.libraryEntries.first)
    #expect(entry.source == .project(projectID))
    #expect(MacLibrarySourceFilter.projects.matches(entry))

    // Saving the same file again is idempotent and reports "Already in Library".
    #expect(await workspace.saveProjectFileToLibrary(file, projectID: projectID))
    #expect(workspace.statusMessage == "Already in Library")
    #expect(workspace.libraryEntries.count == 1)
  }

  @Test("Saved response filenames include timestamp and sanitized title")
  func responseFilenameGeneration() {
    let date = Date(timeIntervalSince1970: 1_764_094_805)
    let titled = MacWorkspaceModel.responseFilename(
      createdAt: date,
      conversationTitle: "API / Design: Plan"
    )
    #expect(titled.hasPrefix("API - Design- Plan-"))
    #expect(titled.hasSuffix(".md"))
    #expect(!titled.contains("/"))

    let untitled = MacWorkspaceModel.responseFilename(
      createdAt: date,
      conversationTitle: "New Chat"
    )
    #expect(untitled.hasPrefix("Response-"))
    #expect(untitled.hasSuffix(".md"))
  }

  @Test("consumeErrorMessage clears stale workspace errors")
  func consumeErrorMessageClearsState() async throws {
    let context = try makeContext()
    defer { context.cleanup() }
    let services = try await makeServices(context)
    let workspace = MacWorkspaceModel(services: services)
    workspace.errorMessage = "Temporary failure"

    #expect(workspace.consumeErrorMessage() == "Temporary failure")
    #expect(workspace.errorMessage == nil)
  }

  @Test("ModelRequestPolicy reports per-provider supported image MIME types consistently")
  func modelRequestPolicyImageMIMETypes() {
    #expect(ModelRequestPolicy.supportsImageMIME("image/png", for: .openai))
    #expect(ModelRequestPolicy.supportsImageMIME("image/webp", for: .openai))
    #expect(ModelRequestPolicy.supportsImageMIME("image/gif", for: .anthropic))
    #expect(!ModelRequestPolicy.supportsImageMIME("image/heic", for: .openai))
    #expect(!ModelRequestPolicy.supportsImageMIME("image/tiff", for: .anthropic))

    #expect(ModelRequestPolicy.supportsImageMIME("image/png", for: .xAI))
    #expect(ModelRequestPolicy.supportsImageMIME("image/jpeg", for: .xAI))
    #expect(!ModelRequestPolicy.supportsImageMIME("image/webp", for: .xAI))
    #expect(!ModelRequestPolicy.supportsImageMIME("image/gif", for: .xAI))

    #expect(ModelRequestPolicy.supportsImageMIME("image/heic", for: .gemini))
    #expect(ModelRequestPolicy.supportsImageMIME("image/tiff", for: .gemini))
    #expect(!ModelRequestPolicy.supportsImageMIME("application/pdf", for: .gemini))
  }

  @Test("Attachment importer auto-transcodes unsupported image formats with fresh IDs")
  func transcodeUnsupportedImagesForProvider() async throws {
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
    let pngData = try #require(rep.representation(using: .png, properties: [:]))
    let gifData = try #require(rep.representation(using: .gif, properties: [:]))

    let tiffAttachment = ChatAttachment(
      id: "library-tiff-id",
      kind: .image,
      filename: "scan.tiff",
      mimeType: "image/tiff",
      data: tiffData
    )
    let pngAttachment = ChatAttachment(
      id: "library-png-id",
      kind: .image,
      filename: "diagram.png",
      mimeType: "image/png",
      data: pngData
    )
    let gifAttachment = ChatAttachment(
      id: "library-gif-id",
      kind: .image,
      filename: "anim.gif",
      mimeType: "image/gif",
      data: gifData
    )
    let pdfAttachment = ChatAttachment(
      id: "library-pdf-id",
      kind: .file,
      filename: "spec.pdf",
      mimeType: "application/pdf",
      data: Data("%PDF-1.4".utf8)
    )

    // Gemini accepts TIFF/PNG/GIF untouched.
    let geminiResult = try await MacAttachmentImporter.transcodeUnsupportedImages(
      [tiffAttachment, pngAttachment, pdfAttachment],
      for: .gemini
    )
    #expect(geminiResult.map(\.id) == ["library-tiff-id", "library-png-id", "library-pdf-id"])
    #expect(geminiResult[0].mimeType == "image/tiff")

    // OpenAI transcodes TIFF -> JPEG with a fresh ID, keeping PNG and PDF untouched.
    let openaiResult = try await MacAttachmentImporter.transcodeUnsupportedImages(
      [tiffAttachment, pngAttachment, pdfAttachment],
      for: .openai
    )
    #expect(openaiResult[0].id != tiffAttachment.id)
    #expect(openaiResult[0].mimeType == "image/jpeg")
    #expect(openaiResult[0].filename == "scan.jpg")
    #expect(openaiResult[0].data.prefix(3) == Data([0xFF, 0xD8, 0xFF]))
    #expect(openaiResult[1].id == pngAttachment.id)
    #expect(openaiResult[1].mimeType == "image/png")
    #expect(openaiResult[2].id == pdfAttachment.id)

    // xAI transcodes GIF -> JPEG with a fresh ID, keeping PNG untouched.
    let xaiResult = try await MacAttachmentImporter.transcodeUnsupportedImages(
      [gifAttachment, pngAttachment],
      for: .xAI
    )
    #expect(xaiResult[0].id != gifAttachment.id)
    #expect(xaiResult[0].mimeType == "image/jpeg")
    #expect(xaiResult[0].filename == "anim.jpg")
    #expect(xaiResult[1].id == pngAttachment.id)
  }
}

private struct MacAttachmentTestContext {
  let root: URL
  let environment: BYOKStorageEnvironment
  let blobs: FileAttachmentBlobStore

  func cleanup() {
    try? FileManager.default.removeItem(at: root)
    if let suite = environment.userDefaultsSuiteName {
      UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
  }
}

private func makeContext() throws -> MacAttachmentTestContext {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("byok-mac-attachment-tests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let environment = BYOKStorageEnvironment(
    rootDirectory: root,
    userDefaultsSuiteName: "byok-mac-attachment-tests-\(UUID().uuidString)",
    credentialService: "tests.byok.mac.attachments.credentials.\(UUID().uuidString)",
    mcpCredentialService: "tests.byok.mac.attachments.mcp.\(UUID().uuidString)",
    telemetryDirectory: root.appendingPathComponent("Telemetry", isDirectory: true)
  )
  let blobs = FileAttachmentBlobStore(directory: environment.layout.filesDirectory)
  return MacAttachmentTestContext(root: root, environment: environment, blobs: blobs)
}

@MainActor
private func makeServices(_ context: MacAttachmentTestContext) async throws -> BYOKCoreServices {
  try await BYOKStorageBootstrap.prepare(environment: context.environment)
  let services = try BYOKCoreServices(
    environment: context.environment,
    credentialVault: InMemoryCredentialVault(),
    mcpCredentialVault: InMemoryMCPCredentialVault()
  )
  try await services.loadStoredState()
  return services
}
