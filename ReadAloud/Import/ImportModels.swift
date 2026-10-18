import Foundation
import PDFKitAudio
import TextExtractorWeb

nonisolated enum ReadAloudImportSource: Sendable, Equatable {
    case file(URL)
    case pastedText(String, suggestedTitle: String?)
    case web(URL)
}

nonisolated enum ReadAloudImportKind: String, Sendable, Equatable {
    case epub
    case pdf
    case document
    case paste
    case article
}

nonisolated enum ReadAloudImportStage: String, Sendable, Equatable {
    case preparing
    case extracting
    case normalizing
    case persisting
    case finished
}

nonisolated struct ReadAloudImportProgress: Sendable, Equatable {
    let stage: ReadAloudImportStage
    let fractionCompleted: Double?
    let detail: String?

    init(
        stage: ReadAloudImportStage,
        fractionCompleted: Double? = nil,
        detail: String? = nil
    ) {
        self.stage = stage
        self.fractionCompleted = fractionCompleted.map {
            min(1, max(0, $0))
        }
        self.detail = detail
    }
}

nonisolated enum ReadAloudImportDiagnosticSeverity: String, Sendable, Equatable {
    case info
    case warning
}

nonisolated struct ReadAloudImportDiagnostic: Sendable, Equatable {
    let severity: ReadAloudImportDiagnosticSeverity
    let code: String
    let message: String
    let sourceLocator: String?
}

nonisolated struct NormalizedImportItem: Sendable, Equatable {
    let id: UUID
    let title: String
    let order: Int
    let normalizedText: String
    let sourceLocator: ProjectSourceLocator
    let parentID: UUID?

    init(
        id: UUID = UUID(),
        title: String,
        order: Int,
        normalizedText: String,
        sourceLocator: ProjectSourceLocator,
        parentID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.order = order
        self.normalizedText = normalizedText
        self.sourceLocator = sourceLocator
        self.parentID = parentID
    }
}

nonisolated struct NormalizedImportArtwork: Sendable, Equatable {
    let data: Data
    let fileExtension: String
}

nonisolated struct NormalizedImportDocument: Sendable, Equatable {
    let kind: ReadAloudImportKind
    let title: String
    let author: String?
    let items: [NormalizedImportItem]
    let artwork: NormalizedImportArtwork?
    let diagnostics: [ReadAloudImportDiagnostic]
    // Additional parser output; normalized text remains the current read/play input.
    var parsedOutput: ParsedImportOutput? = nil
}

/// Serializable copies of the output parsers already provide. These are cached
/// before app-level filtering; they do not infer roles absent from a parser.
nonisolated enum ParsedImportOutput: Codable, Equatable, Sendable {
    case pdf(result: PdfReadingResult, chapters: [ParsedPDFChapter])
    case epub(ParsedEPUBDocument)
    case document(ParsedTextDocument)
    case article(WebArticleResult)
    case paste(rawText: String)

    var sourceType: ProjectSourceType {
        switch self {
        case .pdf: return .pdf
        case .epub: return .epub
        case .document: return .document
        case .article: return .article
        case .paste: return .paste
        }
    }

    /// Change deliberately when the cached output contract becomes incompatible.
    /// A miss never authorizes parsing; the caller must obtain user initiation.
    static func producerID(for type: ProjectSourceType) -> String {
        switch type {
        case .pdf: return "PDFKitAudio-1.2.0/include-all-v1"
        case .epub: return "EpubKit-1.1.0/default-v1"
        case .document: return "TextExtractor-1.2.0/default-v1"
        case .article: return "TextExtractorWeb-1.2.0/article-v1"
        case .paste: return "ReadAloud/paste-v1"
        }
    }
}

nonisolated struct ParsedPDFChapter: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let order: Int
    let firstPage: Int
    let lastPage: Int
    let sourceElementIDs: [String]
}

nonisolated struct ParsedEPUBDocument: Codable, Equatable, Sendable {
    let title: String?
    let creators: [String]
    let language: String?
    let identifiers: [String]
    let publisher: String?
    let modified: String?
    let renditionLayout: String?
    let chapters: [Chapter]
    let tableOfContents: [TOCItem]
    let diagnostics: [Diagnostic]
    // Cover bytes are already stored separately in cache/artwork.

    struct Chapter: Codable, Equatable, Sendable {
        let id: String
        let order: Int
        let title: String?
        let href: String
        let mediaType: String
        let properties: [String]
        let text: String
    }

    struct TOCItem: Codable, Equatable, Sendable {
        let id: String
        let title: String
        let href: String?
        let children: [TOCItem]
    }

    struct Diagnostic: Codable, Equatable, Sendable {
        let severity: String
        let message: String
        let path: String?
    }
}

nonisolated struct ParsedTextDocument: Codable, Equatable, Sendable {
    let title: String
    let sourceURL: URL?
    let format: String
    let text: String
    let rawText: String?
    let segments: [Segment]
    let metadata: [String: String]
    let warnings: [Warning]

    struct Segment: Codable, Equatable, Sendable {
        let id: String
        let text: String
        let startTime: TimeInterval?
        let endTime: TimeInterval?
        let metadata: [String: String]
    }

    struct Warning: Codable, Equatable, Sendable {
        let code: String
        let message: String
    }
}

/// Optional sidecar. Its identity is independent of selected filters and text
/// revisions; renaming a chapter or changing narration does not invalidate it.
nonisolated struct ParsedImportCache: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    // Whole-book parser output includes source attribution in addition to text;
    // use a separate bound from the existing per-chapter JSON limit.
    static let maximumBytes = 64 * 1_024 * 1_024
    let schemaVersion: Int
    let sourceID: UUID
    let sourceRevision: String
    let sourceType: ProjectSourceType
    let producerID: String
    let itemMappings: [ItemMapping]
    let output: ParsedImportOutput

    struct ItemMapping: Codable, Equatable, Sendable {
        let itemID: UUID
        let sourceLocator: ProjectSourceLocator
    }

    init(source: ProjectSource, items: [NormalizedImportItem], output: ParsedImportOutput) {
        schemaVersion = Self.currentSchemaVersion
        sourceID = source.id
        sourceRevision = source.sourceRevision
        sourceType = source.type
        producerID = ParsedImportOutput.producerID(for: source.type)
        itemMappings = items.map { ItemMapping(itemID: $0.id, sourceLocator: $0.sourceLocator) }
        self.output = output
    }

    func matches(_ source: ProjectSource) -> Bool {
        schemaVersion == Self.currentSchemaVersion
            && sourceID == source.id
            && sourceRevision == source.sourceRevision
            && sourceType == source.type
            && output.sourceType == source.type
            && producerID == ParsedImportOutput.producerID(for: source.type)
            && Set(itemMappings.map(\.itemID)).count == itemMappings.count
    }
}

nonisolated struct ParsedOutputSource: Sendable {
    let project: ProjectDocument
    let fileURL: URL
    let items: [ProjectContentItem]
}

typealias ParsedOutputProgress = @Sendable (ReadAloudImportProgress) -> Void
typealias ParsedOutputRetry = @MainActor () async throws -> Void
typealias ParsedOutputParseOperation = @Sendable (ParsedOutputSource, @escaping ParsedOutputProgress) async throws -> ParsedImportCache

nonisolated struct ReadAloudImportResult: Sendable, Equatable {
    let project: ProjectDocument
    let snapshot: ProjectSnapshot
    let diagnostics: [ReadAloudImportDiagnostic]
}

nonisolated enum ReadAloudImportError: Error, LocalizedError, Sendable, Equatable {
    case unsupportedFileType(String)
    case emptyContent
    case invalidTitle
    case sourceUnavailable(String)
    case normalizationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFileType(let name):
            return "Unsupported import file type: \(name)"
        case .emptyContent:
            return "The imported source did not contain readable content."
        case .invalidTitle:
            return "The imported source does not have a usable title."
        case .sourceUnavailable(let reason):
            return "Unable to retain the import source: \(reason)"
        case .normalizationFailed(let reason):
            return "Unable to normalize imported content: \(reason)"
        }
    }
}

nonisolated protocol ReadAloudDocumentImporting: Sendable {
    func importDocument(
        from url: URL,
        progress: (@Sendable (ReadAloudImportProgress) -> Void)?
    ) async throws -> NormalizedImportDocument
}
