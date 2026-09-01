import Foundation

extension ConversationStore {
  /// Sidebar search is intentionally index-only. Message content stays in
  /// sharded conversation files and is never read just to search chat titles.
  public func search(_ query: String) -> [ConversationSearchResult] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }

    var results: [ConversationSearchResult] = []
    results.reserveCapacity(32)

    for conversation in conversationSummaries() {
      guard conversation.title.localizedCaseInsensitiveContains(trimmed) else { continue }
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
      if results.count == 100 { break }
    }

    return results
  }
}
