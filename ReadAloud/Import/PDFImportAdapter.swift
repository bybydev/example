import Foundation
import PDFKitAudio

nonisolated struct PDFImportAdapter: ReadAloudDocumentImporting {
    func importDocument(
        from url: URL,
        progress: (@Sendable (ReadAloudImportProgress) -> Void)?
    ) async throws -> NormalizedImportDocument {
        try Task.checkCancellation()

        let session = try await PDFReadingSession.open(
            at: url,
            progress: { value in
                progress?(
                    ReadAloudImportProgress(
                        stage: .extracting,
                        fractionCompleted: value.pageFractionCompleted,
                        detail: value.stage.rawValue
                    )
                )
            }
        )

        try Task.checkCancellation()
        progress?(
            ReadAloudImportProgress(
                stage: .normalizing,
                fractionCompleted: 0
            )
        )

        let book = session.book
        // One source parse, two inexpensive views: existing saved speech text
        // and complete typed output for later in-memory filtering.
        let fullReading = try await session.reading(policy: .includeAll)
        let reading = try await session.reading(policy: .listening)
        let chapters = try session.chapters(for: reading)
        var items: [NormalizedImportItem] = []
        items.reserveCapacity(chapters.count)

        for entry in chapters {
            try Task.checkCancellation()
            let chapter = entry.chapter
            let text = ReadAloudContentNormalizer.normalizeSpokenText(
                entry.text
            )
            let order = items.count
            items.append(
                NormalizedImportItem(
                    title: try ReadAloudContentNormalizer.sanitizedTitle(
                        chapter.title,
                        fallback: "Section \(order + 1)"
                    ),
                    order: order,
                    normalizedText: text,
                    sourceLocator: ProjectSourceLocator(
                        kind: .pdf,
                        value: "chapter:\(chapter.id);pages:\(chapter.pageRange.lowerBound)-\(chapter.pageRange.upperBound)"
                    )
                )
            )
        }

        guard !items.isEmpty,
              fullReading.items.contains(where: { !$0.element.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw ReadAloudImportError.emptyContent
        }

        var diagnostics: [ReadAloudImportDiagnostic] = []
        if book.ocrPageCount > 0 {
            diagnostics.append(
                ReadAloudImportDiagnostic(
                    severity: .info,
                    code: "pdf.ocrPages",
                    message: "\(book.ocrPageCount) page(s) used OCR.",
                    sourceLocator: nil
                )
            )
        }
        if book.emptyPageCount > 0 {
            diagnostics.append(
                ReadAloudImportDiagnostic(
                    severity: .warning,
                    code: "pdf.emptyPages",
                    message: "\(book.emptyPageCount) page(s) contained no readable text.",
                    sourceLocator: nil
                )
            )
        }

        return NormalizedImportDocument(
            kind: .pdf,
            title: try ReadAloudContentNormalizer.sanitizedTitle(
                book.metadata.title,
                fallback: url.deletingPathExtension().lastPathComponent
            ),
            author: nonempty(
                book.metadata.authors.isEmpty
                    ? (book.metadata.creator ?? "")
                    : book.metadata.authors.joined(separator: ", ")
            ),
            items: items,
            artwork: book.coverImageData.map {
                NormalizedImportArtwork(
                    data: $0,
                    fileExtension: "jpg"
                )
            },
            diagnostics: diagnostics,
            parsedOutput: .pdf(
                result: fullReading,
                chapters: book.chapters.sorted { $0.order < $1.order }.map {
                    ParsedPDFChapter(
                        id: $0.id, title: $0.title, order: $0.order,
                        firstPage: $0.pageRange.lowerBound,
                        lastPage: $0.pageRange.upperBound,
                        sourceElementIDs: $0.elements.map(\.id)
                    )
                }
            )
        )
    }

    private func nonempty(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
