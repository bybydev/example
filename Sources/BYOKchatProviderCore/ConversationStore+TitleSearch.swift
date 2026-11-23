import Foundation

extension ConversationStore {
  /// Index-only chat title search used by Free tier and lightweight surfaces.
  /// Message content stays in sharded conversation files and is never read.
  public func searchTitles(_ query: String, limit: Int = 100) -> [ConversationSearchResult] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }

    let cap = max(1, limit)
    var results: [ConversationSearchResult] = []
    results.reserveCapacity(min(cap, 32))

    for conversation in conversationSummaries() {
      guard
        conversation.title.range(
          of: trimmed,
          options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
      else { continue }
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
      if results.count == cap { break }
    }

    return results
  }
}
