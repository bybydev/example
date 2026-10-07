import Foundation
import PDFKitAudio

nonisolated struct PDFImportAdapter: ReadAloudDocumentImporting {
    func importDocument(
        from url: URL,
        progress: (@Sendable (ReadAloudImportProgress) -> Void)?
    ) async throws -> NormalizedImportDocument {
        let parser = PdfParser(
            configuration: PdfParserConfiguration(
                extractCoverImage: true,
                retainNativeText: false
            )
        )

        let book = try await parser.parse(
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

        progress?(
            ReadAloudImportProgress(
                stage: .normalizing,
                fractionCompleted: 0
            )
        )

        let chapters = book.chapters.sorted { $0.order < $1.order }
        var items: [NormalizedImportItem] = []
        items.reserveCapacity(chapters.count)

        for chapter in chapters {
            let text = ReadAloudContentNormalizer.normalizeSpokenText(
                chapter.plainText
            )
            guard !text.isEmpty else { continue }

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

        guard !items.isEmpty else {
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
            diagnostics: diagnostics
        )
    }

    private func nonempty(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
