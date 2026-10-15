import Foundation
import PDFKitAudio
import XCTest
@testable import ReadAloud

/// Direct typed-content integration tests. These use a manual PdfBook so
/// parser-only running-matter confirmation must be tested separately with
/// an actual parser fixture.
final class PDFReadingSessionTests: XCTestCase {
    private func makeSource() throws -> PDFReadingSession {
        let spanningText = "Across the page boundary."
        let firstSpan = try PdfSourceSpan(
            pageIndex: 0,
            sourceRange: PdfTextRange(location: 0, length: 10),
            outputRange: PdfTextRange(location: 0, length: 10)
        )
        let secondSpan = try PdfSourceSpan(
            pageIndex: 1,
            sourceRange: PdfTextRange(
                location: 0, length: spanningText.utf16.count - 10
            ),
            outputRange: PdfTextRange(
                location: 10, length: spanningText.utf16.count - 10
            )
        )
        let chapters = [
            PdfChapter(
                id: "chapter-one", title: "One", pageRange: 0...1,
                order: 0, plainText: spanningText, htmlPreview: "",
                elements: [
                    try PdfSemanticElement(
                        id: "spanning-paragraph",
                        content: .paragraph(text: spanningText),
                        sourceSpans: [firstSpan, secondSpan]
                    ),
                    try PdfSemanticElement(
                        id: "caption-one",
                        content: .caption(text: "An illustration caption.")
                    ),
                    try PdfSemanticElement(
                        id: "table-one",
                        content: .table(text: "Value One, Value Two")
                    ),
                ]
            ),
            PdfChapter(
                id: "chapter-two", title: "Two", pageRange: 2...2,
                order: 1, plainText: "Second chapter.", htmlPreview: "",
                elements: [
                    try PdfSemanticElement(
                        id: "body-two",
                        content: .paragraph(text: "Second chapter.")
                    ),
                    // A manually supplied footer has uncertain provenance;
                    // it is included unless a kind-level override says skip.
                    try PdfSemanticElement(
                        id: "uncertain-footer",
                        content: .pageFooter(text: "Possibly a footer")
                    ),
                ]
            ),
            PdfChapter(
                id: "chapter-footnotes", title: "Notes", pageRange: 3...3,
                order: 2, plainText: "An omitted note.", htmlPreview: "",
                elements: [
                    try PdfSemanticElement(
                        id: "note-one",
                        content: .footnote(text: "An omitted note.")
                    ),
                ]
            ),
        ]
        let book = PdfBook(
            metadata: PdfMetadata(title: "Typed fixture", pageCount: 4),
            chapters: chapters, toc: [], cover: nil, fileURL: nil
        )
        return try PDFReadingSession(book: book)
    }

    private func existingItem(
        chapter: String, title: String, order: Int, text: String
    ) -> ProjectContentItem {
        ProjectContentItem(
            id: UUID(),
            title: title,
            order: order,
            text: text,
            contentRevision: ProjectContentRevision.item(normalizedText: text),
            sourceLocator: ProjectSourceLocator(
                kind: .pdf, value: "chapter:\(chapter);pages:\(order)-\(order)"
            )
        )
    }

    func testTypedPolicyAndCrossPageProvenance() async throws {
        let session = try makeSource()
        let initial = try await session.reading(policy: .listening)
        let chapterBlocks = try session.chapters(for: initial)
        XCTAssertEqual(chapterBlocks.count, 3)
        XCTAssertEqual(chapterBlocks[0].blocks[0].element.sourcePageIndexes, [0, 1])
        XCTAssertTrue(initial.blocks.contains(where: { $0.element.kind == .caption }))
        XCTAssertTrue(initial.blocks.contains(where: { $0.element.kind == .table }))
        XCTAssertFalse(initial.blocks.contains(where: { $0.element.kind == .footnote }))
        // Unconfirmed running matter is retained by the library.
        XCTAssertTrue(initial.blocks.contains(where: {
            $0.element.text == "Possibly a footer"
        }))

        var options = PdfReadingPolicy(
            includesFootnotes: true,
            includesCaptions: false,
            includesTables: false,
            includesRunningMatter: false
        )
        options.overrides[.pageFooter] = .skip
        let changed = try await session.reading(policy: options)
        XCTAssertTrue(changed.blocks.contains(where: { $0.element.kind == .footnote }))
        XCTAssertFalse(changed.blocks.contains(where: { $0.element.kind == .caption }))
        XCTAssertFalse(changed.blocks.contains(where: { $0.element.kind == .table }))
        XCTAssertFalse(changed.blocks.contains(where: { $0.element.kind == .pageFooter }))
        XCTAssertEqual(changed.omissions.count, 3)
    }

    func testPreviouslyOmittedChapterGetsStableItemAcrossProjections() async throws {
        let session = try makeSource()
        let projectID = UUID()
        let stored = [
            existingItem(
                chapter: "chapter-one", title: "One", order: 0,
                text: "Across the page boundary.\n\nAn illustration caption.\n\nValue One, Value Two"
            ),
            existingItem(
                chapter: "chapter-two", title: "Two", order: 1,
                text: "Second chapter.\n\nPossibly a footer"
            ),
        ]
        let initial = try await session.projection(
            for: stored, projectID: projectID, policy: .listening
        )
        XCTAssertEqual(initial.items.count, 2)
        XCTAssertEqual(initial.items[0].id, stored[0].id)
        XCTAssertEqual(initial.items[1].id, stored[1].id)

        let include = PdfReadingPolicy(includesFootnotes: true)
        let expanded = try await session.projection(
            for: stored, projectID: projectID, policy: include
        )
        XCTAssertEqual(expanded.items.count, 3)
        XCTAssertEqual(expanded.items[2].text, "An omitted note.")
        let newlyIncludedID = expanded.items[2].id

        // Repeating the projection, including after an app restart/reparse,
        // must not assign a different ID to this logical chapter.
        let reopenedSession = try makeSource()
        let repeated = try await reopenedSession.projection(
            for: stored, projectID: projectID, policy: include
        )
        XCTAssertEqual(repeated.items[2].id, newlyIncludedID)

        let restored = try await session.projection(
            for: expanded.items, projectID: projectID, policy: .listening
        )
        XCTAssertEqual(restored.items.count, 3)
        XCTAssertEqual(restored.items[2].id, newlyIncludedID)
        XCTAssertEqual(restored.items[2].text, "")
    }

    func testDuplicateTypedSourceIDsAreRejected() throws {
        let duplicate = try PdfSemanticElement(
            id: "same-id", content: .paragraph(text: "Text")
        )
        let chapters = (0..<2).map { order in
            PdfChapter(
                id: "chapter-\(order)",
                title: "Section \(order)", pageRange: order...order,
                order: order, plainText: "Text", htmlPreview: "",
                elements: [duplicate]
            )
        }
        let book = PdfBook(
            metadata: PdfMetadata(), chapters: chapters,
            toc: [], cover: nil, fileURL: nil
        )
        XCTAssertThrowsError(try PDFReadingSession(book: book))
    }
}
