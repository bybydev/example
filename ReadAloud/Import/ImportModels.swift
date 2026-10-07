import Foundation

nonisolated enum ReadAloudImportSource: Sendable, Equatable {
    case file(URL)
    case pastedText(String, suggestedTitle: String?)
}

nonisolated enum ReadAloudImportKind: String, Sendable, Equatable {
    case epub
    case pdf
    case document
    case paste
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
}

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
