import Foundation
import Testing

@testable import BYOKchatProviderCore

@Suite("Conversation full-text search index")
struct ConversationSearchIndexTests {
  private func makeTempDatabaseURL() -> (directory: URL, databaseURL: URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("byok-fts-tests-\(UUID().uuidString)", isDirectory: true)
    let databaseURL = directory.appendingPathComponent("conversations-fts.sqlite", isDirectory: false)
    return (directory, databaseURL)
  }

  @Test("FTS5 index supports multi-word, prefix, diacritic, and punctuation-safe queries")
  func ftsQueriesAndSnippets() async throws {
    let (dir, dbURL) = makeTempDatabaseURL()
    defer { try? FileManager.default.removeItem(at: dir) }

    let persistence = InMemoryConversationWorkspacePersistence()
    let searchIndex = ConversationSearchIndexStore(databaseURL: dbURL)
    let store = ConversationStore(persistence: persistence, searchIndex: searchIndex)
    try await store.load()
    await store.setFullTextSearchEnabled(true)

    let chat = try await store.createConversation(
      providerID: "openai",
      accountID: "acct-1",
      modelID: "gpt-4o"
    )
    let turn = try await store.beginTurn(
      conversationID: chat.id,
      userText: "Explain café résumé indexing with SQLite FTS5",
      attachments: [
        ChatAttachment(
          kind: .file,
          filename: "architecture-blueprint.pdf",
          mimeType: "application/pdf",
          data: Data("pdf".utf8)
        )
      ]
    )
    _ = try await store.completeMessage(
      conversationID: chat.id,
      messageID: turn.assistantMessage.id,
      response: ProviderResponse(
        text: "SQLite FTS5 tokenizes documents efficiently for instant full-text lookup.",
        reasoning: "Internal hidden reasoning secret-token-xyz should stay excluded.",
        providerID: "openai",
        accountID: "acct-1",
        modelID: "gpt-4o"
      )
    )

    // Multi-word non-adjacent + prefix match via FTS5.
    let multiWord = await store.searchFullTextWithMetrics("sqlite lookup")
    #expect(multiWord.usedFTSIndex)
    #expect(multiWord.results.contains { $0.messageID == turn.assistantMessage.id })

    // Diacritic-insensitive matching.
    let diacritic = await store.searchFullText("cafe resume")
    #expect(diacritic.contains { $0.messageID == turn.userMessage.id })

    // Attachment filename matching produces Attachment snippet.
    let attachment = await store.searchFullText("blueprint")
    let attachmentHit = try #require(attachment.first { $0.messageID == turn.userMessage.id })
    #expect(attachmentHit.snippet == "Attachment: architecture-blueprint.pdf")

    // Reasoning stays excluded.
    let reasoningHit = await store.searchFullText("secret-token-xyz")
    #expect(reasoningHit.isEmpty)

    // Special FTS5 operator characters do not throw or break queries.
    let punctuation = await store.searchFullText("SQLite: \"FTS5\" OR NOT (lookup)*")
    #expect(punctuation.contains { $0.messageID == turn.assistantMessage.id })
    #expect(await store.searchFullText("??? --- !!!").isEmpty)
  }

  @Test("Cancelled partial responses are indexed and edit/regeneration truncations prune old messages")
  func incrementalMutationsAndTruncations() async throws {
    let (dir, dbURL) = makeTempDatabaseURL()
    defer { try? FileManager.default.removeItem(at: dir) }

    let persistence = InMemoryConversationWorkspacePersistence()
    let searchIndex = ConversationSearchIndexStore(databaseURL: dbURL)
    let store = ConversationStore(persistence: persistence, searchIndex: searchIndex)
    try await store.load()
    await store.setFullTextSearchEnabled(true)

    let chat = try await store.createConversation(
      providerID: "openai",
      accountID: "acct-1",
      modelID: "gpt-4o"
    )
    let firstTurn = try await store.beginTurn(
      conversationID: chat.id,
      userText: "First prompt alpha"
    )
    _ = try await store.cancelMessage(
      conversationID: chat.id,
      messageID: firstTurn.assistantMessage.id,
      content: "Partial cancelled answer nebula",
      reasoning: ""
    )

    #expect(await store.searchFullText("nebula").count == 1)

    // Regenerating drops the cancelled assistant response from FTS immediately.
    let regen = try await store.beginRegeneration(
      conversationID: chat.id,
      confirmingUncertainCompletion: false
    )
    #expect(await store.searchFullText("nebula").isEmpty)

    _ = try await store.completeMessage(
      conversationID: chat.id,
      messageID: regen.turn.assistantMessage.id,
      response: ProviderResponse(
        text: "Fresh regenerated answer pulsar",
        providerID: "openai",
        accountID: "acct-1",
        modelID: "gpt-4o"
      )
    )
    #expect(await store.searchFullText("pulsar").count == 1)

    // Editing the user message replaces its text and drops the trailing assistant reply.
    _ = try await store.editUserMessageAndBeginTurn(
      conversationID: chat.id,
      messageID: firstTurn.userMessage.id,
      newText: "Edited prompt quasar"
    )
    #expect(await store.searchFullText("pulsar").isEmpty)
    #expect(await store.searchFullText("alpha").isEmpty)
    #expect(await store.searchFullText("quasar").contains { $0.messageID == firstTurn.userMessage.id })

    // Deleting the conversation removes all FTS rows.
    try await store.deleteConversation(chat.id)
    #expect(await store.searchFullText("quasar").isEmpty)
    let status = await store.searchIndexStatus()
    #expect(status.statistics.indexedConversationCount == 0)
  }

  @Test("Launch remains lazy with zero shard reads and title search never reads shards")
  func launchAndTitleSearchStayLazy() async throws {
    let (dir, dbURL) = makeTempDatabaseURL()
    defer { try? FileManager.default.removeItem(at: dir) }

    let conversation = ChatConversation(
      id: "lazy-fts-chat",
      title: "Quarterly Roadmap",
      providerID: "openai",
      accountID: "acct-1",
      modelID: "gpt-4o",
      messages: [
        ChatMessage(role: .user, content: "secret body phrase", status: .complete)
      ]
    )
    let record = ConversationShardRecord(conversation: conversation)
    let shard = try JSONEncoder.providerEncoderWithoutAttachmentData.encode(record)
    let index = ConversationIndexState(entries: [ConversationIndexEntry(conversation: conversation)])
    let indexData = try JSONEncoder.providerEncoder.encode(index)

    let persistence = InMemoryConversationWorkspacePersistence(
      shards: [conversation.id.rawValue: shard]
    )
    await persistence.saveIndex(indexData)

    let searchIndex = ConversationSearchIndexStore(databaseURL: dbURL)
    let store = ConversationStore(persistence: persistence, searchIndex: searchIndex)
    try await store.load()

    // Startup and Free title search never touch shards or create the FTS database.
    #expect(await persistence.shardLoadCount() == 0)
    let titleResults = await store.searchTitles("roadmap")
    #expect(titleResults.map(\.conversationID) == [conversation.id])
    #expect(await store.searchTitles("secret body").isEmpty)
    #expect(await persistence.shardLoadCount() == 0)

    let disabledStatus = await store.searchIndexStatus()
    #expect(disabledStatus.phase == .disabled)
    #expect(!disabledStatus.statistics.databaseExists)

    // Enabling Pro and reconciling indexes the shard once; subsequent reconciles read 0 shards.
    await store.setFullTextSearchEnabled(true)
    await store.reconcileSearchIndex()
    #expect(await persistence.shardLoadCount() == 1)

    await store.reconcileSearchIndex()
    #expect(await persistence.shardLoadCount() == 1)

    let readyStatus = await store.searchIndexStatus()
    #expect(readyStatus.phase == .ready)
    #expect(readyStatus.staleConversationCount == 0)
    #expect(readyStatus.statistics.indexedConversationCount == 1)

    let fullTextHits = await store.searchFullText("secret body")
    #expect(fullTextHits.count == 1)
    #expect(await persistence.shardLoadCount() == 1)
  }

  @Test("Corrupted FTS SQLite file self-heals on next query")
  func corruptDatabaseSelfHeals() async throws {
    let (dir, dbURL) = makeTempDatabaseURL()
    defer { try? FileManager.default.removeItem(at: dir) }

    let persistence = InMemoryConversationWorkspacePersistence()
    let searchIndex = ConversationSearchIndexStore(databaseURL: dbURL)
    let store = ConversationStore(persistence: persistence, searchIndex: searchIndex)
    try await store.load()
    await store.setFullTextSearchEnabled(true)

    let chat = try await store.createConversation(
      providerID: "openai",
      accountID: "acct-1",
      modelID: "gpt-4o"
    )
    _ = try await store.beginTurn(
      conversationID: chat.id,
      userText: "Recoverable search content phoenix"
    )
    #expect(await store.searchFullText("phoenix").count == 1)

    // Corrupt the database file while closed.
    await searchIndex.close()
    try Data("corrupted-not-a-sqlite-header".utf8).write(to: dbURL, options: .atomic)

    let healed = await store.searchFullTextWithMetrics("phoenix")
    #expect(healed.usedFTSIndex)
    #expect(healed.results.count == 1)
  }
}
