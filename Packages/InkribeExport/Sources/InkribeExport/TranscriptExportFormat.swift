public enum TranscriptExportFormat: String, CaseIterable, Codable, Hashable, Sendable {
    case plainText = "txt"
    case markdown = "md"
    case srt
    case vtt

    public var fileExtension: String { rawValue }

    public var displayName: String {
        switch self {
        case .plainText: "Plain Text"
        case .markdown: "Markdown"
        case .srt: "SRT Subtitles"
        case .vtt: "WebVTT Subtitles"
        }
    }

    public var isSubtitle: Bool {
        switch self {
        case .srt, .vtt: true
        case .plainText, .markdown: false
        }
    }

    public var supportsTextSourceSelection: Bool {
        !isSubtitle
    }
}

public enum TranscriptTextSource: String, CaseIterable, Codable, Hashable, Sendable {
    case edited
    case raw

    public var displayName: String {
        switch self {
        case .edited: "Edited"
        case .raw: "Raw"
        }
    }
}
