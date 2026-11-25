import BYOKchatProviderCore
import Foundation
import Observation

@MainActor
@Observable
final class MacWorkspaceModel {
  private(set) var projects: [ChatProject] = []
  private(set) var conversationProjectIDs: [ConversationID: ProjectID] = [:]
  private(set) var libraryEntries: [LibraryEntry] = []
  var isBusy = false
  var errorMessage: String?
  var statusMessage: String?
  var onFileReferencesChanged: (() -> Void)?

  private let projectsStore: ProjectWorkspaceStore
  private let libraryStore: LibraryStore
  private let restrictions: MacProResourceRestrictions

  init(
    services: BYOKCoreServices,
    restrictions: MacProResourceRestrictions = MacPurchaseStore.restrictions
  ) {
    projectsStore = services.projectWorkspace
    libraryStore = services.libraryStore
    self.restrictions = restrictions
  }

  func reload() async {
    let snapshot = await projectsStore.snapshot()
    projects = snapshot.projects.sorted {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
    conversationProjectIDs = Dictionary(
      uniqueKeysWithValues: snapshot.conversationProjectIDs.compactMap { rawConversationID, rawProjectID in
        let projectID = ProjectID(rawValue: rawProjectID)
        guard projects.contains(where: { $0.id == projectID }) else { return nil }
        return (ConversationID(rawValue: rawConversationID), projectID)
      }
    )
    libraryEntries = await libraryStore.entries()
  }

  func project(_ id: ProjectID?) -> ChatProject? {
    guard let id else { return nil }
    return projects.first { $0.id == id }
  }

  func projectID(for conversationID: ConversationID) -> ProjectID? {
    conversationProjectIDs[conversationID]
  }

  func project(for conversationID: ConversationID) -> ChatProject? {
    project(projectID(for: conversationID))
  }

  func conversationIDs(in projectID: ProjectID) -> Set<ConversationID> {
    Set(conversationProjectIDs.compactMap { $0.value == projectID ? $0.key : nil })
  }

  func isProjectRestricted(_ id: ProjectID) -> Bool {
    restrictions.isProjectRestricted(
      id,
      currentIDs: projects.map(\.id),
      entitlement: MacProAccess.entitlementAccess
    )
  }

  func projectFiles(projectID: ProjectID?) -> [ProjectFile] {
    guard let projectID, !isProjectRestricted(projectID) else { return [] }
    return project(projectID)?.projectFiles ?? []
  }

  func projectFiles(conversationID: ConversationID?) -> [ProjectFile] {
    guard let conversationID,
      let projectID = projectID(for: conversationID),
      !isProjectRestricted(projectID)
    else { return [] }
    return project(projectID)?.projectFiles ?? []
  }

  func fileData(_ id: String) async -> Data? {
    await projectsStore.fileData(id)
  }

  func attachment(for file: ProjectFile) async -> ChatAttachment? {
    guard let data = await projectsStore.fileData(file.id), !data.isEmpty else {
      errorMessage = "The file '\(file.filename)' could not be loaded."
      return nil
    }
    return ChatAttachment(
      id: file.id,
      kind: file.mimeType.lowercased().hasPrefix("image/") ? .image : .file,
      filename: file.filename,
      mimeType: file.mimeType,
      data: data
    )
  }

  func attachment(for entry: LibraryEntry) async -> ChatAttachment? {
    guard let data = await libraryStore.data(for: entry), !data.isEmpty else {
      errorMessage = "The file '\(entry.filename)' could not be loaded."
      return nil
    }
    return ChatAttachment(
      id: entry.id.rawValue,
      kind: entry.kind,
      filename: entry.filename,
      mimeType: entry.mimeType,
      data: data
    )
  }

  @discardableResult
  func createProject(
    name: String,
    symbolName: String,
    accentID: String,
    accountID: ProviderAccountID?,
    modelID: ModelID?,
    instructions: String,
    files: [ProjectFile],
    mcpConfiguration: MCPChatToolConfiguration,
    promptPresets: [ProjectPromptPreset],
    toolPresets: [ProjectToolPreset]
  ) async -> ProjectID? {
    guard MacProAccess.requireProjectCapacity(currentCount: projects.count) else {
      errorMessage = MacProAccess.blockedMessage(
        freeMessage: "Free includes 1 project. Upgrade to BYOK Pro to create more."
      )
      return nil
    }

    return await performReturning("Project created", referencesChanged: !files.isEmpty) {
      let value = try await projectsStore.createProject(
        name: name,
        symbolName: symbolName,
        accentID: accentID,
        accountID: accountID,
        modelID: modelID,
        instructions: instructions,
        files: files,
        mcpConfiguration: mcpConfiguration,
        promptPresets: promptPresets,
        toolPresets: toolPresets
      )
      MacAppAnalytics.track(.projectCreated)
      return value.id
    }
  }

  /// Full replacement remains available for portability/legacy callers. New
  /// Mac Project surfaces should use the focused mutation methods below so a
  /// stale editor snapshot cannot overwrite unrelated Project fields.
  func updateProject(
    id: ProjectID,
    name: String,
    symbolName: String,
    accentID: String,
    accountID: ProviderAccountID?,
    modelID: ModelID?,
    instructions: String,
    files: [ProjectFile],
    mcpConfiguration: MCPChatToolConfiguration,
    promptPresets: [ProjectPromptPreset],
    toolPresets: [ProjectToolPreset]
  ) async -> Bool {
    guard requireProjectAccess(id) else { return false }
    return await performResult("Project updated", referencesChanged: true) {
      _ = try await projectsStore.updateProject(
        id: id,
        name: name,
        symbolName: symbolName,
        accentID: accentID,
        accountID: accountID,
        modelID: modelID,
        instructions: instructions,
        files: files,
        mcpConfiguration: mcpConfiguration,
        promptPresets: promptPresets,
        toolPresets: toolPresets
      )
    }
  }

  func updateProjectIdentity(
    id: ProjectID,
    name: String,
    symbolName: String,
    accentID: String
  ) async -> Bool {
    guard requireProjectAccess(id) else { return false }
    return await performResult("Project updated") {
      _ = try await projectsStore.updateProjectIdentity(
        id: id,
        name: name,
        symbolName: symbolName,
        accentID: accentID
      )
    }
  }

  func updateProjectDefaults(
    id: ProjectID,
    accountID: ProviderAccountID?,
    modelID: ModelID?
  ) async -> Bool {
    guard requireProjectAccess(id) else { return false }
    return await performResult("Project updated") {
      _ = try await projectsStore.updateProjectDefaults(
        id: id,
        accountID: accountID,
        modelID: modelID
      )
    }
  }

  func updateProjectInstructions(id: ProjectID, instructions: String) async -> Bool {
    guard requireProjectAccess(id) else { return false }
    return await performResult("Project updated") {
      _ = try await projectsStore.updateProjectInstructions(id: id, instructions: instructions)
    }
  }

  func addProjectFiles(_ files: [ProjectFile], to projectID: ProjectID) async -> Bool {
    guard !files.isEmpty else { return true }
    guard requireProjectAccess(projectID) else { return false }
    return await performResult("Project updated", referencesChanged: true) {
      _ = try await projectsStore.addProjectFiles(files, to: projectID)
    }
  }

  func removeProjectFile(_ fileID: String, from projectID: ProjectID) async -> Bool {
    guard requireProjectAccess(projectID) else { return false }
    return await performResult("Project updated", referencesChanged: true) {
      _ = try await projectsStore.removeProjectFile(fileID, from: projectID)
    }
  }

  func upsertProjectPromptPreset(
    _ preset: ProjectPromptPreset,
    projectID: ProjectID
  ) async -> Bool {
    guard requireProjectAccess(projectID) else { return false }
    return await performResult("Project updated") {
      _ = try await projectsStore.upsertProjectPromptPreset(preset, projectID: projectID)
    }
  }

  func deleteProjectPromptPreset(_ presetID: String, projectID: ProjectID) async -> Bool {
    guard requireProjectAccess(projectID) else { return false }
    return await performResult("Project updated") {
      _ = try await projectsStore.deleteProjectPromptPreset(presetID, projectID: projectID)
    }
  }

  func replaceProjectToolSettings(
    id: ProjectID,
    mcpConfiguration: MCPChatToolConfiguration?,
    toolPresets: [ProjectToolPreset]
  ) async -> Bool {
    guard requireProjectAccess(id) else { return false }
    return await performResult("Project updated") {
      _ = try await projectsStore.replaceProjectToolSettings(
        id: id,
        mcpConfiguration: mcpConfiguration,
        toolPresets: toolPresets
      )
    }
  }

  func deleteProject(_ id: ProjectID) async -> Bool {
    await performResult("Project deleted; its chats are now standalone", referencesChanged: true) {
      try await projectsStore.deleteProject(id)
    }
  }

  func assignConversation(_ conversationID: ConversationID, to projectID: ProjectID?) async -> Bool {
    if let projectID, !requireProjectAccess(projectID) { return false }
    return await performResult(nil) {
      try await projectsStore.assignConversation(conversationID, to: projectID)
    }
  }

  func removeConversation(_ conversationID: ConversationID) async -> Bool {
    await assignConversation(conversationID, to: nil)
  }

  func consumeErrorMessage() -> String? {
    let message = errorMessage
    errorMessage = nil
    return message
  }

  func addLibraryAttachments(_ attachments: [ChatAttachment]) async -> Bool {
    guard !attachments.isEmpty else { return true }
    let label = attachments.count == 1
      ? "Added to Library"
      : "Added \(attachments.count) items to Library"
    return await performResult(label, referencesChanged: true) {
      let existingIDs = Set(await libraryStore.entries().map(\.id))
      let savedEntries = try await libraryStore.addAttachments(attachments, source: .manual)
      for entry in savedEntries where !existingIDs.contains(entry.id) {
        MacAppAnalytics.track(.libraryItemSaved, dimension: entry.kind == .image ? .image : .file)
      }
    }
  }

  func saveStoredAttachmentToLibrary(
    _ attachment: ChatAttachment,
    conversationID: ConversationID,
    messageID: ChatMessageID
  ) async -> Bool {
    let didAdd = await performReturning(nil, referencesChanged: true) {
      let existingIDs = Set(await libraryStore.entries().map(\.id))
      let entry = try await libraryStore.ensureListed(
        fileID: attachment.id,
        filename: attachment.filename,
        mimeType: attachment.mimeType,
        byteCount: attachment.byteCount,
        source: .chat(conversationID: conversationID, messageID: messageID)
      )
      let added = !existingIDs.contains(entry.id)
      if added {
        MacAppAnalytics.track(.libraryItemSaved, dimension: entry.kind == .image ? .image : .file)
      }
      return added
    }
    guard let didAdd else { return false }
    statusMessage = didAdd ? "Saved to Library" : "Already in Library"
    return true
  }

  func saveProjectFileToLibrary(
    _ file: ProjectFile,
    projectID: ProjectID
  ) async -> Bool {
    let didAdd = await performReturning(nil, referencesChanged: true) {
      let existingIDs = Set(await libraryStore.entries().map(\.id))
      let entry = try await libraryStore.ensureListed(
        fileID: file.id,
        filename: file.filename,
        mimeType: file.mimeType,
        byteCount: file.byteCount,
        source: .project(projectID)
      )
      let added = !existingIDs.contains(entry.id)
      if added {
        MacAppAnalytics.track(.libraryItemSaved, dimension: entry.kind == .image ? .image : .file)
      }
      return added
    }
    guard let didAdd else { return false }
    statusMessage = didAdd ? "Saved to Library" : "Already in Library"
    return true
  }

  func saveResponseToLibrary(
    _ content: String,
    conversationID: ConversationID,
    messageID: ChatMessageID,
    createdAt: Date,
    conversationTitle: String? = nil
  ) async -> Bool {
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }

    let filename = Self.responseFilename(
      createdAt: createdAt,
      conversationTitle: conversationTitle
    )
    return await performResult("Saved to Library", referencesChanged: true) {
      let entry = try await libraryStore.add(
        filename: filename,
        mimeType: "text/markdown",
        data: Data(trimmed.utf8),
        source: .chat(conversationID: conversationID, messageID: messageID)
      )
      MacAppAnalytics.track(.libraryItemSaved, dimension: entry.kind == .image ? .image : .file)
    }
  }

  static func responseFilename(
    createdAt: Date,
    conversationTitle: String? = nil
  ) -> String {
    let parts = Calendar.current.dateComponents(
      [.year, .month, .day, .hour, .minute, .second],
      from: createdAt
    )
    let stamp = String(
      format: "%04d-%02d-%02d-%02d%02d%02d",
      parts.year ?? 0,
      parts.month ?? 0,
      parts.day ?? 0,
      parts.hour ?? 0,
      parts.minute ?? 0,
      parts.second ?? 0
    )
    if let title = conversationTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
      !title.isEmpty,
      title.caseInsensitiveCompare("New Chat") != .orderedSame
    {
      let sanitized = title
        .replacingOccurrences(of: "/", with: "-")
        .replacingOccurrences(of: ":", with: "-")
        .replacingOccurrences(of: "\0", with: "")
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
      let stem = String(sanitized.prefix(40)).trimmingCharacters(in: .whitespacesAndNewlines)
      if !stem.isEmpty && stem != "." && stem != ".." {
        return "\(stem)-\(stamp).md"
      }
    }
    return "Response-\(stamp).md"
  }

  @discardableResult
  func saveLibraryItem(
    filename: String,
    mimeType: String,
    data: Data,
    source: LibraryEntrySource,
    successMessage: String? = "Saved to Library"
  ) async -> LibraryEntry? {
    await performReturning(successMessage, referencesChanged: true) {
      let entry = try await libraryStore.add(
        filename: filename,
        mimeType: mimeType,
        data: data,
        source: source
      )
      MacAppAnalytics.track(.libraryItemSaved, dimension: entry.kind == .image ? .image : .file)
      return entry
    }
  }

  @discardableResult
  func saveLibraryAttachments(
    _ attachments: [ChatAttachment],
    source: LibraryEntrySource,
    successMessage: String? = "Saved to Library"
  ) async -> [LibraryEntry]? {
    guard !attachments.isEmpty else { return [] }
    return await performReturning(successMessage, referencesChanged: true) {
      let savedEntries = try await libraryStore.addAttachments(attachments, source: source)
      for entry in savedEntries {
        MacAppAnalytics.track(.libraryItemSaved, dimension: entry.kind == .image ? .image : .file)
      }
      return savedEntries
    }
  }

  func renameLibraryEntry(_ id: LibraryEntryID, filename: String) async -> Bool {
    await performResult("Renamed library item") {
      try await libraryStore.rename(id, filename: filename)
    }
  }

  func deleteLibraryEntries(_ ids: Set<LibraryEntryID>) async -> Bool {
    guard !ids.isEmpty else { return true }
    let label = ids.count == 1
      ? "Deleted 1 item from Library"
      : "Deleted \(ids.count) items from Library"
    return await performResult(label, referencesChanged: true) {
      try await libraryStore.deleteEntries(ids)
    }
  }

  func libraryData(_ entry: LibraryEntry) async -> Data? {
    await libraryStore.data(for: entry)
  }

  func libraryThumbnail(_ entry: LibraryEntry, maxPixelSize: CGFloat) async -> Data? {
    await libraryStore.thumbnailData(for: entry, maxPixelSize: maxPixelSize)
  }

  private func requireProjectAccess(_ id: ProjectID) -> Bool {
    guard isProjectRestricted(id) else { return true }
    errorMessage = MacProAccess.restoredResourceBlockedMessage("project")
    MacProAccess.requestUpgrade(.projects)
    return false
  }

  private func performResult(
    _ successMessage: String?,
    referencesChanged: Bool = false,
    operation: () async throws -> Void
  ) async -> Bool {
    guard !isBusy else {
      errorMessage = "Another workspace change is still being saved. Try again."
      return false
    }

    isBusy = true
    errorMessage = nil
    statusMessage = nil
    defer { isBusy = false }
    do {
      try await operation()
      await reload()
      if referencesChanged { onFileReferencesChanged?() }
      statusMessage = successMessage
      return true
    } catch {
      MacAppAnalytics.reportError("workspace_operation_failed", component: "workspace")
      errorMessage = error.localizedDescription
      return false
    }
  }

  private func performReturning<T>(
    _ successMessage: String?,
    referencesChanged: Bool = false,
    operation: () async throws -> T
  ) async -> T? {
    guard !isBusy else {
      errorMessage = "Another workspace change is still being saved. Try again."
      return nil
    }

    isBusy = true
    errorMessage = nil
    statusMessage = nil
    defer { isBusy = false }
    do {
      let value = try await operation()
      await reload()
      if referencesChanged { onFileReferencesChanged?() }
      statusMessage = successMessage
      return value
    } catch {
      MacAppAnalytics.reportError("workspace_operation_failed", component: "workspace")
      errorMessage = error.localizedDescription
      return nil
    }
  }
}
