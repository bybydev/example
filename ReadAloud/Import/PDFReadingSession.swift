import Foundation
import PDFKitAudio

/// Logical reading blocks assigned to the chapter that owns the first
/// contributing semantic element, including paragraphs spanning PDF pages.
nonisolated struct PDFReadingChapter: Sendable {
    let chapter: PdfChapter
    let blocks: [PdfReadingItem]

    var text: String {
        blocks.map { $0.element.text }.joined(separator: "\n\n")
    }
}

/// Keeps the original parser-backed book (and its running-matter evidence)
/// available while a PDF reader session is alive. Policies only derive views
/// from this book: they must never reparse the PDF or discard skipped content.
nonisolated final class PDFReadingSession: Sendable {
    let book: PdfBook

    private let orderedChapters: [PdfChapter]
    private let ownerByElementID: [String: Int]

    init(book: PdfBook) throws {
        let chapters = book.chapters.sorted { $0.order < $1.order }
        var owners: [String: Int] = [:]
        for (index, chapter) in chapters.enumerated() {
            try Task.checkCancellation()
            for element in chapter.elements {
                guard owners.updateValue(index, forKey: element.id) == nil else {
                    throw ReadAloudImportError.normalizationFailed(
                        "PDF chapter elements have duplicate identities."
                    )
                }
            }
        }
        self.book = book
        self.orderedChapters = chapters
        self.ownerByElementID = owners
    }

    static func open(
        at url: URL,
        progress: PdfParser.ProgressHandler? = nil
    ) async throws -> PDFReadingSession {
        try Task.checkCancellation()
        var configuration = PdfParserConfiguration.listening
        configuration.extractCoverImage = true
        configuration.retainNativeText = false
        let book = try await PdfParser(configuration: configuration).parseAsync(
            at: url,
            progress: progress
        )
        try Task.checkCancellation()
        return try PDFReadingSession(book: book)
    }

    func reading(
        policy: PdfReadingPolicy = .listening
    ) async throws -> PdfReadingResult {
        try Task.checkCancellation()
        return try await book.readingResultAsync(policy: policy)
    }

    /// Rebuild the entire policy-specific content, including chapters which
    /// were empty under a previous policy. Existing chapter IDs/settings stay
    /// stable; newly included chapters get a deterministic project-local UUID.
    func projection(
        for items: [ProjectContentItem],
        projectID: UUID,
        policy: PdfReadingPolicy
    ) async throws -> PDFReadingProjection {
        let task = Task.detached(priority: .userInitiated) { [self] in
            let result = try await reading(policy: policy)
            let chapters = try self.chapters(for: result)
            var existingByChapter = [String: ProjectContentItem]()
            for item in items {
                try Task.checkCancellation()
                guard item.sourceLocator.kind == .pdf,
                      item.sourceLocator.value.hasPrefix("chapter:"),
                      let separator = item.sourceLocator.value.range(of: ";pages:") else {
                    throw ReadAloudImportError.normalizationFailed(
                        "A PDF chapter locator is invalid."
                    )
                }
                let chapterID = String(
                    item.sourceLocator.value[
                        item.sourceLocator.value.index(
                            item.sourceLocator.value.startIndex,
                            offsetBy: "chapter:".count
                        )..<separator.lowerBound
                    ]
                )
                guard !chapterID.isEmpty,
                      existingByChapter.updateValue(item, forKey: chapterID) == nil else {
                    throw ReadAloudImportError.normalizationFailed(
                        "PDF chapter identities are duplicated."
                    )
                }
            }

            var projectedItems = [ProjectContentItem]()
            var paragraphs = [UUID: [ReaderParagraph]]()
            var seenChapters = Set<String>()
            var seenItemIDs = Set<UUID>()
            for entry in chapters {
                try Task.checkCancellation()
                let chapter = entry.chapter
                guard seenChapters.insert(chapter.id).inserted else {
                    throw ReadAloudImportError.normalizationFailed(
                        "PDF parser returned duplicate chapter IDs."
                    )
                }
                let text = ReadAloudContentNormalizer.normalizeSpokenText(entry.text)
                let previous = existingByChapter[chapter.id]
                // Retain established empty chapters so toggles back to a
                // previous policy preserve the same item and cache identity.
                if previous == nil && text.isEmpty { continue }

                let id: UUID
                if let previous {
                    id = previous.id
                } else {
                    id = try Self.stableItemID(
                        projectID: projectID, chapterID: chapter.id
                    )
                }
                guard seenItemIDs.insert(id).inserted else {
                    throw ReadAloudImportError.normalizationFailed(
                        "PDF chapter item identities collided."
                    )
                }
                let title: String
                if let previous {
                    title = previous.title
                } else {
                    title = try ReadAloudContentNormalizer.sanitizedTitle(
                        chapter.title,
                        fallback: "Section \(projectedItems.count + 1)"
                    )
                }
                let item = ProjectContentItem(
                    id: id,
                    title: title,
                    order: projectedItems.count,
                    text: text,
                    contentRevision: ProjectContentRevision.item(normalizedText: text),
                    sourceLocator: ProjectSourceLocator(
                        kind: .pdf,
                        value: "chapter:\(chapter.id);pages:\(chapter.pageRange.lowerBound)-\(chapter.pageRange.upperBound)"
                    ),
                    settings: previous?.settings ?? ItemNarrationSettings()
                )
                try ProjectValidation.validate(item)
                projectedItems.append(item)
                paragraphs[id] = ReaderTextLayout.paragraphs(in: text)
            }

            guard existingByChapter.keys.allSatisfy({ seenChapters.contains($0) }),
                  !projectedItems.isEmpty else {
                throw ReadAloudImportError.normalizationFailed(
                    "PDF chapter mapping is incomplete."
                )
            }
            return PDFReadingProjection(
                items: projectedItems,
                textByItemID: Dictionary(
                    uniqueKeysWithValues: projectedItems.map { ($0.id, $0.text) }
                ),
                paragraphsByItemID: paragraphs
            )
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Identity must remain stable across included/excluded policy variants.
    private static func stableItemID(
        projectID: UUID, chapterID: String
    ) throws -> UUID {
        let hex = Array(ProjectDigest.sha256(
            "readaloud-pdf-chapter-v1\\n\(projectID.uuidString)\\n\(chapterID)"
        ).prefix(32))
        let text = [
            String(hex[0..<8]), String(hex[8..<12]), String(hex[12..<16]),
            String(hex[16..<20]), String(hex[20..<32])
        ].joined(separator: "-")
        guard let id = UUID(uuidString: text) else {
            throw ReadAloudImportError.normalizationFailed(
                "Unable to construct stable PDF chapter identity."
            )
        }
        return id
    }

    func chapters(for result: PdfReadingResult) throws -> [PDFReadingChapter] {
        var grouped = [[PdfReadingItem]](
            repeating: [],
            count: orderedChapters.count
        )
        for item in result.blocks {
            try Task.checkCancellation()
            guard let firstID = item.sourceElementIDs.first,
                  let chapterIndex = ownerByElementID[firstID],
                  item.sourceElementIDs.allSatisfy({ ownerByElementID[$0] != nil }) else {
                throw ReadAloudImportError.normalizationFailed(
                    "PDF reading block cannot be assigned to a source chapter."
                )
            }
            grouped[chapterIndex].append(item)
        }

        return orderedChapters.enumerated().map { index, chapter in
            PDFReadingChapter(chapter: chapter, blocks: grouped[index])
        }
    }
}

/// A policy-specific in-memory reader projection. No stored source data is
/// modified; the playback/cache migration is handled separately in Pass 3.
nonisolated struct PDFReadingProjection: Sendable {
    let items: [ProjectContentItem]
    let textByItemID: [UUID: String]
    let paragraphsByItemID: [UUID: [ReaderParagraph]]
}
