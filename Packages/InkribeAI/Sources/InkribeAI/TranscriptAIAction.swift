import InkribeCore

public enum TranscriptAIAction: String, CaseIterable, Codable, Hashable, Sendable {
    case clean
    case polish
    case summarize
    case notes
    case actionItems

    public var derivedDocumentKind: DerivedDocumentKind {
        switch self {
        case .clean: .cleanedCopy
        case .polish: .polishedCopy
        case .summarize: .summary
        case .notes: .notes
        case .actionItems: .actionItems
        }
    }

    public var supportsEditedTextReplacement: Bool {
        switch self {
        case .clean, .polish: true
        case .summarize, .notes, .actionItems: false
        }
    }

    var maximumOutputTokens: Int {
        switch self {
        case .clean, .polish: 1_024
        case .summarize, .actionItems: 512
        case .notes: 768
        }
    }

    var samplingTemperature: Float {
        switch self {
        case .clean, .polish: 0.1
        case .summarize, .notes, .actionItems: 0.2
        }
    }
}
