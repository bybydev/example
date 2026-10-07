import Foundation
import TextExtractor

nonisolated struct TextDocumentImportAdapter: ReadAloudDocumentImporting {
    private let extractor = TextExtractor()

    var supportedFileExtensions: Set<String> {
        extractor.supportedFileExtensions
    }

    func importDocument(
        from url: URL,
        progress: (@Sendable (ReadAloudImportProgress) -> Void)?
    ) async throws -> NormalizedImportDocument {
        progress?(
            ReadAloudImportProgress(
                stage: .extracting,
                fractionCompleted: nil,
                detail: url.lastPathComponent
            )
        )

        let extractionTask = Task.detached(
            priority: .userInitiated
        ) {
            try Task.checkCancellation()
            return try extractor.extract(
                from: url,
                options: TextExtractionOptions(
                    startAccessingSecurityScopedResource: false
                )
            )
        }

        let document = try await withTaskCancellationHandler {
            try await extractionTask.value
        } onCancel: {
            extractionTask.cancel()
        }

        progress?(
            ReadAloudImportProgress(
                stage: .normalizing,
                fractionCompleted: 0
            )
        )

        let items = try normalizedItems(document)
        let author = document.metadata["author"]
            ?? document.metadata["creator"]

        return NormalizedImportDocument(
            kind: .document,
            title: try ReadAloudContentNormalizer.sanitizedTitle(
                document.title,
                fallback: url.deletingPathExtension().lastPathComponent
            ),
            author: author.flatMap(nonempty),
            items: items,
            artwork: nil,
            diagnostics: document.warnings.map {
                ReadAloudImportDiagnostic(
                    severity: .warning,
                    code: "textExtractor.\($0.code.rawValue)",
                    message: $0.message,
                    sourceLocator: nil
                )
            }
        )
    }

    private func normalizedItems(
        _ document: ExtractedTextDocument
    ) throws -> [NormalizedImportItem] {
        let meaningfulSegments = document.segments.filter {
            !ReadAloudContentNormalizer.normalizeSpokenText($0.text).isEmpty
        }

        if !meaningfulSegments.isEmpty {
            return try meaningfulSegments.enumerated().map {
                index,
                segment in
                let metadataTitle = segment.metadata["title"]
                    ?? segment.metadata["name"]
                return NormalizedImportItem(
                    title: try ReadAloudContentNormalizer.sanitizedTitle(
                        metadataTitle,
                        fallback: defaultSegmentTitle(
                            format: document.format,
                            index: index
                        )
                    ),
                    order: index,
                    normalizedText: segment.text,
                    sourceLocator: ProjectSourceLocator(
                        kind: .document,
                        value: "format:\(document.format.rawValue);segment:\(segment.id)"
                    )
                )
            }
        }

        let text = ReadAloudContentNormalizer.normalizeSpokenText(
            document.text
        )
        guard !text.isEmpty else {
            throw ReadAloudImportError.emptyContent
        }

        return [
            NormalizedImportItem(
                title: try ReadAloudContentNormalizer.sanitizedTitle(
                    document.title,
                    fallback: "Document"
                ),
                order: 0,
                normalizedText: text,
                sourceLocator: ProjectSourceLocator(
                    kind: .document,
                    value: "format:\(document.format.rawValue);document"
                )
            )
        ]
    }

    private func nonempty(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func defaultSegmentTitle(
        format: TextExtractionFormat,
        index: Int
    ) -> String {
        switch format {
        case .pptx:
            return "Slide \(index + 1)"
        case .srt, .vtt:
            return "Segment \(index + 1)"
        default:
            return "Section \(index + 1)"
        }
    }
}

