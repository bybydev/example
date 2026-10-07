import Foundation

// One versioned shard per conversation plus a lightweight index used for
// startup/list surfaces. Full message histories are loaded on demand.
public actor ConversationStore {
  private let persistence: any ConversationWorkspacePersistence
  private let blobs: any AttachmentBlobStoring

  /// Loaded full conversations only. This is deliberately not the whole corpus.
  private var state = ConversationWorkspaceState()
  /// Complete lightweight catalog loaded from index.json at startup.
  private var indexEntries: [ConversationID: ConversationIndexEntry] = [:]
  private var hasLoaded = false
  private var deferredDirtyIDs: Set<ConversationID> = []
  private var isDeferredFlushScheduled = false

  public private(set) var flushError: Error?
  public private(set) var quarantinedShardCount = 0

  private struct IndexVersionHeader: Decodable {
    var schemaVersion: Int?
  }

  private struct IndexTombstones: Decodable {
    var tombstones: [String: Date]?
  }

  private struct ShardVersionHeader: Decodable {
    var schemaVersion: Int?
    var minimumReaderVersion: Int?
  }

  private struct DecodedShard {
    var conversation: ChatConversation
    var isLegacy: Bool
  }

  public init(
    persistence: any ConversationWorkspacePersistence,
    blobs: any AttachmentBlobStoring = InMemoryAttachmentBlobStore()
  ) {
    self.persistence = persistence
    self.blobs = blobs
  }

  public func load() async throws {
    guard !hasLoaded else { return }

    let shardIDs = Set(try await persistence.shardIDs())
    let indexData = try await persistence.loadIndex()

    if let indexData {
      if let header = try? JSONDecoder.provider.decode(IndexVersionHeader.self, from: indexData),
        let version = header.schemaVersion
      {
        if version > ConversationIndexState.currentSchemaVersion {
          throw ProviderError.conversationVersionUnsupported(version)
        }

        if version == ConversationIndexState.currentSchemaVersion,
          let index = try? JSONDecoder.provider.decode(ConversationIndexState.self, from: indexData),
          let catalog = try validatedCatalog(index.entries),
          Set(catalog.keys.map(\.rawValue)) == shardIDs
        {
          indexEntries = catalog
          state.tombstones = SyncTombstonePolicy.pruned(index.tombstones)
          hasLoaded = true
          return
        }
      }

      // Preserve deletion tombstones while rebuilding an old/stale index.
      if let old = try? JSONDecoder.provider.decode(IndexTombstones.self, from: indexData) {
        state.tombstones = old.tombstones ?? [:]
      }
    }

    // First run after the lazy-index upgrade (or a missing/stale index) does
    // one migration scan. Subsequent launches read index.json only.
    try await rebuildIndex(shardIDs: shardIDs)
    hasLoaded = true
  }

  /// Full portable snapshot. This is intentionally an on-demand operation and
  /// may load every shard; normal app startup never calls it.
  public func snapshot() async -> ConversationWorkspaceState {
    ConversationWorkspaceState(
      conversations: await allConversations(),
      tombstones: state.tombstones
    )
  }

  /// Lightweight objects synthesized from index.json. Their messages contain
  /// compact usage/attachment metadata only; content/reasoning stay in shards.
  public func conversationSummaries() -> [ChatConversation] {
    sortedIndexEntries().map(\.summaryConversation)
  }

  public func containsConversation(_ id: ConversationID) -> Bool {
    indexEntries[id] != nil
  }

  /// Returns a full conversation only when it is already hydrated in memory.
  public func cachedConversation(id: ConversationID) -> ChatConversation? {
    state.conversations.first { $0.id == id }
  }

  /// Attachment IDs remain available from the index, so app-level orphan GC
  /// never has to open every conversation shard at launch.
  public func referencedAttachmentIDs() -> Set<String> {
    Set(indexEntries.values.flatMap(\.referencedAttachmentIDs))
  }

  public func exportWorkspace() async throws -> Data {
    var exported = await snapshot()
    for conversationIndex in exported.conversations.indices {
      for messageIndex in exported.conversations[conversationIndex].messages.indices {
        guard
          let attachments = exported.conversations[conversationIndex].messages[messageIndex]
            .attachments,
          !attachments.isEmpty
        else { continue }
        var kept: [ChatAttachment] = []
        kept.reserveCapacity(attachments.count)
        for var attachment in attachments {
          if attachment.data.isEmpty {
            attachment.data = (try? await blobs.loadData(attachment.id)) ?? Data()
          }
          if !attachment.data.isEmpty { kept.append(attachment) }
        }
        exported.conversations[conversationIndex].messages[messageIndex].attachments =
          kept.isEmpty ? nil : kept
      }
    }
    return try JSONEncoder.providerEncoder.encode(exported)
  }

  /// Explicit full-corpus read for backup/analytics/library flows. This is not
  /// used by startup or the sidebar.
  public func allConversations() async -> [ChatConversation] {
    var values: [ChatConversation] = []
    values.reserveCapacity(indexEntries.count)
    for entry in sortedIndexEntries() {
      if let conversation = try? await loadConversation(id: entry.id, cache: true) {
        values.append(conversation)
      }
    }
    return values.sorted(by: Self.conversationSort)
  }

  /// Hydrates exactly one full shard on demand.
  public func conversation(id: ConversationID) async throws -> ChatConversation {
    try await loadConversation(id: id, cache: true)
  }

  @discardableResult
  public func createConversation(
    providerID: ProviderID,
    accountID: ProviderAccountID,
    modelID: ModelID,
    systemPrompt: String = "",
    options: ProviderRequestOptions = .init(),
    id: ConversationID = .init(),
    isIOSNewChat: Bool? = nil
  ) async throws -> ChatConversation {
    let value = ChatConversation(
      id: id,
      providerID: providerID,
      accountID: accountID,
      modelID: modelID,
      systemPrompt: systemPrompt,
      options: options,
      isIOSNewChat: isIOSNewChat
    )
    state.conversations.append(value)
    try await persist(conversationIDs: [value.id])
    return value
  }

  /// Reads durable state without trusting optimistic/cache mutations. Cleanup
  /// callers must also exclude in-flight writes in their lifecycle coordinator.
  public func persistedConversation(id: ConversationID) async throws -> ChatConversation? {
    guard let data = try await persistence.loadShard(id: id.rawValue) else { return nil }
    return try decodeShard(data, expectedID: id.rawValue).conversation
  }

  /// Restore a failed first append from its authoritative shard. A failed blob
  /// or shard write must not leave an unsaved user message in the mutable cache
  /// for the next draft save/retry to persist accidentally.
  public func restorePersistedConversation(id: ConversationID) async throws {
    // Evict first, even when the durable read fails. A later draft/save must
    // reload the shard rather than accidentally commit the failed append.
    state.conversations.removeAll { $0.id == id }
    deferredDirtyIDs.remove(id)
    guard var persisted = try await persistedConversation(id: id) else { return }
    let repaired = repairInterruptedMessages(in: &persisted)
    state.conversations.append(persisted)
    indexEntries[id] = ConversationIndexEntry(conversation: persisted)
    if repaired {
      try await persistence.saveShard(id: id.rawValue, data: shardData(persisted))
      try await persistIndex()
    }
  }

  public func deleteConversation(_ id: ConversationID) async throws {
    state.conversations.removeAll { $0.id == id }
    indexEntries.removeValue(forKey: id)
    deferredDirtyIDs.remove(id)
    state.tombstones[id.rawValue] = .now
    try await persistence.deleteShard(id: id.rawValue)
    try await persistIndex()
  }

  public func deleteAllConversations() async throws {
    guard !indexEntries.isEmpty else { return }
    let removedIDs = Array(indexEntries.keys)
    state.conversations.removeAll()
    indexEntries.removeAll()
    deferredDirtyIDs.removeAll()
    for id in removedIDs {
      state.tombstones[id.rawValue] = .now
    }
    try await persistence.deleteAllShards()
    try await persistIndex()
  }

  public func renameConversation(_ id: ConversationID, title: String) async throws {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw ProviderError.invalidRequest("Conversation title cannot be empty.")
    }
    try await ensureConversationLoaded(id)
    try mutateConversation(id) { conversation in
      conversation.title = trimmed
      conversation.updatedAt = .now
    }
    try await persist(conversationIDs: [id])
  }

  public func updateTarget(
    _ id: ConversationID,
    providerID: ProviderID,
    accountID: ProviderAccountID,
    modelID: ModelID,
    systemPrompt: String,
    options: ProviderRequestOptions
  ) async throws {
    try await ensureConversationLoaded(id)
    try mutateConversation(id) { conversation in
      conversation.providerID = providerID
      conversation.accountID = accountID
      conversation.modelID = modelID
      conversation.systemPrompt = systemPrompt
      conversation.options = options
      conversation.updatedAt = .now
    }
    try await persist(conversationIDs: [id])
  }

  public func setDraft(_ text: String, conversationID: ConversationID) async throws {
    try await ensureConversationLoaded(conversationID)
    try mutateConversation(conversationID) { conversation in
      let value = text.isEmpty ? nil : text
      guard conversation.draftText != value else { return }
      conversation.draftText = value
    }
    try await persist(conversationIDs: [conversationID])
  }

  /// Search is intentionally an on-demand corpus scan. It does not populate
  /// the normal conversation cache, so searching cannot turn startup laziness
  /// into permanent all-history memory usage.
  public func search(_ query: String, limit: Int = 100) async -> [ConversationSearchResult] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }

    var results: [ConversationSearchResult] = []
    for entry in sortedIndexEntries() {
      if entry.title.localizedCaseInsensitiveContains(trimmed) {
        results.append(
          ConversationSearchResult(
            conversationID: entry.id,
            messageID: nil,
            role: .title,
            title: entry.title,
            snippet: entry.title,
            updatedAt: entry.updatedAt
          )
        )
      }

      guard let conversation = try? await readConversationWithoutCaching(id: entry.id) else {
        continue
      }
      for message in conversation.messages where message.status == .complete {
        let contentMatches = message.content.localizedCaseInsensitiveContains(trimmed)
        let matchingAttachment = (message.attachments ?? []).first {
          $0.filename.localizedCaseInsensitiveContains(trimmed)
        }
        guard contentMatches || matchingAttachment != nil else { continue }
        results.append(
          ConversationSearchResult(
            conversationID: conversation.id,
            messageID: message.id,
            role: message.role == .user ? .user : .assistant,
            title: entry.title,
            snippet: contentMatches
              ? Self.searchSnippet(text: message.content, query: trimmed)
              : "Attachment: \(matchingAttachment?.filename ?? trimmed)",
            updatedAt: message.updatedAt
          )
        )
      }
    }

    return Array(
      results.sorted { lhs, rhs in
        if lhs.role == .title, rhs.role != .title { return true }
        if lhs.role != .title, rhs.role == .title { return false }
        return lhs.updatedAt > rhs.updatedAt
      }.prefix(max(1, limit))
    )
  }

  public func editUserMessageAndBeginTurn(
    conversationID: ConversationID,
    messageID: ChatMessageID,
    newText: String,
    at date: Date = .now
  ) async throws -> ChatHistoryMutation {
    let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw ProviderError.invalidMessages }
    try await ensureConversationLoaded(conversationID)

    var result: ChatHistoryMutation?
    try mutateConversation(conversationID) { conversation in
      guard let index = conversation.messages.firstIndex(where: { $0.id == messageID }) else {
        throw ProviderError.chatMessageNotFound(messageID)
      }
      guard conversation.messages[index].role == .user else {
        throw ProviderError.invalidRequest("Only user messages can be edited.")
      }

      let oldContent = conversation.messages[index].content
      let removedCount = conversation.messages.count - index - 1
      conversation.messages.removeSubrange((index + 1)..<conversation.messages.endIndex)
      conversation.messages[index].content = trimmed
      conversation.messages[index].updatedAt = date
      conversation.messages[index].status = .complete
      conversation.messages[index].providerID = conversation.providerID
      conversation.messages[index].accountID = conversation.accountID
      conversation.messages[index].modelID = conversation.modelID
      conversation.messages[index].errorCode = nil
      conversation.messages[index].errorDescription = nil
      conversation.messages[index].completionUncertain = false

      if index == 0
        && (conversation.title == "New Chat"
          || conversation.title == Self.generatedTitle(from: oldContent))
      {
        conversation.title = Self.generatedTitle(from: trimmed)
      }

      let assistant = Self.assistantPlaceholder(for: conversation, at: date)
      conversation.messages.append(assistant)
      conversation.updatedAt = date
      result = ChatHistoryMutation(
        turn: ChatTurnStart(
          conversationID: conversationID,
          userMessage: conversation.messages[index],
          assistantMessage: assistant
        ),
        removedMessageCount: removedCount
      )
    }
    try await persist(conversationIDs: [conversationID])
    return result!
  }

  public func beginRegeneration(
    conversationID: ConversationID,
    confirmingUncertainCompletion: Bool,
    at date: Date = .now
  ) async throws -> ChatHistoryMutation {
    try await ensureConversationLoaded(conversationID)
    var result: ChatHistoryMutation?
    try mutateConversation(conversationID) { conversation in
      guard let userIndex = conversation.messages.lastIndex(where: { $0.role == .user }) else {
        throw ProviderError.invalidRequest("There is no user message to regenerate.")
      }

      let laterMessages = conversation.messages[(userIndex + 1)..<conversation.messages.endIndex]
      if laterMessages.contains(where: { $0.completionUncertain == true })
        && !confirmingUncertainCompletion
      {
        throw ProviderError.uncertainCompletionConfirmationRequired
      }

      let removedCount = conversation.messages.count - userIndex - 1
      conversation.messages.removeSubrange((userIndex + 1)..<conversation.messages.endIndex)
      let assistant = Self.assistantPlaceholder(for: conversation, at: date)
      conversation.messages.append(assistant)
      conversation.updatedAt = date
      result = ChatHistoryMutation(
        turn: ChatTurnStart(
          conversationID: conversationID,
          userMessage: conversation.messages[userIndex],
          assistantMessage: assistant
        ),
        removedMessageCount: removedCount
      )
    }
    try await persist(conversationIDs: [conversationID])
    return result!
  }

  @discardableResult
  public func beginTurn(
    conversationID: ConversationID,
    userText: String,
    attachments: [ChatAttachment] = [],
    at date: Date = .now
  ) async throws -> ChatTurnStart {
    let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty || !attachments.isEmpty else { throw ProviderError.invalidMessages }
    try Self.validateAttachments(attachments)
    try await ensureConversationLoaded(conversationID)

    var result: ChatTurnStart?
    try mutateConversation(conversationID) { conversation in
      let user = ChatMessage(
        role: .user,
        content: trimmed,
        attachments: attachments.isEmpty ? nil : attachments,
        createdAt: date,
        updatedAt: date,
        status: .complete,
        providerID: conversation.providerID,
        accountID: conversation.accountID,
        modelID: conversation.modelID
      )
      let assistant = Self.assistantPlaceholder(for: conversation, at: date)
      conversation.messages.append(user)
      conversation.messages.append(assistant)
      conversation.draftText = nil
      conversation.updatedAt = date
      if conversation.title == "New Chat" || conversation.messages.count == 2 {
        let titleSource = trimmed.isEmpty ? (attachments.first?.filename ?? "Attachment") : trimmed
        conversation.title = Self.generatedTitle(from: titleSource)
      }
      result = ChatTurnStart(
        conversationID: conversationID,
        userMessage: user,
        assistantMessage: assistant
      )
    }
    try await persist(conversationIDs: [conversationID])
    return result!
  }

  public func updateStreamingMessage(
    conversationID: ConversationID,
    messageID: ChatMessageID,
    content: String,
    reasoning: String,
    usage: ProviderUsage? = nil,
    at date: Date = .now
  ) async throws {
    try await ensureConversationLoaded(conversationID)
    try mutateMessage(conversationID: conversationID, messageID: messageID) { message in
      message.content = content
      message.reasoning = reasoning
      if let usage { message.usage = usage }
      message.status = .streaming
      message.updatedAt = date
    }
    try mutateConversation(conversationID) { $0.updatedAt = date }
    markConversationDirty(conversationID)
  }

  public func appendToolRound(
    conversationID: ConversationID,
    messageID: ChatMessageID,
    round: ChatToolRound,
    at date: Date = .now
  ) async throws -> ChatMessage {
    try await ensureConversationLoaded(conversationID)
    var result: ChatMessage?
    try mutateMessage(conversationID: conversationID, messageID: messageID) { message in
      var rounds = message.toolRounds ?? []
      rounds.append(round)
      message.toolRounds = rounds
      message.content = ""
      message.reasoning = ""
      message.status = .streaming
      message.updatedAt = date
      result = message
    }
    try mutateConversation(conversationID) { $0.updatedAt = date }
    try await persist(conversationIDs: [conversationID])
    return result!
  }

  public func completeMessage(
    conversationID: ConversationID,
    messageID: ChatMessageID,
    response: ProviderResponse,
    at date: Date = .now
  ) async throws -> ChatMessage {
    try await ensureConversationLoaded(conversationID)
    var result: ChatMessage?
    try mutateMessage(conversationID: conversationID, messageID: messageID) { message in
      message.content = response.text
      message.reasoning = response.reasoning
      message.providerID = response.providerID
      message.accountID = response.accountID
      message.modelID = response.modelID
      message.finishReason = response.finishReason
      message.usage = response.usage
      message.providerContinuation = response.toolContinuation
      message.metadata = response.metadata
      message.status = .complete
      message.errorCode = nil
      message.errorDescription = nil
      message.completionUncertain = false
      message.updatedAt = date
      result = message
    }
    try mutateConversation(conversationID) { $0.updatedAt = date }
    try await persist(conversationIDs: [conversationID])
    return result!
  }

  public func cancelMessage(
    conversationID: ConversationID,
    messageID: ChatMessageID,
    content: String,
    reasoning: String,
    at date: Date = .now
  ) async throws -> ChatMessage {
    try await ensureConversationLoaded(conversationID)
    var result: ChatMessage?
    try mutateMessage(conversationID: conversationID, messageID: messageID) { message in
      message.content = content
      message.reasoning = reasoning
      message.status = .cancelled
      message.completionUncertain = false
      message.updatedAt = date
      result = message
    }
    try mutateConversation(conversationID) { $0.updatedAt = date }
    try await persist(conversationIDs: [conversationID])
    return result!
  }

  public func failMessage(
    conversationID: ConversationID,
    messageID: ChatMessageID,
    content: String,
    reasoning: String,
    error: Error,
    at date: Date = .now
  ) async throws -> ChatMessage {
    try await ensureConversationLoaded(conversationID)
    var result: ChatMessage?
    try mutateMessage(conversationID: conversationID, messageID: messageID) { message in
      message.content = content
      message.reasoning = reasoning
      message.status = .failed
      message.errorCode = Self.errorCode(error)
      message.errorDescription = Self.safeErrorDescription(error)
      message.completionUncertain = Self.completionIsUncertain(error)
      message.updatedAt = date
      result = message
    }
    try mutateConversation(conversationID) { $0.updatedAt = date }
    try await persist(conversationIDs: [conversationID])
    return result!
  }

  public func setContextOmissionCount(_ count: Int, conversationID: ConversationID) async throws {
    try await ensureConversationLoaded(conversationID)
    try mutateConversation(conversationID) { conversation in
      conversation.lastContextOmittedMessageCount = max(0, count)
    }
    try await persist(conversationIDs: [conversationID])
  }

  public func hydrateRequestAttachments(in messages: inout [ProviderMessage]) async throws {
    guard messages.contains(where: { !($0.attachments ?? []).isEmpty }) else { return }
    for messageIndex in messages.indices {
      guard let attachments = messages[messageIndex].attachments, !attachments.isEmpty else {
        continue
      }
      var kept: [ChatAttachment] = []
      kept.reserveCapacity(attachments.count)
      for var attachment in attachments where attachment.data.isEmpty {
        do {
          if let data = try await blobs.loadData(attachment.id), !data.isEmpty {
            attachment.data = data
          }
        } catch {
          // Keep read errors retryable rather than treating them as deletion.
        }
        if !attachment.data.isEmpty {
          kept.append(attachment)
        }
      }
      messages[messageIndex].attachments = kept.isEmpty ? nil : kept
    }
  }

  public func attachmentData(_ id: String) async -> Data? {
    guard !id.isEmpty else { return nil }
    return (try? await blobs.loadData(id)) ?? nil
  }

  public func attachmentThumbnail(_ id: String, maxPixelSize: CGFloat) async -> Data? {
    guard !id.isEmpty else { return nil }
    return (try? await blobs.thumbnailData(id, maxPixelSize: maxPixelSize)) ?? nil
  }

  public func attachmentMetadata(_ id: String) async -> AttachmentBlobMetadata? {
    guard !id.isEmpty else { return nil }
    return (try? await blobs.metadata(for: id)) ?? nil
  }

  // MARK: - Lazy shard loading / migration

  private func validatedCatalog(
    _ entries: [ConversationIndexEntry]
  ) throws -> [ConversationID: ConversationIndexEntry]? {
    var result: [ConversationID: ConversationIndexEntry] = [:]
    for entry in entries {
      if entry.shardSchemaVersion > ConversationShardRecord.currentSchemaVersion
        || entry.minimumReaderVersion > ConversationShardRecord.currentReaderVersion
      {
        throw ProviderError.conversationVersionUnsupported(entry.shardSchemaVersion)
      }
      guard result[entry.id] == nil else { return nil }
      result[entry.id] = entry
    }
    return result
  }

  private func rebuildIndex(shardIDs: Set<String>) async throws {
    var rebuilt: [ConversationID: ConversationIndexEntry] = [:]

    for shardID in shardIDs.sorted() {
      guard let data = try await persistence.loadShard(id: shardID) else { continue }
      do {
        let decoded = try decodeShard(data, expectedID: shardID)
        var conversation = decoded.conversation
        let didBackfill = await backfillAttachmentByteCounts(in: &conversation)
        let didRepair = repairInterruptedMessages(in: &conversation)
        if decoded.isLegacy || didBackfill || didRepair {
          try await persistence.saveShard(id: shardID, data: shardData(conversation))
        }
        rebuilt[conversation.id] = ConversationIndexEntry(conversation: conversation)
      } catch let error as ProviderError {
        if case .conversationVersionUnsupported = error {
          // Newer data is valid data. Never rename it to .corrupt.
          throw error
        }
        _ = try? await persistence.quarantineShard(id: shardID)
        quarantinedShardCount += 1
      } catch {
        _ = try? await persistence.quarantineShard(id: shardID)
        quarantinedShardCount += 1
      }
    }

    indexEntries = rebuilt
    state.conversations.removeAll()
    state.tombstones = SyncTombstonePolicy.pruned(state.tombstones)
    try await persistIndex()
  }

  private func loadConversation(id: ConversationID, cache: Bool) async throws -> ChatConversation {
    if let cached = state.conversations.first(where: { $0.id == id }) {
      return cached
    }
    guard indexEntries[id] != nil else {
      throw ProviderError.conversationNotFound(id)
    }
    guard let data = try await persistence.loadShard(id: id.rawValue) else {
      indexEntries.removeValue(forKey: id)
      try? await persistIndex()
      throw ProviderError.conversationNotFound(id)
    }

    do {
      let decoded = try decodeShard(data, expectedID: id.rawValue)
      var conversation = decoded.conversation
      let didBackfill = await backfillAttachmentByteCounts(in: &conversation)
      let didRepair = repairInterruptedMessages(in: &conversation)

      if cache {
        state.conversations.removeAll { $0.id == id }
        state.conversations.append(conversation)
      }

      let newEntry = ConversationIndexEntry(conversation: conversation)
      let indexChanged = indexEntries[id] != newEntry
      indexEntries[id] = newEntry

      if decoded.isLegacy || didBackfill || didRepair {
        if cache {
          try await persist(conversationIDs: [id])
        } else {
          try await persistence.saveShard(id: id.rawValue, data: shardData(conversation))
          try await persistIndex()
        }
      } else if indexChanged {
        try await persistIndex()
      }
      return conversation
    } catch let error as ProviderError {
      if case .conversationVersionUnsupported = error {
        throw error
      }
      try await quarantineUnreadableShard(id)
      throw error
    } catch {
      try await quarantineUnreadableShard(id)
      throw ProviderError.invalidRequest("Conversation data is unreadable.")
    }
  }

  private func readConversationWithoutCaching(id: ConversationID) async throws -> ChatConversation {
    if let cached = state.conversations.first(where: { $0.id == id }) {
      return cached
    }
    guard let data = try await persistence.loadShard(id: id.rawValue) else {
      throw ProviderError.conversationNotFound(id)
    }
    return try decodeShard(data, expectedID: id.rawValue).conversation
  }

  private func decodeShard(_ data: Data, expectedID: String) throws -> DecodedShard {
    let header = try? JSONDecoder.provider.decode(ShardVersionHeader.self, from: data)
    if let schemaVersion = header?.schemaVersion {
      let minimumReaderVersion = header?.minimumReaderVersion ?? schemaVersion
      if schemaVersion > ConversationShardRecord.currentSchemaVersion
        || minimumReaderVersion > ConversationShardRecord.currentReaderVersion
      {
        throw ProviderError.conversationVersionUnsupported(schemaVersion)
      }
      let record = try JSONDecoder.provider.decode(ConversationShardRecord.self, from: data)
      guard record.schemaVersion == schemaVersion else {
        throw ProviderError.invalidRequest("Conversation shard version metadata is inconsistent.")
      }
      guard record.conversation.id.rawValue == expectedID else {
        throw ProviderError.invalidRequest("Conversation shard identity does not match its filename.")
      }
      return DecodedShard(conversation: record.conversation, isLegacy: false)
    }

    // v0 migration: builds before the envelope stored a bare ChatConversation.
    let conversation = try JSONDecoder.provider.decode(ChatConversation.self, from: data)
    guard conversation.id.rawValue == expectedID else {
      throw ProviderError.invalidRequest("Conversation shard identity does not match its filename.")
    }
    return DecodedShard(conversation: conversation, isLegacy: true)
  }

  private func quarantineUnreadableShard(_ id: ConversationID) async throws {
    _ = try? await persistence.quarantineShard(id: id.rawValue)
    quarantinedShardCount += 1
    state.conversations.removeAll { $0.id == id }
    indexEntries.removeValue(forKey: id)
    try? await persistIndex()
  }

  private func ensureConversationLoaded(_ id: ConversationID) async throws {
    guard !state.conversations.contains(where: { $0.id == id }) else { return }
    _ = try await loadConversation(id: id, cache: true)
  }

  private func backfillAttachmentByteCounts(in conversation: inout ChatConversation) async -> Bool {
    var missingIDs: Set<String> = []
    for message in conversation.messages {
      for attachment in message.attachments ?? []
      where attachment.declaredByteCount == nil && attachment.data.isEmpty {
        missingIDs.insert(attachment.id)
      }
    }
    guard !missingIDs.isEmpty else { return false }

    var metadataByID: [String: Int] = [:]
    for id in missingIDs {
      if let metadata = try? await blobs.metadata(for: id), metadata.byteCount > 0 {
        metadataByID[id] = metadata.byteCount
      }
    }

    var changed = false
    for messageIndex in conversation.messages.indices {
      guard let attachments = conversation.messages[messageIndex].attachments else { continue }
      var repaired = attachments
      for attachmentIndex in repaired.indices where repaired[attachmentIndex].declaredByteCount == nil {
        if !repaired[attachmentIndex].data.isEmpty {
          repaired[attachmentIndex].declaredByteCount = repaired[attachmentIndex].data.count
        } else if let byteCount = metadataByID[repaired[attachmentIndex].id] {
          repaired[attachmentIndex].declaredByteCount = byteCount
        } else {
          continue
        }
        changed = true
      }
      conversation.messages[messageIndex].attachments = repaired
    }
    return changed
  }

  private func offloadAttachmentBlobs(for ids: Set<ConversationID>) async throws {
    for id in ids {
      guard let conversationIndex = state.conversations.firstIndex(where: { $0.id == id }) else {
        continue
      }
      let conversation = state.conversations[conversationIndex]
      for messageIndex in conversation.messages.indices {
        guard let attachments = conversation.messages[messageIndex].attachments,
          !attachments.isEmpty
        else { continue }
        var stored = attachments
        for attachmentIndex in stored.indices {
          let attachment = stored[attachmentIndex]
          guard !attachment.data.isEmpty else { continue }
          try await blobs.writeIfAbsent(
            attachment.id,
            data: attachment.data,
            metadata: AttachmentBlobMetadata(
              filename: attachment.filename,
              mimeType: attachment.mimeType,
              byteCount: attachment.data.count,
              createdAt: conversation.createdAt
            )
          )
          stored[attachmentIndex].data = Data()
          if stored[attachmentIndex].declaredByteCount == nil {
            stored[attachmentIndex].declaredByteCount = attachment.data.count
          }
        }
        state.conversations[conversationIndex].messages[messageIndex].attachments = stored
      }
    }
  }

  private func mutateConversation(
    _ id: ConversationID,
    mutation: (inout ChatConversation) throws -> Void
  ) throws {
    guard let index = state.conversations.firstIndex(where: { $0.id == id }) else {
      throw ProviderError.conversationNotFound(id)
    }
    try mutation(&state.conversations[index])
  }

  private func mutateMessage(
    conversationID: ConversationID,
    messageID: ChatMessageID,
    mutation: (inout ChatMessage) throws -> Void
  ) throws {
    try mutateConversation(conversationID) { conversation in
      guard let index = conversation.messages.firstIndex(where: { $0.id == messageID }) else {
        throw ProviderError.chatMessageNotFound(messageID)
      }
      try mutation(&conversation.messages[index])
    }
  }

  private static func assistantPlaceholder(
    for conversation: ChatConversation,
    at date: Date
  ) -> ChatMessage {
    ChatMessage(
      role: .assistant,
      createdAt: date,
      updatedAt: date,
      status: .pending,
      providerID: conversation.providerID,
      accountID: conversation.accountID,
      modelID: conversation.modelID
    )
  }

  private static func validateAttachments(_ attachments: [ChatAttachment]) throws {
    guard attachments.count <= 8 else {
      throw ProviderError.invalidRequest("A message can include at most 8 attachments.")
    }
    guard attachments.allSatisfy({
      (!$0.data.isEmpty || ($0.declaredByteCount ?? 0) > 0) && $0.byteCount <= 20 * 1_024 * 1_024
    }) else {
      throw ProviderError.invalidRequest("Each attachment must be non-empty and no larger than 20 MB.")
    }
    guard attachments.reduce(0, { $0 + $1.byteCount }) <= 40 * 1_024 * 1_024 else {
      throw ProviderError.invalidRequest("Attachments in one message cannot exceed 40 MB total.")
    }
  }

  private static func searchSnippet(text: String, query: String) -> String {
    let normalized = text.replacingOccurrences(of: "\n", with: " ")
    guard
      let range = normalized.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
    else {
      return String(normalized.prefix(160))
    }
    let matchOffset = normalized.distance(from: normalized.startIndex, to: range.lowerBound)
    let startOffset = max(0, matchOffset - 56)
    let endOffset = min(normalized.count, matchOffset + query.count + 96)
    let start = normalized.index(normalized.startIndex, offsetBy: startOffset)
    let end = normalized.index(normalized.startIndex, offsetBy: endOffset)
    let prefix = startOffset > 0 ? "…" : ""
    let suffix = endOffset < normalized.count ? "…" : ""
    return prefix + String(normalized[start..<end]) + suffix
  }

  private static func completionIsUncertain(_ error: Error) -> Bool {
    guard let providerError = error as? ProviderError else { return false }
    guard case .transport(_, let completionUnknown) = providerError else { return false }
    return completionUnknown
  }

  private func repairInterruptedMessages(in conversation: inout ChatConversation) -> Bool {
    var changed = false
    for messageIndex in conversation.messages.indices {
      let status = conversation.messages[messageIndex].status
      guard status == .pending || status == .streaming else { continue }
      conversation.messages[messageIndex].status = .interrupted
      conversation.messages[messageIndex].errorCode = "interrupted"
      conversation.messages[messageIndex].errorDescription =
        "Generation was interrupted before completion."
      conversation.messages[messageIndex].completionUncertain = false
      conversation.messages[messageIndex].updatedAt = .now
      changed = true
    }
    return changed
  }

  // MARK: - Sharded persistence

  private func persist(conversationIDs involved: Set<ConversationID>) async throws {
    let targets = involved.union(deferredDirtyIDs)
    try await offloadAttachmentBlobs(for: targets)
    for id in targets.map(\.rawValue).sorted() {
      guard let conversation = state.conversations.first(where: { $0.id.rawValue == id }) else {
        deferredDirtyIDs.remove(ConversationID(rawValue: id))
        continue
      }
      try await persistence.saveShard(id: id, data: shardData(conversation))
      indexEntries[conversation.id] = ConversationIndexEntry(conversation: conversation)
      deferredDirtyIDs.remove(conversation.id)
    }
    flushError = nil
    try await persistIndex()
  }

  private func markConversationDirty(_ id: ConversationID) {
    deferredDirtyIDs.insert(id)
    scheduleDeferredFlush()
  }

  private func scheduleDeferredFlush() {
    guard !isDeferredFlushScheduled else { return }
    isDeferredFlushScheduled = true
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(2))
      await self?.performDeferredFlushIfDue()
    }
  }

  private func performDeferredFlushIfDue() async {
    isDeferredFlushScheduled = false
    guard !deferredDirtyIDs.isEmpty else { return }
    do {
      try await persist(conversationIDs: [])
    } catch {
      flushError = error
    }
  }

  private func shardData(_ conversation: ChatConversation) throws -> Data {
    let record = ConversationShardRecord(conversation: conversation)
    return try JSONEncoder.providerEncoderWithoutAttachmentData.encode(record)
  }

  private func persistIndex() async throws {
    let index = ConversationIndexState(
      entries: sortedIndexEntries(),
      tombstones: state.tombstones
    )
    try await persistence.saveIndex(JSONEncoder.providerEncoder.encode(index))
  }

  private func sortedIndexEntries() -> [ConversationIndexEntry] {
    indexEntries.values.sorted { lhs, rhs in
      if lhs.updatedAt == rhs.updatedAt { return lhs.createdAt > rhs.createdAt }
      return lhs.updatedAt > rhs.updatedAt
    }
  }

  private static func conversationSort(_ lhs: ChatConversation, _ rhs: ChatConversation) -> Bool {
    if lhs.updatedAt == rhs.updatedAt { return lhs.createdAt > rhs.createdAt }
    return lhs.updatedAt > rhs.updatedAt
  }

  private static func generatedTitle(from text: String) -> String {
    let singleLine = text.replacingOccurrences(of: "\n", with: " ")
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
    guard singleLine.count > 52 else { return singleLine }
    return String(singleLine.prefix(49)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
  }

  private static func errorCode(_ error: Error) -> String {
    switch error {
    case is CancellationError: return "cancelled"
    case let value as ProviderError: return String(describing: value)
    default: return "unknown"
    }
  }

  private static func safeErrorDescription(_ error: Error) -> String {
    if let value = error as? LocalizedError, let description = value.errorDescription {
      return description
    }
    return "Generation failed."
  }
}
