import Foundation
import PDFKitAudio
import XCTest
@testable import ReadAloud

/// Disk-backed regression tests: no PDF extraction or ONNX inference needed.
/// They exercise the storage contract used by reader-side policy changes.
final class PDFReadingPersistenceTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let projectID: UUID
        let first: ProjectContentItem
        let second: ProjectContentItem
        let store: ProjectStore

        var paths: ProjectPackagePaths {
            ProjectPackagePaths(
                packageURL: ProjectPackagePaths.packageURL(
                    projectID: projectID, rootURL: root
                )
            )
        }
    }

    private func makeFixture(
        root existingRoot: URL? = nil
    ) async throws -> Fixture {
        let root = existingRoot ?? FileManager.default.temporaryDirectory.appending(
            path: "ReadAloud-PDFReadingTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        let store = try ProjectStore(rootURL: root)
        let id = UUID()
        let sourceID = UUID()
        let sourceBytes = Data("%PDF-1.4 test-source".utf8)
        let source = ProjectSource(
            id: sourceID,
            type: .pdf,
            originalFileName: "fixture.pdf",
            relativePath: "source/\(ProjectPackagePaths.fileID(sourceID)).pdf",
            sourceRevision: ProjectDigest.sha256(sourceBytes)
        )
        let first = makeItem(
            title: "One", chapter: "chapter-one",
            order: 0, text: "First spoken passage."
        )
        let second = makeItem(
            title: "Two", chapter: "chapter-two",
            order: 1, text: "Second spoken passage."
        )
        let items = [first, second]
        let entries = items.map { item in
            ContentManifestItem(
                id: item.id,
                order: item.order,
                relativePath: ProjectPackagePaths.relativeItemPath(item.id)
            )
        }
        let manifest = ProjectContentManifest(
            contentRevision: try ProjectContentRevision.project(
                manifestItems: entries, items: items
            ),
            items: entries
        )
        let initial = ProjectDocument(
            id: id, title: "PDF Fixture", source: source,
            pdfReadingPolicy: .listening,
            playback: ProjectPlaybackState(
                currentItemID: first.id,
                contentBookmark: ProjectContentBookmark(
                    contentRevision: first.contentRevision,
                    textOffsetUTF16: 6
                ),
                projectProgress: 0.25
            )
        )
        try await store.createPackage(
            project: initial,
            manifest: manifest,
            items: items,
            retainedSource: .data(sourceBytes)
        )
        return Fixture(
            root: root, projectID: id,
            first: first, second: second, store: store
        )
    }

    private func makeItem(
        title: String, chapter: String, order: Int, text: String,
        id: UUID = UUID()
    ) -> ProjectContentItem {
        ProjectContentItem(
            id: id,
            title: title,
            order: order,
            text: text,
            contentRevision: ProjectContentRevision.item(
                normalizedText: text
            ),
            sourceLocator: ProjectSourceLocator(
                kind: .pdf,
                value: "chapter:\(chapter);pages:\(order)-\(order)"
            )
        )
    }

    private func modified(
        _ item: ProjectContentItem, text: String
    ) -> ProjectContentItem {
        makeItem(
            title: item.title,
            chapter: item.sourceLocator.value
                .replacingOccurrences(of: "chapter:", with: "")
                .components(separatedBy: ";pages:")[0],
            order: item.order,
            text: text,
            id: item.id
        )
    }

    func testFourFiltersPersistPerProjectThroughFreshStore() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let selected = PdfReadingPolicy(
            includesFootnotes: true,
            includesCaptions: false,
            includesTables: false,
            includesRunningMatter: true
        )
        _ = try await fixture.store.updatePDFReadingPolicy(
            projectID: fixture.projectID, policy: selected
        )
        let reopened = try ProjectStore(rootURL: fixture.root)
        let loaded = try await reopened.loadProject(projectID: fixture.projectID)
        XCTAssertEqual(loaded.project.pdfReadingPolicy, selected)
        XCTAssertTrue(loaded.project.pdfReadingPolicy?.includesFootnotes == true)
        XCTAssertTrue(loaded.project.pdfReadingPolicy?.includesCaptions == false)
        XCTAssertTrue(loaded.project.pdfReadingPolicy?.includesTables == false)
        XCTAssertTrue(loaded.project.pdfReadingPolicy?.includesRunningMatter == true)

        _ = try await reopened.updatePDFReadingPolicy(
            projectID: fixture.projectID, policy: .listening
        )
        let afterReset = try await fixture.store.loadProject(
            projectID: fixture.projectID
        )
        XCTAssertEqual(afterReset.project.pdfReadingPolicy, .listening)
    }

    func testOnePDFsFiltersDoNotAlterAnotherPDF() async throws {
        let first = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: first.root) }
        let second = try await makeFixture(root: first.root)
        let custom = PdfReadingPolicy(
            includesFootnotes: true, includesTables: false
        )
        _ = try await first.store.updatePDFReadingPolicy(
            projectID: first.projectID, policy: custom
        )
        let reopened = try ProjectStore(rootURL: first.root)
        let selected = try await reopened.loadProject(
            projectID: first.projectID
        )
        let untouched = try await reopened.loadProject(
            projectID: second.projectID
        )
        XCTAssertEqual(selected.project.pdfReadingPolicy, custom)
        XCTAssertEqual(untouched.project.pdfReadingPolicy, .listening)
    }

    func testInvalidReplacementLeavesProjectUnchanged() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let before = try await fixture.store.loadProject(
            projectID: fixture.projectID
        )
        do {
            _ = try await fixture.store.replacePDFReadingContent(
                projectID: fixture.projectID,
                policy: PdfReadingPolicy(includesFootnotes: true),
                items: [fixture.first, fixture.first]
            )
            XCTFail("Duplicate content IDs must be rejected before commit.")
        } catch {
            // Rejection is the required result, regardless of error type.
        }
        let reopened = try ProjectStore(rootURL: fixture.root)
        let after = try await reopened.loadProject(
            projectID: fixture.projectID
        )
        XCTAssertEqual(after.project, before.project)
        XCTAssertEqual(after.items, before.items)
        XCTAssertEqual(after.manifest, before.manifest)
    }

    func testPolicyOnlyUpdateRetainsTextAndBookmark() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let policy = PdfReadingPolicy(includesFootnotes: true)
        let before = try await fixture.store.loadProject(projectID: fixture.projectID)
        _ = try await fixture.store.updatePDFReadingPolicy(
            projectID: fixture.projectID, policy: policy
        )
        let after = try await fixture.store.loadProject(projectID: fixture.projectID)
        XCTAssertEqual(after.manifest, before.manifest)
        XCTAssertEqual(after.items, before.items)
        XCTAssertEqual(after.project.playback, before.project.playback)
        XCTAssertEqual(after.project.pdfReadingPolicy, policy)
    }

    func testTextChangeInvalidatesStaleBookmarkAndGenerationJobs() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let oldKey = ProjectDigest.sha256("old-generation")
        let unchangedKey = ProjectDigest.sha256("unchanged-generation")
        let now = Date()
        let jobs = [
            GenerationJobRecord(
                id: UUID(), projectID: fixture.projectID,
                itemID: fixture.first.id, operation: .generate,
                generationKey: oldKey, state: .queued,
                createdAt: now, updatedAt: now, attempt: 0, lastError: nil
            ),
            GenerationJobRecord(
                id: UUID(), projectID: fixture.projectID,
                itemID: fixture.second.id, operation: .generate,
                generationKey: unchangedKey, state: .queued,
                createdAt: now, updatedAt: now, attempt: 0, lastError: nil
            ),
        ]
        try await fixture.store.saveQueue(
            projectID: fixture.projectID,
            queue: ProjectQueueDocument(jobs: jobs)
        )
        let keep = fixture.paths.chunkCacheDirectory.appending(path: "preserve.bin")
        try FileManager.default.createDirectory(
            at: fixture.paths.chunkCacheDirectory,
            withIntermediateDirectories: true
        )
        try Data("unchanged cached chunks".utf8).write(to: keep)
        let selected = PdfReadingPolicy(includesTables: false)
        _ = try await fixture.store.replacePDFReadingContent(
            projectID: fixture.projectID,
            policy: selected,
            items: [
                modified(fixture.first, text: "A different first passage."),
                fixture.second
            ]
        )
        let reopened = try ProjectStore(rootURL: fixture.root)
        let loaded = try await reopened.loadProject(projectID: fixture.projectID)
        XCTAssertEqual(loaded.project.pdfReadingPolicy, selected)
        XCTAssertEqual(loaded.items[0].text, "A different first passage.")
        XCTAssertNotEqual(
            loaded.items[0].contentRevision, fixture.first.contentRevision
        )
        XCTAssertEqual(
            loaded.items[1].contentRevision, fixture.second.contentRevision
        )
        XCTAssertNil(loaded.project.playback?.contentBookmark)
        XCTAssertNil(loaded.project.playback?.audioPosition)
        XCTAssertEqual(loaded.project.playback?.projectProgress, 0)
        XCTAssertEqual(loaded.queue.jobs.map(\.id), [jobs[1].id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path))

        do {
            _ = try await reopened.updatePlayback(
                projectID: fixture.projectID,
                playback: ProjectPlaybackState(
                    currentItemID: fixture.first.id,
                    contentBookmark: ProjectContentBookmark(
                        contentRevision: fixture.first.contentRevision,
                        textOffsetUTF16: 4
                    )
                )
            )
            XCTFail("Stale PDF text revision should reject a late bookmark.")
        } catch let error as ProjectStoreError {
            guard case .invalidData = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
    }

    func testInsertedChapterKeepsCurrentBookmarkAndRecomputesProgress() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let preface = makeItem(
            title: "Preface", chapter: "chapter-preface",
            order: 0, text: "Newly included preface."
        )
        let first = makeItem(
            title: fixture.first.title, chapter: "chapter-one",
            order: 1, text: fixture.first.text, id: fixture.first.id
        )
        let second = makeItem(
            title: fixture.second.title, chapter: "chapter-two",
            order: 2, text: fixture.second.text, id: fixture.second.id
        )
        _ = try await fixture.store.replacePDFReadingContent(
            projectID: fixture.projectID,
            policy: PdfReadingPolicy(includesFootnotes: true),
            items: [preface, first, second]
        )
        let reopened = try ProjectStore(rootURL: fixture.root)
        let loaded = try await reopened.loadProject(projectID: fixture.projectID)
        let bookmark = loaded.project.playback?.contentBookmark
        XCTAssertEqual(bookmark?.contentRevision, fixture.first.contentRevision)
        XCTAssertEqual(bookmark?.textOffsetUTF16, 6)
        XCTAssertEqual(loaded.project.playback?.currentItemID, fixture.first.id)

        let total = [preface, first, second].reduce(0) {
            $0 + max(1, $1.text.utf16.count)
        }
        let expected = Double(preface.text.utf16.count + 6) / Double(total)
        XCTAssertEqual(
            loaded.project.playback?.projectProgress ?? -1,
            expected, accuracy: 0.0001
        )
    }

    func testNewlyIncludedAndEmptyChapterItemsSurviveReopen() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let includedID = UUID()
        let newlyIncluded = makeItem(
            title: "Footnotes", chapter: "chapter-footnotes",
            order: 2, text: "Previously excluded note.", id: includedID
        )
        let selected = PdfReadingPolicy(includesFootnotes: true)
        _ = try await fixture.store.replacePDFReadingContent(
            projectID: fixture.projectID,
            policy: selected,
            items: [fixture.first, fixture.second, newlyIncluded]
        )
        let reopened = try ProjectStore(rootURL: fixture.root)
        let expanded = try await reopened.loadProject(projectID: fixture.projectID)
        XCTAssertEqual(expanded.items.count, 3)
        XCTAssertEqual(expanded.items[2].id, includedID)

        let empty = modified(newlyIncluded, text: "")
        _ = try await reopened.replacePDFReadingContent(
            projectID: fixture.projectID,
            policy: .listening,
            items: [fixture.first, fixture.second, empty]
        )
        let closed = try await reopened.loadProject(projectID: fixture.projectID)
        XCTAssertEqual(closed.items.count, 3)
        XCTAssertEqual(closed.items[2].id, includedID)
        XCTAssertTrue(closed.items[2].text.isEmpty)
        XCTAssertEqual(closed.project.pdfReadingPolicy, .listening)
    }

    func testCommittedSwapMarkerKeepsNewContentAfterRestart() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let selected = PdfReadingPolicy(includesCaptions: false)
        let changedText = "Only the new filtered reading."
        _ = try await fixture.store.replacePDFReadingContent(
            projectID: fixture.projectID,
            policy: selected,
            items: [
                modified(fixture.first, text: changedText),
                fixture.second
            ]
        )
        let transaction = fixture.paths.tempDirectory.appending(
            path: "pdf-reading-transaction", directoryHint: .isDirectory
        )
        let backup = transaction.appending(
            path: "backup", directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: backup, withIntermediateDirectories: true
        )
        // Simulate a kill after every swap completed and the committed
        // marker was written, before its temporary backups were removed.
        try Data("committed".utf8).write(
            to: transaction.appending(path: "committed")
        )
        let reopened = try ProjectStore(rootURL: fixture.root)
        let loaded = try await reopened.loadProject(projectID: fixture.projectID)
        XCTAssertEqual(loaded.project.pdfReadingPolicy, selected)
        XCTAssertEqual(loaded.items.first?.text, changedText)
        XCTAssertFalse(FileManager.default.fileExists(atPath: transaction.path))
    }

    func testInterruptedSwapRestoresOriginalContentOnColdLaunch() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let paths = fixture.paths
        let transaction = paths.tempDirectory.appending(
            path: "pdf-reading-transaction", directoryHint: .isDirectory
        )
        let backup = transaction.appending(path: "backup", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: backup, withIntermediateDirectories: true
        )
        // Simulate a crash after the old content was moved aside, before the
        // replacement content and project metadata were committed.
        try FileManager.default.moveItem(
            at: paths.contentDirectory,
            to: backup.appending(path: "content", directoryHint: .isDirectory)
        )
        let reopened = try ProjectStore(rootURL: fixture.root)
        let loaded = try await reopened.loadProject(projectID: fixture.projectID)
        XCTAssertEqual(loaded.items.map(\.text), [
            fixture.first.text, fixture.second.text
        ])
        XCTAssertEqual(loaded.project.pdfReadingPolicy, .listening)
        XCTAssertFalse(FileManager.default.fileExists(atPath: transaction.path))
    }
}
