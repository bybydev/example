public enum TranscriptAIAction: String, CaseIterable, Codable, Sendable {
    case clean
    case polish
    case summarize
    case notes
    case actionItems
}
