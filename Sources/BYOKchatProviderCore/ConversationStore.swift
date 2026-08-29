import Foundation

// The conversation workspace persistence lives in ConversationShardPersistence.swift:
// one shard file per conversation plus a derived index cache.

public actor ConversationStore {
  private let persistence: any ConversationWorkspacePersistence
  private let blobs: any AttachmentBlobStoring
  private var state = ConversationWorkspaceState()
  private var hasLoaded = false
  /// Conversations mutated by streaming deltas awaiting the debounced flush.
  private var deferredDirtyIDs: Set<ConversationID> = []
  private var isDeferredFlushScheduled = false
  /// Best-effort record of a failed debounced flush; hard persists retry the
  /// same conversations and clear it on success.
  public private(set) var flushError: Error?
  /// Shards quarantined as unreadable during load. Those conversations are
  /// skipped rather than failing the whole workspace.
  public private(set) var quarantinedShardCount = 0

  public init(
    persistence: any ConversationWorkspacePersistence,
    blobs: any AttachmentBlobStoring = InMemoryAttachmentBlobStore()
  ) {
    self.persistence = persistence
    self.blobs = blobs
  }

  public func load() async throws {
    guard !hasLoaded else { return }
    // Shards are authoritative; the index cache is rebuilt, never trusted.
    var loaded: [ChatConversation] = []
    for id in try await persistence.shardIDs() {
      guard let data = try await persistence.loadShard(id: id) else { continue }
      do {
        loaded.append(try JSONDecoder.provider.decode(ChatConversation.self, from: data))
      } catch {
        _ = try? await persistence.quarantineShard(id: id)
        quarantinedShardCount += 1
      }
    }
    state = ConversationWorkspaceState(conversations: loaded)
    // Rows above are authoritative; the index contributes only its
    // tombstones (deletions live nowhere else once shards are gone).
    if let indexData = try await persistence.loadIndex(),
      let index = try? JSONDecoder.provider.decode(ConversationIndexState.self, from: indexData)
    {
      state.tombstones = index.tombstones.merging(state.tombstones) { max($0, $1) }
    }
    state.tombstones = SyncTombstonePolicy.pruned(state.tombstones)
    await backfillAttachmentByteCounts()
    hasLoaded = true
    let repairedIDs = repairInterruptedMessages()
    if !repairedIDs.isEmpty {
      // Repairs must reach disk, not just memory, or every launch re-repairs.
      try await persist(conversationIDs: repairedIDs)
    } else if !state.conversations.isEmpty {
      try await persistIndex()
    }
  }

  public func snapshot() -> ConversationWorkspaceState { state }

  /// Attachment IDs still referenced anywhere in history, for the app-level
  /// blob GC. Reads authoritative state so a half-refreshed UI snapshot can
  /// never make live blobs look collectable.
  public func referencedAttachmentIDs() -> Set<String> {
    Set(
      state.conversations.flatMap { conversation in
        conversation.messages.flatMap { message in
          (message.attachments ?? []).map(\.id)
        }
      }
    )
  }

  /// Encodes every conversation with attachment bytes fetched from disk at
  /// export time, so backups stay self-contained regardless of which chats
  /// this session has open. Attachments whose bytes are gone are left out:
  /// import validation rejects empty payloads.
  public func exportWorkspace() async throws -> Data {
    var exported = state
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

  public func allConversations() -> [ChatConversation] {
    state.conversations.sorted { lhs, rhs in
      if lhs.updatedAt == rhs.updatedAt { return lhs.createdAt > rhs.createdAt }
      return lhs.updatedAt > rhs.updatedAt
    }
  }

  public func conversation(id: ConversationID) throws -> ChatConversation {
    guard let value = state.conversations.first(where: { $0.id == id }) else {
      throw ProviderError.conversationNotFound(id)
    }
    return value
  }

  @discardableResult
  public func createConversation(
    providerID: ProviderID,
    accountID: ProviderAccountID,
    modelID: ModelID,
    systemPrompt: String = "",
    options: ProviderRequestOptions = .init()
  ) async throws -> ChatConversation {
    let value = ChatConversation(
      providerID: providerID,
      accountID: accountID,
      modelID: modelID,
      systemPrompt: systemPrompt,
      options: options
    )
    state.conversations.append(value)
    try await persist(conversationIDs: [value.id])
    return value
  }

  public func deleteConversation(_ id: ConversationID) async throws {
    state.conversations.removeAll { $0.id == id }
    deferredDirtyIDs.remove(id)
    state.tombstones[id.rawValue] = .now
    try await persistence.deleteShard(id: id.rawValue)
    try await persistIndex()
    // Orphaned blobs are swept by the app-level sweepOrphanFiles.
  }

  /// Bulk removal used by replace-existing imports; one pass + one sweep
  /// instead of one per conversation.
  public func deleteAllConversations() async throws {
    guard !state.conversations.isEmpty else { return }
    let removed = state.conversations
    state.conversations.removeAll()
    deferredDirtyIDs.removeAll()
    for conversation in removed {
      state.tombstones[conversation.id.rawValue] = .now
    }
    try await persistence.deleteAllShards()
    try await persistIndex()
    // Orphaned blobs are swept by the app-level sweepOrphanFiles.
  }

  public func renameConversation(_ id: ConversationID, title: String) async throws {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw ProviderError.invalidRequest("Conversation title cannot be empty.")
    }
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
    try mutateConversation(conversationID) { conversation in
      let value = text.isEmpty ? nil : text
      guard conversation.draftText != value else { return }
      conversation.draftText = value
    }
    try await persist(conversationIDs: [conversationID])
  }

  public func search(_ query: String, limit: Int = 100) -> [ConversationSearchResult] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }

    var results: [ConversationSearchResult] = []
    for conversation in state.conversations {
      if conversation.title.localizedCaseInsensitiveContains(trimmed) {
        results.append(
          ConversationSearchResult(
            conversationID: conversation.id,
            messageID: nil,
            role: .title,
            title: conversation.title,
            snippet: conversation.title,
            updatedAt: conversation.updatedAt
          )
        )
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
            title: conversation.title,
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
    try mutateMessage(conversationID: conversationID, messageID: messageID) { message in
      message.content = content
      message.reasoning = reasoning
      if let usage { message.usage = usage }
      message.status = .streaming
      message.updatedAt = date
    }
    try mutateConversation(conversationID) { $0.updatedAt = date }
    // Streaming deltas only dirty memory here; a debounced flush lands them.
    markConversationDirty(conversationID)
  }

  public func appendToolRound(
    conversationID: ConversationID,
    messageID: ChatMessageID,
    round: ChatToolRound,
    at date: Date = .now
  ) async throws -> ChatMessage {
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
    var result: ChatMessage?
    try mutateMessage(conversationID: conversationID, messageID: messageID) { message in
      message.content = response.text
      message.reasoning = response.reasoning
      message.providerID = response.providerID
      message.accountID = response.accountID
      message.modelID = response.modelID
      message.finishReason = response.finishReason
      message.usage = response.usage
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
    try mutateConversation(conversationID) { conversation in
      conversation.lastContextOmittedMessageCount = max(0, count)
    }
    try await persist(conversationIDs: [conversationID])
  }

  /// Fills the blob bytes of every attachment referenced by the given
  /// request messages, called just before the provider request is built.
  /// Rows are metadata-only in memory; this is the only send-path fetch, and
  /// it covers exactly the messages in the built context (omitted history is
  /// never read). Attachments whose blob is missing are dropped from the
  /// message — request builders reject empty payloads. A read error leaves
  /// the row as-is so a later send can retry.
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
          // A read error is not evidence the blob is gone; keep the row so a
          // later send retries instead of silently stripping the file.
        }
        // Adapters reject empty payloads; a confirmed-missing blob (read
        // returned nil) drops the attachment from the request, while the
        // stored row itself is untouched and still displays "unavailable".
        if !attachment.data.isEmpty {
          kept.append(attachment)
        }
      }
      messages[messageIndex].attachments = kept.isEmpty ? nil : kept
    }
  }

  /// Pass-through byte access for surfaces that need the original on demand
  /// (QuickLook, share, save). nil when the blob is missing.
  public func attachmentData(_ id: String) async -> Data? {
    guard !id.isEmpty else { return nil }
    return (try? await blobs.loadData(id)) ?? nil
  }

  /// Pass-through thumbnail access; the store persists the downsampled
  /// derivative so later requests skip regeneration.
  public func attachmentThumbnail(_ id: String, maxPixelSize: CGFloat) async -> Data? {
    guard !id.isEmpty else { return nil }
    return (try? await blobs.thumbnailData(id, maxPixelSize: maxPixelSize)) ?? nil
  }

  /// Blob metadata by ID. nil when the blob is not stored or the store keeps
  /// no index entry for it.
  public func attachmentMetadata(_ id: String) async -> AttachmentBlobMetadata? {
    guard !id.isEmpty else { return nil }
    return (try? await blobs.metadata(for: id)) ?? nil
  }

  /// Rows are metadata-only in memory; sizes shown by tiles and pickers come
  /// from `declaredByteCount`. Shards written before that field existed are
  /// repaired here from the blob store's index so their surfaces do not read
  /// as zero bytes. Best-effort: an unavailable index leaves the shard as-is.
  private func backfillAttachmentByteCounts() async {
    var missingIDs: Set<String> = []
    for conversation in state.conversations {
      for message in conversation.messages {
        for attachment in message.attachments ?? []
        where attachment.declaredByteCount == nil && attachment.data.isEmpty {
          missingIDs.insert(attachment.id)
        }
      }
    }
    guard !missingIDs.isEmpty else { return }

    var metadataByID: [String: Int] = [:]
    for id in missingIDs {
      if let metadata = try? await blobs.metadata(for: id), metadata.byteCount > 0 {
        metadataByID[id] = metadata.byteCount
      }
    }

    var changedConversations: Set<ConversationID> = []
    for conversationIndex in state.conversations.indices {
      for messageIndex in state.conversations[conversationIndex].messages.indices {
        guard
          let attachments = state.conversations[conversationIndex].messages[messageIndex]
            .attachments
        else { continue }
        var repaired = attachments
        for attachmentIndex in repaired.indices
        where repaired[attachmentIndex].declaredByteCount == nil {
          if !repaired[attachmentIndex].data.isEmpty {
            repaired[attachmentIndex].declaredByteCount = repaired[attachmentIndex].data.count
          } else if let byteCount = metadataByID[repaired[attachmentIndex].id] {
            repaired[attachmentIndex].declaredByteCount = byteCount
          } else {
            continue
          }
          changedConversations.insert(state.conversations[conversationIndex].id)
        }
        state.conversations[conversationIndex].messages[messageIndex].attachments = repaired
      }
    }
    guard !changedConversations.isEmpty else { return }
    // Repairs must reach disk or every launch repeats the backfill.
    try? await persist(conversationIDs: changedConversations)
  }

  /// Writes any not-yet-stored payloads of the given conversations to blob
  /// files before their shard JSON lands. Crash between the two steps leaves
  /// an orphan blob (cleaned by the sweep), never a metadata row pointing at
  /// nothing. Rows drop their in-memory bytes once stored — metadata-only is
  /// the live shape too; surfaces re-fetch on demand.
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
    // `declaredByteCount` keeps validation working on metadata-only rows
    // (re-sent history attachments hold no bytes until the runtime refetches).
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

  private func repairInterruptedMessages() -> Set<ConversationID> {
    var changed: Set<ConversationID> = []
    for conversationIndex in state.conversations.indices {
      for messageIndex in state.conversations[conversationIndex].messages.indices {
        let status = state.conversations[conversationIndex].messages[messageIndex].status
        guard status == .pending || status == .streaming else { continue }
        state.conversations[conversationIndex].messages[messageIndex].status = .interrupted
        state.conversations[conversationIndex].messages[messageIndex].errorCode = "interrupted"
        state.conversations[conversationIndex].messages[messageIndex].errorDescription =
          "Generation was interrupted before completion."
        state.conversations[conversationIndex].messages[messageIndex].completionUncertain = false
        state.conversations[conversationIndex].messages[messageIndex].updatedAt = .now
        changed.insert(state.conversations[conversationIndex].id)
      }
    }
    return changed
  }

  // MARK: - Sharded persistence

  /// Persists the given conversations' shards plus the derived index. The
  /// deferred (streaming) dirty set rides along so a hard flush after a turn
  /// also lands any deltas still waiting on the debounce timer.
  private func persist(conversationIDs involved: Set<ConversationID>) async throws {
    let targets = involved.union(deferredDirtyIDs)
    try await offloadAttachmentBlobs(for: targets)
    for id in targets.map(\.rawValue).sorted() {
      guard
        let conversation = state.conversations.first(where: { $0.id.rawValue == id })
      else {
        // Stale dirt for a conversation that no longer exists.
        deferredDirtyIDs.remove(ConversationID(rawValue: id))
        continue
      }
      try await persistence.saveShard(id: id, data: shardData(conversation))
      deferredDirtyIDs.remove(conversation.id)
    }
    flushError = nil
    try await persistIndex()
  }

  private func markConversationDirty(_ id: ConversationID) {
    deferredDirtyIDs.insert(id)
    scheduleDeferredFlush()
  }

  /// Streaming deltas mutate memory immediately but land on disk at most ~2s
  /// later, so a long reply costs a handful of single-shard writes instead of
  /// one whole-corpus write per delta. Crash exposure stays within the
  /// current turn — the same window the interrupted-repair pass covers.
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
    try JSONEncoder.providerEncoderWithoutAttachmentData.encode(conversation)
  }

  private func persistIndex() async throws {
    let index = ConversationIndexState(
      entries: state.conversations.map(ConversationIndexEntry.init),
      tombstones: state.tombstones
    )
    try await persistence.saveIndex(JSONEncoder.providerEncoder.encode(index))
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
