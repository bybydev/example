import Foundation
import PDFKitAudio
import XCTest
@testable import ReadAloud

@MainActor
final class CachedPDFReadingTests: XCTestCase {
    private struct Fixture: Sendable {
        let root: URL
        let store: ProjectStore
        let project: ProjectDocument
        let items: [ProjectContentItem]
        let cache: ParsedImportCache
        var paths: ProjectPackagePaths {
            ProjectPackagePaths(packageURL: ProjectPackagePaths.packageURL(projectID: project.id, rootURL: root))
        }
    }

    private func fixture(cacheAvailable: Bool = true) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "CachedPDF-\(UUID().uuidString)")
        let store = try ProjectStore(rootURL: root)
        // Deliberately not a parseable PDF. Opening/filtering must use its cache.
        let bytes = Data("retained PDF snapshot used for identity checks only".utf8)
        let sourceID = UUID()
        let source = ProjectSource(
            id: sourceID, type: .pdf, originalFileName: "book.pdf",
            relativePath: "source/\(sourceID.uuidString.lowercased()).pdf",
            sourceRevision: ProjectDigest.sha256(bytes)
        )
        let normalized = [
            NormalizedImportItem(title: "Main", order: 0, normalizedText: "Main text.\n\nCaption.\n\nUncertain header.",
                sourceLocator: ProjectSourceLocator(kind: .pdf, value: "chapter:main;pages:0-0")),
            NormalizedImportItem(title: "Notes", order: 1, normalizedText: "",
                sourceLocator: ProjectSourceLocator(kind: .pdf, value: "chapter:notes;pages:1-1"))
        ]
        let content = try ReadAloudContentNormalizer.makeContent(from: normalized)
        let project = ProjectDocument(title: "Cached PDF", source: source, pdfReadingPolicy: .listening)
        let elements = try [
            PdfSemanticElement(content: .paragraph(text: "Main text.")),
            PdfSemanticElement(content: .pageHeader(text: "Confirmed header.")),
            PdfSemanticElement(content: .caption(text: "Caption.")),
            PdfSemanticElement(content: .pageHeader(text: "Uncertain header.")),
            PdfSemanticElement(content: .footnote(text: "Optional note."))
        ]
        let blocks = try elements.enumerated().map { index, element in
            try PdfReadingItem(
                element: element, sourceElementIDs: [element.id],
                decision: PdfReadingDecision(
                    disposition: .read,
                    evidence: index == 1 ? .confirmedRunningMatter : (index == 3 ? .uncertainContent : .supportedContent),
                    reason: .includeByDefault
                )
            )
        }
        let cached = ParsedImportCache(source: source, items: normalized, output: .pdf(
            result: PdfReadingResult(title: "Cached PDF", items: blocks),
            chapters: [
                ParsedPDFChapter(id: "main", title: "Main", order: 0, firstPage: 0, lastPage: 0, sourceElementIDs: elements.prefix(4).map(\.id)),
                ParsedPDFChapter(id: "notes", title: "Notes", order: 1, firstPage: 1, lastPage: 1, sourceElementIDs: [elements[4].id])
            ]
        ))
        try await store.createPackage(
            project: project, manifest: content.manifest, items: content.items,
            retainedSource: .data(bytes), parsedCache: cacheAvailable ? cached : nil
        )
        return Fixture(root: root, store: store, project: project, items: content.items, cache: cached)
    }

    func testFiltersRestoreOptionalBlocksWithoutChangingStoredTextManifestOrCache() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let paths = fixture.paths
        let before = try [paths.contentManifest, paths.parsedOutputCache]
            .map { try Data(contentsOf: $0) } + fixture.items.map { try Data(contentsOf: paths.itemJSON($0.id)) }
        let runtime = ProjectRuntime(
            id: fixture.project.id, packageURL: paths.packageURL,
            persistence: ProjectRuntimePersistenceBridge(projectID: fixture.project.id, store: fixture.store)
        )
        defer { runtime.shutdown() }
        try await runtime.loadIfNeeded()
        XCTAssertTrue(runtime.isPDFReadingReady)
        XCTAssertEqual(runtime.itemStates.map(\.id), fixture.items.map(\.id))
        XCTAssertEqual(runtime.itemStates[1].item.text, "")
        XCTAssertFalse(runtime.itemStates[0].item.text.contains("Confirmed header."))
        XCTAssertTrue(runtime.itemStates[0].item.text.contains("Uncertain header."))

        var policy = PdfReadingPolicy.includeAll
        policy.includesCaptions = false
        try await runtime.applyPDFReadingPolicy(policy)
        XCTAssertEqual(runtime.itemStates[1].item.text, "Optional note.")
        XCTAssertTrue(runtime.itemStates[0].item.text.contains("Confirmed header."))
        XCTAssertFalse(runtime.itemStates[0].item.text.contains("Caption."))
        XCTAssertEqual(runtime.readerParagraphs(itemID: fixture.items[1].id).map(\.text).joined(), "Optional note.")
        let keyWithNote = runtime.itemStates[1].generationKey

        let freshStore = try ProjectStore(rootURL: fixture.root)
        let reopened = try await freshStore.loadProject(projectID: fixture.project.id)
        XCTAssertTrue(reopened.hasParsedPDFOutput)
        XCTAssertEqual(reopened.items.map(\.text), runtime.itemStates.map { $0.item.text })

        try await runtime.applyPDFReadingPolicy(.listening)
        XCTAssertEqual(runtime.itemStates[1].item.text, "")
        XCTAssertNotEqual(runtime.itemStates[1].generationKey, keyWithNote)
        XCTAssertEqual(runtime.itemStates.map(\.id), fixture.items.map(\.id))
        let after = try [paths.contentManifest, paths.parsedOutputCache]
            .map { try Data(contentsOf: $0) } + fixture.items.map { try Data(contentsOf: paths.itemJSON($0.id)) }
        XCTAssertEqual(after, before)
    }

    func testAudioAndBookmarksValidateEffectiveTextInsteadOfEmptySavedChapter() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.store.updatePDFReadingPolicy(projectID: fixture.project.id, policy: .includeAll)
        let loaded = try await fixture.store.loadProject(projectID: fixture.project.id)
        let notes = loaded.items[1]
        XCTAssertEqual(fixture.items[1].text, "")
        XCTAssertEqual(notes.text, "Optional note.")
        let metadata = GeneratedAudioMetadata(
            itemID: notes.id, generationKey: ProjectDigest.sha256("filtered-generation"),
            audioRevision: ProjectDigest.sha256("filtered-wav"), contentRevision: notes.contentRevision,
            voiceID: "af_heart", speed: 1, runtimeRevision: "test", synthesisConfigVersion: 1,
            durationSeconds: 1,
            segments: [AudioSegmentMetadata(
                sourceRange: AudioSourceRange(startUTF16: 0, endUTF16: notes.text.utf16.count),
                startSeconds: 0, endSeconds: 1
            )]
        )
        try await fixture.store.saveAudioMetadata(projectID: fixture.project.id, metadata: metadata)
        let checkpoint = ProjectPlaybackState(
            currentItemID: notes.id,
            contentBookmark: ProjectContentBookmark(contentRevision: notes.contentRevision, textOffsetUTF16: 5)
        )
        _ = try await fixture.store.updatePlayback(projectID: fixture.project.id, playback: checkpoint)
        let updated = try await fixture.store.updatePDFReadingPolicy(projectID: fixture.project.id, policy: .listening)
        XCTAssertEqual(updated.playback?.contentBookmark?.textOffsetUTF16, 0)
        XCTAssertEqual(updated.playback?.contentBookmark?.contentRevision, fixture.items[1].contentRevision)
        do {
            try await fixture.store.saveAudioMetadata(projectID: fixture.project.id, metadata: metadata)
            XCTFail("Audio for the included note must not validate under an excluding policy")
        } catch let error as ProjectStoreError {
            guard case .invalidData = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testLoadedBlocksRemainUsableWhenTheDiskSidecarIsRemoved() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runtime = ProjectRuntime(
            id: fixture.project.id, packageURL: fixture.paths.packageURL,
            persistence: ProjectRuntimePersistenceBridge(projectID: fixture.project.id, store: fixture.store)
        )
        defer { runtime.shutdown() }
        try await runtime.loadIfNeeded()
        try await runtime.applyPDFReadingPolicy(.includeAll)
        try FileManager.default.removeItem(at: fixture.paths.parsedOutputCache)
        try await runtime.applyPDFReadingPolicy(.listening)
        XCTAssertEqual(runtime.itemStates[1].item.text, "")
        XCTAssertTrue(runtime.isPDFReadingReady)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.parsedOutputCache.path))
    }

    func testCacheMissKeepsSavedTextAndDoesNotParseOrSavePendingFilters() async throws {
        let fixture = try await fixture(cacheAvailable: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runtime = ProjectRuntime(
            id: fixture.project.id, packageURL: fixture.paths.packageURL,
            persistence: ProjectRuntimePersistenceBridge(projectID: fixture.project.id, store: fixture.store)
        )
        defer { runtime.shutdown() }
        try await runtime.loadIfNeeded()
        XCTAssertNil(runtime.pdfReadingProjection)
        XCTAssertTrue(runtime.isPDFReadingReady)
        XCTAssertEqual(runtime.itemStates.map { $0.item.text }, fixture.items.map(\.text))
        do {
            try await runtime.applyPDFReadingPolicy(.includeAll)
            XCTFail("Unavailable blocks require explicit preparation, never implicit parsing")
        } catch is ParsedOutputPreparationError { }
        let project = try await fixture.store.loadProjectMetadata(projectID: fixture.project.id)
        XCTAssertEqual(project.pdfReadingPolicy, .listening)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.parsedOutputCache.path))

        _ = try await fixture.store.updatePDFReadingPolicy(projectID: fixture.project.id, policy: .includeAll)
        try await runtime.refresh()
        XCTAssertFalse(runtime.isPDFReadingReady)
        XCTAssertTrue(runtime.blocksQueuedGeneration)
        XCTAssertEqual(runtime.itemStates.map { $0.item.text }, fixture.items.map(\.text))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.parsedOutputCache.path))
    }

    func testExplicitFilterActionOffersWithoutParsingThenStartCachesAndApplies() async throws {
        let fixture = try await fixture(cacheAvailable: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = ProjectRuntimeManager(store: fixture.store)
        let wasActive = ProjectGenerationExecutionRegistry.shared.isApplicationActive
        manager.setApplicationActive(true)
        defer { manager.shutdownAll(); manager.setApplicationActive(wasActive) }
        let runtime = try await manager.prepareRuntime(projectID: fixture.project.id)
        let files = [fixture.paths.contentManifest] + fixture.items.map { fixture.paths.itemJSON($0.id) }
        let saved = try files.map { try Data(contentsOf: $0) }
        var parses = 0
        var request: ParsedOutputPreparation?
        manager.registerPreparationPresenter(id: UUID(), priority: 1) { runtime, retry in
            request = ParsedOutputPreparation(title: "Book", process: { progress in
                parses += 1
                try await runtime.prepareParsedOutputFromUser(progress: progress, parse: { _, progress in
                    progress(ReadAloudImportProgress(stage: .extracting, fractionCompleted: 0.5))
                    return fixture.cache
                })
            }, retry: retry)
            return true
        }
        try await runtime.applyPDFReadingPolicy(.includeAll)
        let preparation = try XCTUnwrap(request)
        XCTAssertEqual(preparation.phase, .offered)
        XCTAssertEqual(parses, 0)
        XCTAssertEqual(runtime.pdfReadingPolicy, .listening)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.parsedOutputCache.path))

        preparation.start()
        await preparation.waitForCompletion()
        XCTAssertEqual(preparation.phase, .finished)
        XCTAssertEqual(parses, 1)
        XCTAssertEqual(runtime.pdfReadingPolicy, .includeAll)
        XCTAssertEqual(runtime.itemStates[1].item.text, "Optional note.")
        let cached = try await fixture.store.loadParsedOutput(projectID: fixture.project.id)
        XCTAssertEqual(cached, fixture.cache)
        XCTAssertEqual(try files.map { try Data(contentsOf: $0) }, saved)
    }

    func testPassiveWorkAndInactiveActionsNeverQueuePreparationForForegrounding() async throws {
        let fixture = try await fixture(cacheAvailable: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = ProjectRuntimeManager(store: fixture.store)
        let wasActive = ProjectGenerationExecutionRegistry.shared.isApplicationActive
        manager.setApplicationActive(true)
        defer { manager.shutdownAll(); manager.setApplicationActive(wasActive) }
        let runtime = try await manager.prepareRuntime(projectID: fixture.project.id)
        var rootOffers = 0
        var modalOffers = 0
        let modalID = UUID()
        manager.registerPreparationPresenter(id: UUID(), priority: 0) { _, _ in rootOffers += 1; return true }
        manager.registerPreparationPresenter(id: modalID, priority: 4) { _, _ in modalOffers += 1; return true }
        try await runtime.refresh()
        await runtime.schedulePrefetch(after: fixture.items[0].id)
        XCTAssertEqual(rootOffers + modalOffers, 0)
        manager.setApplicationActive(false)
        do {
            try await runtime.applyPDFReadingPolicy(.includeAll)
            XCTFail("Inactive actions must not queue a sheet")
        } catch is ParsedOutputPreparationError { }
        manager.setApplicationActive(true)
        try await runtime.loadIfNeeded()
        XCTAssertEqual(rootOffers + modalOffers, 0)
        try await runtime.applyPDFReadingPolicy(.includeAll)
        XCTAssertEqual(modalOffers, 1)
        XCTAssertEqual(rootOffers, 0)
        manager.unregisterPreparationPresenter(id: modalID)
        try await runtime.applyPDFReadingPolicy(.includeAll)
        XCTAssertEqual(rootOffers, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.parsedOutputCache.path))
    }

    func testCancelledNativeParserReturningLateCannotPublishCache() async throws {
        let fixture = try await fixture(cacheAvailable: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runtime = ProjectRuntime(
            id: fixture.project.id, packageURL: fixture.paths.packageURL,
            persistence: ProjectRuntimePersistenceBridge(projectID: fixture.project.id, store: fixture.store)
        )
        defer { runtime.shutdown() }
        try await runtime.loadIfNeeded()
        let gate = ParsedOutputPreparationGate()
        let operation = Task {
            try await runtime.prepareParsedOutputFromUser(progress: { _ in }, parse: { _, _ in
                // Deliberately ignores cancellation, like a native parser call.
                await gate.suspend()
                return fixture.cache
            })
        }
        await gate.waitForEntry()
        operation.cancel()
        await gate.release()
        do { try await operation.value; XCTFail("Late output must be rejected") }
        catch is CancellationError { }
        XCTAssertFalse(runtime.isPreparingParsedOutput)
        XCTAssertNil(runtime.pdfReadingProjection)
        XCTAssertEqual(runtime.itemStates.map { $0.item.text }, fixture.items.map(\.text))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.parsedOutputCache.path))
    }

    func testExplicitKindOverridesKeepUncertainContentAndStableEmptyChapterIDs() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var policy = PdfReadingPolicy.includeAll
        policy.overrides[.pageHeader] = .skip
        let projection = try XCTUnwrap(PDFReadingProjection.cached(
            fixture.cache, items: fixture.items, projectID: fixture.project.id, policy: policy
        ))
        XCTAssertFalse(projection.items[0].text.contains("header."))
        XCTAssertEqual(projection.items[1].id, fixture.items[1].id)
        XCTAssertTrue(projection.paragraphsByItemID.isEmpty, "Opening a book must not lay out every chapter")
    }
}



// A controllable native-style call that does not itself honor cancellation.
private actor ParsedOutputPreparationGate {
    private var entered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var completion: CheckedContinuation<Void, Never>?

    func suspend() async {
        entered = true
        entryWaiter?.resume()
        entryWaiter = nil
        await withCheckedContinuation { completion = $0 }
    }
    func waitForEntry() async {
        if !entered { await withCheckedContinuation { entryWaiter = $0 } }
    }
    func release() { completion?.resume(); completion = nil }
}

@MainActor
final class ParsedOutputPreparationTests: XCTestCase {
    func testOfferAndNotNowNeverStartProcessing() async {
        var starts = 0
        var retries = 0
        let request = ParsedOutputPreparation(title: "Book", process: { _ in starts += 1 }, retry: { retries += 1 })
        XCTAssertEqual(request.phase, .offered)
        XCTAssertEqual(starts, 0)
        request.cancel()
        request.start()
        await request.waitForCompletion()
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(retries, 0)
        XCTAssertEqual(request.phase, .cancelled)
    }

    func testCancelRejectsLateProgressAndPendingAction() async {
        let gate = ParsedOutputPreparationGate()
        var retries = 0
        let request = ParsedOutputPreparation(title: "Book", process: { progress in
            await gate.suspend()
            progress(ReadAloudImportProgress(stage: .finished, fractionCompleted: 1))
        }, retry: { retries += 1 })
        request.start()
        await gate.waitForEntry()
        request.cancel()
        await gate.release()
        await request.waitForCompletion()
        XCTAssertEqual(request.phase, .cancelled)
        XCTAssertEqual(request.progress.stage, .preparing)
        XCTAssertEqual(retries, 0)
    }

    func testFailureWaitsForExplicitRetry() async {
        let registry = ProjectGenerationExecutionRegistry.shared
        let wasActive = registry.isApplicationActive
        registry.setApplicationActive(true)
        defer { registry.setApplicationActive(wasActive) }
        var starts = 0
        var retries = 0
        let request = ParsedOutputPreparation(title: "Book", process: { _ in
            starts += 1
            if starts == 1 { throw ParsedOutputPreparationError.unavailable }
        }, retry: { retries += 1 })
        request.start()
        await request.waitForCompletion()
        guard case .failed = request.phase else { return XCTFail("Expected a visible failure") }
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(retries, 0)
        request.start()
        await request.waitForCompletion()
        XCTAssertEqual(starts, 2)
        XCTAssertEqual(retries, 1)
        XCTAssertEqual(request.phase, .finished)
    }

    func testCompletionInBackgroundDoesNotResumePendingAction() async {
        let registry = ProjectGenerationExecutionRegistry.shared
        let wasActive = registry.isApplicationActive
        registry.setApplicationActive(false)
        defer { registry.setApplicationActive(wasActive) }
        var retries = 0
        let request = ParsedOutputPreparation(title: "Book", process: { _ in }, retry: { retries += 1 })
        request.start()
        await request.waitForCompletion()
        XCTAssertEqual(request.phase, .finished)
        registry.setApplicationActive(true)
        XCTAssertEqual(retries, 0)
    }
}

// Pass 1 cache coverage uses the already registered test source. These tests
// exercise persistence only; loading a missing cache must not run any importer.
@MainActor
final class ParsedOutputCacheTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "ReadAloud-ParsedOutputTests-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func importedPaste(in root: URL) async throws -> (ProjectStore, ProjectDocument) {
        let store = try ProjectStore(rootURL: root)
        let result = try await ReadAloudImportCoordinator(projectStore: store).importSource(
            .pastedText("First   paragraph.\n\nSecond paragraph.", suggestedTitle: "Fixture")
        )
        return (store, result.project)
    }

    private func paths(_ project: ProjectDocument, root: URL) -> ProjectPackagePaths {
        ProjectPackagePaths(packageURL: ProjectPackagePaths.packageURL(
            projectID: project.id, rootURL: root
        ))
    }

    func testImportPersistsRawOutputAndExistingTextWithTheSameItemIDs() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, project) = try await importedPaste(in: root)
        let loaded = try await store.loadProject(projectID: project.id)
        let cachedValue = try await store.loadParsedOutput(projectID: project.id)
        let cached = try XCTUnwrap(cachedValue)
        XCTAssertEqual(cached.itemMappings.map(\.itemID), loaded.items.map(\.id))
        XCTAssertEqual(cached.itemMappings.map(\.sourceLocator), loaded.items.map(\.sourceLocator))
        guard case .paste(let raw) = cached.output else { return XCTFail("Missing raw paste") }
        XCTAssertEqual(raw, "First   paragraph.\n\nSecond paragraph.")
        XCTAssertEqual(loaded.items.first?.text, "First paragraph.\n\nSecond paragraph.")

        let filePaths = paths(project, root: root)
        let textBefore = try Data(contentsOf: filePaths.itemJSON(loaded.items[0].id))
        let projectBefore = try Data(contentsOf: filePaths.projectJSON)
        _ = try await store.clearTemporaryCache(projectID: project.id)
        let freshStore = try ProjectStore(rootURL: root)
        let restored = try await freshStore.loadParsedOutput(projectID: project.id)
        XCTAssertEqual(restored, cached)
        XCTAssertEqual(try Data(contentsOf: filePaths.itemJSON(loaded.items[0].id)), textBefore)
        XCTAssertEqual(try Data(contentsOf: filePaths.projectJSON), projectBefore)
    }

    func testMissingCorruptAndIncompatibleCachesAreMissesWithoutChangingTheProject() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, project) = try await importedPaste(in: root)
        let filePaths = paths(project, root: root)
        let original = try Data(contentsOf: filePaths.parsedOutputCache)
        let projectBefore = try Data(contentsOf: filePaths.projectJSON)
        try FileManager.default.removeItem(at: filePaths.parsedOutputCache)
        let missing = try await store.loadParsedOutput(projectID: project.id)
        XCTAssertNil(missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: filePaths.parsedOutputCache.path))

        try Data("not JSON".utf8).write(to: filePaths.parsedOutputCache)
        let corrupt = try await store.loadParsedOutput(projectID: project.id)
        XCTAssertNil(corrupt)
        for (key, value) in [
            ("schemaVersion", 999 as Any),
            ("producerID", "incompatible-parser" as Any),
            ("sourceRevision", String(repeating: "0", count: 64) as Any),
            ("sourceID", UUID().uuidString as Any)
        ] {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
            json[key] = value
            try JSONSerialization.data(withJSONObject: json).write(to: filePaths.parsedOutputCache)
            let incompatible = try await store.loadParsedOutput(projectID: project.id)
            XCTAssertNil(incompatible, "Expected a cache miss for \(key)")
        }
        XCTAssertEqual(try Data(contentsOf: filePaths.projectJSON), projectBefore)
        let loaded = try await store.loadProject(projectID: project.id)
        XCTAssertEqual(loaded.items.first?.text, "First paragraph.\n\nSecond paragraph.")
    }

    func testSavingCacheRejectsAnotherSourceAndKeepsPreviousCache() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, project) = try await importedPaste(in: root)
        let original = try await store.loadParsedOutput(projectID: project.id)
        let unrelated = ProjectSource(
            type: .paste, originalFileName: "other.txt",
            relativePath: "source/other.txt", sourceRevision: project.source.sourceRevision
        )
        let wrong = ParsedImportCache(source: unrelated, items: [], output: .paste(rawText: "Other"))
        do {
            try await store.saveParsedOutput(projectID: project.id, cache: wrong)
            XCTFail("A different source ID must not replace the cache")
        } catch let error as ProjectStoreError {
            guard case .invalidData = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let remaining = try await store.loadParsedOutput(projectID: project.id)
        XCTAssertEqual(remaining, original)
    }

    func testSubtitleImportRetainsCueIDsTimingAndMetadataAfterReopen() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appending(path: "captions.srt")
        try """
        1
        00:00:01,000 --> 00:00:02,500
        First cue.

        2
        00:00:03,000 --> 00:00:04,000
        Second cue.
        """.write(to: input, atomically: true, encoding: .utf8)
        let store = try ProjectStore(rootURL: root.appending(path: "Projects"))
        let result = try await ReadAloudImportCoordinator(projectStore: store).importSource(.file(input))
        let freshStore = try ProjectStore(rootURL: store.rootURL)
        let cachedValue = try await freshStore.loadParsedOutput(projectID: result.project.id)
        let cache = try XCTUnwrap(cachedValue)
        guard case .document(let document) = cache.output else { return XCTFail("Missing document") }
        XCTAssertEqual(document.format, "srt")
        XCTAssertEqual(document.segments.count, 2)
        XCTAssertEqual(document.segments[0].startTime, 1)
        XCTAssertEqual(document.segments[0].endTime, 2.5)
        XCTAssertEqual(document.segments[1].startTime, 3)
        XCTAssertFalse(document.segments[0].id.isEmpty)
        XCTAssertNotEqual(document.segments[0].id, document.segments[1].id)
        XCTAssertTrue(document.rawText?.contains("00:00:01,000") == true)
    }

    func testMarkdownCacheRetainsRawCodeWithoutChangingCurrentSavedSpeech() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appending(path: "notes.md")
        let raw = "# Notes\n\nA spoken paragraph.\n\n" + String(repeating: "`", count: 3)
            + "swift\nlet secret = 42\n" + String(repeating: "`", count: 3) + "\n"
        try raw.write(to: input, atomically: true, encoding: .utf8)
        let imported = try await TextDocumentImportAdapter().importDocument(from: input, progress: nil)
        guard case .document(let cached)? = imported.parsedOutput else { return XCTFail("Missing output") }
        XCTAssertEqual(cached.rawText, raw)
        XCTAssertFalse(imported.items.map(\.normalizedText).joined().contains("let secret"))
    }

    func testPDFCacheRoundTripRetainsOmissionsAndInitiallySkippedChapterMapping() throws {
        let body = try PdfSemanticElement(content: .paragraph(text: "Main text."))
        let note = try PdfSemanticElement(content: .footnote(text: "Optional note."))
        let result = PdfReadingResult(title: "PDF", items: [
            try PdfReadingItem(
                element: body, sourceElementIDs: ["body-source"],
                decision: PdfReadingDecision(disposition: .read, evidence: .supportedContent, reason: .includeByDefault)
            ),
            try PdfReadingItem(
                element: note, sourceElementIDs: ["note-source"],
                decision: PdfReadingDecision(disposition: .skip, evidence: .supportedContent, reason: .optionalContent)
            )
        ])
        let source = ProjectSource(
            type: .pdf, originalFileName: "fixture.pdf", relativePath: "source/fixture.pdf",
            sourceRevision: ProjectDigest.sha256("fixture")
        )
        let cached = ParsedImportCache(source: source, items: [], output: .pdf(
            result: result,
            chapters: [
                ParsedPDFChapter(id: "body", title: "Main", order: 0, firstPage: 0, lastPage: 0, sourceElementIDs: ["body-source"]),
                ParsedPDFChapter(id: "notes", title: "Notes", order: 1, firstPage: 1, lastPage: 1, sourceElementIDs: ["note-source"])
            ]
        ))
        let decoded = try ProjectJSONCodec.decode(
            ParsedImportCache.self, from: ProjectJSONCodec.encode(cached),
            relativePath: "cache/parsed/blocks.json"
        )
        guard case .pdf(let restored, let chapters) = decoded.output else { return XCTFail("Missing PDF") }
        XCTAssertEqual(restored.items, result.items)
        XCTAssertEqual(restored.omissions.first?.element.text, "Optional note.")
        XCTAssertEqual(chapters[1].sourceElementIDs, ["note-source"])
        XCTAssertEqual(decoded, cached)
    }
}


@MainActor
final class VoicePreviewCacheTests: XCTestCase {
    private actor Engine: SpeechSynthesisEngine {
        private(set) var synthesisCount = 0
        private(set) var unloadCount = 0
        private var hold: Bool
        private let started: @Sendable () -> Void
        private var waiter: CheckedContinuation<Void, Never>?

        init(hold: Bool = false, started: @escaping @Sendable () -> Void = {}) {
            self.hold = hold
            self.started = started
        }
        func load() async throws {}
        func unload() async { unloadCount += 1 }
        func warmUp(text: String, voice: SpeechVoice, speed: Float) async throws -> SpeechWarmUpResult {
            SpeechWarmUpResult(elapsedSeconds: 0)
        }
        func synthesize(
            text: String, voice: SpeechVoice, speed: Float, maxChunkSeconds: Double
        ) async throws -> SpeechSynthesisResult {
            try await synthesize(
                text: text, voice: voice, speed: speed, maxChunkSeconds: maxChunkSeconds,
                pronunciationMode: .adaptive
            )
        }
        func synthesize(
            text: String, voice: SpeechVoice, speed: Float, maxChunkSeconds: Double,
            pronunciationMode: PronunciationFallbackMode
        ) async throws -> SpeechSynthesisResult {
            synthesisCount += 1
            if hold {
                hold = false
                await withCheckedContinuation { waiter in
                    self.waiter = waiter
                    started()
                }
            }
            // Deliberately ignore cancellation: the cache/controller must still
            // reject a late result from an already in-flight inference.
            return SpeechSynthesisResult(
                audio: KokoroAudio(samples: [0, 0.25, -0.25], sampleRate: 24_000),
                elapsedSeconds: 0
            )
        }
        func release() {
            waiter?.resume()
            waiter = nil
        }
    }

    private func request(
        voice: SpeechVoice = .heart, text: String = "Hello.",
        mode: PronunciationFallbackMode = .adaptive
    ) -> VoicePreviewRequest {
        VoicePreviewRequest(voice: voice, text: text, pronunciationMode: mode)
    }

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    func testCachedPreviewSurvivesCacheRecreation() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = Engine()
        let cache = VoicePreviewCache(rootURL: root, engine: engine)
        let first = try await cache.audioURL(for: request())
        let second = try await cache.audioURL(for: request())
        XCTAssertEqual(first, second)
        let count = await engine.synthesisCount
        XCTAssertEqual(count, 1)
        let freshEngine = Engine()
        let freshCache = VoicePreviewCache(rootURL: root, engine: freshEngine)
        let restored = try await freshCache.audioURL(for: request())
        XCTAssertEqual(restored, first)
        let freshCount = await freshEngine.synthesisCount
        XCTAssertEqual(freshCount, 0)
        let unloads = await engine.unloadCount
        XCTAssertEqual(unloads, 0)
    }

    func testTextVoiceAndPronunciationModeHaveSeparateCacheEntries() throws {
        let key = try request().cacheKey
        XCTAssertNotEqual(key, try request(text: "Another sample.").cacheKey)
        XCTAssertNotEqual(key, try request(voice: .bella).cacheKey)
        XCTAssertNotEqual(key, try request(mode: .skip).cacheKey)
        XCTAssertEqual(key, try request().cacheKey)
    }

    func testCorruptAndEvictedPreviewsRegenerate() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = Engine()
        let cache = VoicePreviewCache(rootURL: root, engine: engine)
        let url = try await cache.audioURL(for: request())
        try Data("not a WAV".utf8).write(to: url)
        _ = try await cache.audioURL(for: request())
        let regenerated = try ProjectWAVCodec.decode(Data(contentsOf: url))
        XCTAssertEqual(regenerated.samples.count, 3)
        try FileManager.default.removeItem(at: url)
        _ = try await cache.audioURL(for: request())
        let count = await engine.synthesisCount
        XCTAssertEqual(count, 3)
    }

    func testCancelledInferenceCannotPublishCacheFile() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let started = expectation(description: "Preview inference started")
        let engine = Engine(hold: true) { started.fulfill() }
        let cache = VoicePreviewCache(rootURL: root, engine: engine)
        let request = request()
        let task = Task { try await cache.audioURL(for: request) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await engine.release()
        do {
            _ = try await task.value
            XCTFail("Cancelled preview wrote audio")
        } catch is CancellationError {
            // Expected even though the engine returned audio after cancellation.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let unloads = await engine.unloadCount
        XCTAssertEqual(unloads, 0)
    }

    func testStoppedPreviewCannotPauseBookOrRestartAfterLateSynthesis() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let started = expectation(description: "Preview inference started")
        let engine = Engine(hold: true) { started.fulfill() }
        let cache = VoicePreviewCache(rootURL: root, engine: engine)
        let controller = VoicePreviewController(cache: cache)
        controller.preview(.heart, text: "Hello.") { XCTFail("Stale preview paused book") }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(controller.activeVoiceID, SpeechVoice.heart.id)
        XCTAssertTrue(controller.isPreparing)
        controller.stop()
        await engine.release()
        // A barrier behind the old cache request lets its cancelled continuation
        // finish without touching real audio hardware.
        _ = try await cache.audioURL(for: request(text: "Barrier."))
        await Task.yield()
        XCTAssertNil(controller.activeVoiceID)
        XCTAssertFalse(controller.isPreparing)
        XCTAssertNil(controller.errorMessage)
        controller.shutdown()
    }
}

@MainActor
final class PlaybackContinuityTests: XCTestCase {
    private enum FixtureError: Error { case loadFailed, unusedFilePlayback, waitTimedOut }

    @MainActor private final class AudioGate {
        let requested = XCTestExpectation(description: "Chunk requested")
        private var waiter: CheckedContinuation<KokoroAudio, Error>?
        private var result: Result<KokoroAudio, Error>?
        func load() async throws -> KokoroAudio {
            requested.fulfill()
            if let result { return try result.get() }
            return try await withCheckedThrowingContinuation { waiter = $0 }
        }
        func finish(_ result: Result<KokoroAudio, Error>) {
            self.result = result
            waiter?.resume(with: result)
            waiter = nil
        }
    }

    @MainActor fileprivate final class Playback: SpeechPlaybackOutput {
        private struct Buffer {
            let audio: KokoroAudio
            let onStart: (@MainActor () -> Void)?
            var started = false
        }
        var onSnapshotChange: ((SpeechPlaybackQueue.Snapshot) -> Void)?
        var onSessionEvent: ((SpeechPlaybackQueue.SessionEvent) -> Void)?
        var onEnqueued: (() -> Void)?
        private var buffers: [Buffer] = []
        private var paused = false
        private var depthWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
        private var drainWaiters: [CheckedContinuation<Void, Never>] = []
        private(set) var playedSeconds = 0.0
        private(set) var enqueueCount = 0
        var snapshot: SpeechPlaybackQueue.Snapshot {
            SpeechPlaybackQueue.Snapshot(
                queuedBuffers: buffers.count,
                queuedDurationSeconds: buffers.reduce(0) { $0 + $1.audio.durationSeconds },
                isPlaying: !paused && !buffers.isEmpty
            )
        }
        func prepare() throws {}
        func enqueue(_ audio: KokoroAudio, onPlaybackStart: (@MainActor () -> Void)?) throws {
            buffers.append(Buffer(audio: audio, onStart: onPlaybackStart))
            enqueueCount += 1
            announceFirst(); notify(); onEnqueued?()
        }
        func enqueueFile(at url: URL, startSeconds: Double) throws { throw FixtureError.unusedFilePlayback }
        func waitUntilQueueDepthBelow(_ limit: Int) async {
            if buffers.count >= limit {
                await withCheckedContinuation { depthWaiters.append((limit, $0)) }
            }
        }
        func waitUntilDrained() async {
            if !buffers.isEmpty { await withCheckedContinuation { drainWaiters.append($0) } }
        }
        func pause() { paused = true; notify() }
        func resume() throws { paused = false; announceFirst(); notify() }
        func stop() { buffers.removeAll(); paused = false; notify(); releaseWaiters() }
        func shutdown() { stop() }
        func finishNext() {
            guard !paused, !buffers.isEmpty else { return }
            playedSeconds += buffers.removeFirst().audio.durationSeconds
            announceFirst(); notify(); releaseWaiters()
        }
        private func announceFirst() {
            guard !paused, !buffers.isEmpty, !buffers[0].started else { return }
            buffers[0].started = true
            buffers[0].onStart?()
        }
        private func notify() { onSnapshotChange?(snapshot) }
        private func releaseWaiters() {
            let ready = depthWaiters.filter { buffers.count < $0.0 }
            depthWaiters.removeAll { buffers.count < $0.0 }
            for (_, waiter) in ready { waiter.resume() }
            if buffers.isEmpty {
                let waiters = drainWaiters
                drainWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }
    }

    private func waitFor(_ expectation: XCTestExpectation) async throws {
        let result = await XCTWaiter.fulfillment(of: [expectation], timeout: 2)
        guard result == .completed else {
            XCTFail("Playback did not reach the expected boundary")
            throw FixtureError.waitTimedOut
        }
    }

    private func audio() -> KokoroAudio {
        KokoroAudio(samples: Array(repeating: 0.25, count: 240), sampleRate: 24_000)
    }

    func testStarvationRecoversWhenAudioReturnsWithoutCountingFinalDrain() async throws {
        let output = Playback()
        var now = 0.0
        let pipeline = ReadAloudPipeline(playback: output, now: { now })
        let gate = AudioGate()
        let secondEnqueued = expectation(description: "Second buffer enqueued")
        output.onEnqueued = { if output.enqueueCount == 2 { secondEnqueued.fulfill() } }
        var diagnostics: [SpeechPlaybackDiagnostic] = []
        pipeline.onDiagnostic = { diagnostics.append($0) }
        let audio = audio()
        let task = Task {
            try await pipeline.playChunkStream(count: 2, continuous: false, loadAudio: { index in
                if index == 0 { return audio }
                return try await gate.load()
            }, onChunkStarted: { _ in })
        }
        defer {
            task.cancel()
            pipeline.shutdown()
            output.onEnqueued = nil
            gate.finish(.failure(CancellationError()))
        }
        try await waitFor(gate.requested)
        XCTAssertEqual(pipeline.state, .playing)
        now = 1
        output.finishNext()
        XCTAssertEqual(pipeline.state, .buffering)
        XCTAssertEqual(diagnostics, [.starvationStarted])
        now = 4
        gate.finish(.success(audio))
        try await waitFor(secondEnqueued)
        XCTAssertEqual(pipeline.state, .playing)
        XCTAssertEqual(diagnostics, [.starvationStarted, .starvationEnded(seconds: 3, reason: .resumed)])
        output.finishNext()
        try await task.value
        XCTAssertEqual(pipeline.state, .finished)
        XCTAssertEqual(diagnostics.count, 2)
    }

    func testPauseExcludesUserWaitingAndEmptyResumeRemainsBuffering() async throws {
        let output = Playback()
        var now = 0.0
        let pipeline = ReadAloudPipeline(playback: output, now: { now })
        let gate = AudioGate()
        let secondEnqueued = expectation(description: "Second buffer enqueued")
        output.onEnqueued = { if output.enqueueCount == 2 { secondEnqueued.fulfill() } }
        var diagnostics: [SpeechPlaybackDiagnostic] = []
        pipeline.onDiagnostic = { diagnostics.append($0) }
        let audio = audio()
        let task = Task {
            try await pipeline.playChunkStream(count: 2, continuous: false, loadAudio: { index in
                if index == 0 { return audio }
                return try await gate.load()
            }, onChunkStarted: { _ in })
        }
        defer {
            task.cancel()
            pipeline.shutdown()
            output.onEnqueued = nil
            gate.finish(.failure(CancellationError()))
        }
        try await waitFor(gate.requested)
        now = 1
        output.finishNext()
        now = 3
        pipeline.pause()
        XCTAssertEqual(pipeline.state, .paused)
        now = 50
        pipeline.resume()
        XCTAssertEqual(pipeline.state, .buffering)
        now = 53
        gate.finish(.success(audio))
        try await waitFor(secondEnqueued)
        XCTAssertEqual(diagnostics, [
            .starvationStarted, .starvationEnded(seconds: 2, reason: .paused),
            .starvationStarted, .starvationEnded(seconds: 3, reason: .resumed),
        ])
        output.finishNext()
        try await task.value
    }

    func testPreparedAudioDoesNotStartOrAdvanceAudibleChapterWhilePaused() async throws {
        let output = Playback()
        let pipeline = ReadAloudPipeline(playback: output)
        let gate = AudioGate()
        let enqueued = expectation(description: "Paused buffer enqueued")
        output.onEnqueued = { enqueued.fulfill() }
        var started: [Int] = []
        let task = Task {
            try await pipeline.playChunkStream(count: 1, continuous: false,
                loadAudio: { _ in try await gate.load() }, onChunkStarted: { started.append($0) })
        }
        defer {
            task.cancel()
            pipeline.shutdown()
            output.onEnqueued = nil
            gate.finish(.failure(CancellationError()))
        }
        try await waitFor(gate.requested)
        pipeline.pause()
        gate.finish(.success(audio()))
        try await waitFor(enqueued)
        XCTAssertEqual(pipeline.state, .paused)
        XCTAssertTrue(started.isEmpty)
        pipeline.resume()
        XCTAssertEqual(pipeline.state, .playing)
        XCTAssertEqual(started, [0])
        output.finishNext()
        try await task.value
    }

    func testStopWhileBufferingRejectsLateChunkWithoutFailure() async throws {
        let output = Playback()
        var now = 0.0
        let pipeline = ReadAloudPipeline(playback: output, now: { now })
        let gate = AudioGate()
        let audio = audio()
        var diagnostics: [SpeechPlaybackDiagnostic] = []
        pipeline.onDiagnostic = { diagnostics.append($0) }
        let task = Task {
            try await pipeline.playChunkStream(count: 2, loadAudio: { index in
                if index == 0 { return audio }
                return try await gate.load()
            }, onChunkStarted: { _ in })
        }
        defer {
            task.cancel()
            pipeline.shutdown()
            output.onEnqueued = nil
            gate.finish(.failure(CancellationError()))
        }
        try await waitFor(gate.requested)
        now = 2
        output.finishNext()
        now = 4
        pipeline.stop()
        gate.finish(.success(audio))
        do { try await task.value; XCTFail("Stopped stream must not succeed") }
        catch ReadAloudPipeline.PipelineError.cancelled {}
        XCTAssertEqual(pipeline.state, .idle)
        XCTAssertEqual(output.enqueueCount, 1)
        XCTAssertEqual(diagnostics, [.starvationStarted, .starvationEnded(seconds: 2, reason: .stopped)])
    }

    func testFailedChunkEndsBufferingWithRetryableFailure() async throws {
        let output = Playback()
        let pipeline = ReadAloudPipeline(playback: output)
        let gate = AudioGate()
        let audio = audio()
        let task = Task {
            try await pipeline.playChunkStream(count: 2, loadAudio: { index in
                if index == 0 { return audio }
                return try await gate.load()
            }, onChunkStarted: { _ in })
        }
        defer {
            task.cancel()
            pipeline.shutdown()
            output.onEnqueued = nil
            gate.finish(.failure(CancellationError()))
        }
        try await waitFor(gate.requested)
        output.finishNext()
        gate.finish(.failure(FixtureError.loadFailed))
        do { try await task.value; XCTFail("Chunk failure must be surfaced") }
        catch FixtureError.loadFailed {}
        guard case .failed = pipeline.state else { return XCTFail("Expected a retryable failure") }
        XCTAssertEqual(output.snapshot.queuedBuffers, 0)
    }

    func testInitialPreparationAndNormalDrainAreNotStarvation() {
        var monitor = SpeechStreamContinuity()
        let loading = monitor.update(queuedBuffers: 0, outputIsPlaying: false,
            expectingMore: true, paused: false, now: 0)
        XCTAssertEqual(loading.phase, .loading)
        XCTAssertNil(loading.diagnostic)
        let playing = monitor.update(queuedBuffers: 1, outputIsPlaying: true,
            expectingMore: false, paused: false, now: 5)
        XCTAssertEqual(playing.phase, .playing)
        let drained = monitor.update(queuedBuffers: 0, outputIsPlaying: false,
            expectingMore: false, paused: false, now: 10)
        XCTAssertEqual(drained.phase, .drained)
        XCTAssertNil(drained.diagnostic)
    }

    func testBufferingKeepsPlaybackOwnershipWithoutClaimingAudibleOutput() {
        var activity = ProjectRuntimeActivity(playbackState: .buffering, queuedAudioBuffers: 1)
        XCTAssertTrue(activity.hasActivePlaybackWork)
        XCTAssertFalse(activity.hasAudiblePlayback)
        activity.playbackState = .playing
        XCTAssertTrue(activity.hasAudiblePlayback)
        activity.queuedAudioBuffers = 0
        XCTAssertFalse(activity.hasAudiblePlayback)
        activity.playbackState = .paused
        XCTAssertTrue(activity.hasActivePlaybackWork)
        XCTAssertFalse(activity.hasAudiblePlayback)
    }

    func testReadAheadFillsTwentyWithoutAudibleProgressAndKeepsPreparedAudio() async throws {
        // Playback pause has no producer signal: the fixed audible position
        // lets the same window fill in foreground or background, then sleep.
        let window = ChunkReadAhead(startIndex: 100)
        let audio = audio()
        for index in 100..<120 {
            _ = try await window.loadAudio(for: index) { audio }
            await window.markReady(index)
        }
        try await window.awaitReady(119)
        let full = await window.canProduce(120)
        XCTAssertFalse(full)
        await window.markAudible(100)
        let advanced = await window.canProduce(120)
        XCTAssertTrue(advanced)
    }

    func testActiveReadAheadStopsAtTwentyAndResumesWithAudibleProgress() async throws {
        let window = ChunkReadAhead(startIndex: 100)
        let audio = audio()
        for index in 100..<120 {
            _ = try await window.loadAudio(for: index) { audio }
            await window.markReady(index)
        }
        let lastAllowed = await window.canProduce(119)
        let outsideWindow = await window.canProduce(120)
        XCTAssertTrue(lastAllowed)
        XCTAssertFalse(outsideWindow)
        let pending = Task { try await window.loadAudio(for: 120) { audio } }
        defer { pending.cancel() }
        let deadline = Date().addingTimeInterval(2)
        while await window.waitingProductionCount == 0, Date() < deadline {
            await Task.yield()
        }
        let waiting = await window.waitingProductionCount
        guard waiting == 1 else { XCTFail("Producer did not suspend at capacity"); return }
        // Audible start frees exactly one slot, even from a nonzero seek offset.
        await window.markAudible(100)
        let received = try await pending.value
        XCTAssertEqual(received.samples, audio.samples)
        let nextOutside = await window.canProduce(121)
        XCTAssertFalse(nextOutside)
        // Old audible callbacks cannot advance or move the window backwards.
        await window.markAudible(99)
        let stillOutside = await window.canProduce(121)
        XCTAssertFalse(stillOutside)
    }

    func testCancelledProducerExitsFullReadAheadWindow() async throws {
        let window = ChunkReadAhead(startIndex: 0)
        let pending = Task { try await window.awaitProduction(for: 20) }
        defer { pending.cancel() }
        let deadline = Date().addingTimeInterval(2)
        while await window.waitingProductionCount == 0, Date() < deadline {
            await Task.yield()
        }
        let waiting = await window.waitingProductionCount
        guard waiting == 1 else { XCTFail("Producer did not suspend at capacity"); return }
        pending.cancel()
        do { try await pending.value; XCTFail("Cancelled capacity wait must unwind") }
        catch is CancellationError { }
        let remaining = await window.waitingProductionCount
        XCTAssertEqual(remaining, 0)
    }

    func testCancelledReadyWaitExitsWithoutPolling() async throws {
        let window = ChunkReadAhead(startIndex: 0)
        let waiter = Task { try await window.awaitReady(5) }
        waiter.cancel()
        do { try await waiter.value; XCTFail("Cancelled readiness must unwind") }
        catch is CancellationError { }
    }

    func testReplacementReadAheadStartsAtNewSeekOffset() async {
        let old = ChunkReadAhead(startIndex: 0)
        await old.markAudible(100)
        let replacement = ChunkReadAhead(startIndex: 500)
        let lastAllowed = await replacement.canProduce(519)
        let outside = await replacement.canProduce(520)
        XCTAssertTrue(lastAllowed)
        XCTAssertFalse(outside)
    }

    func testPreparedChunksRemainReadableAfterProducerFailure() async throws {
        let window = ChunkReadAhead(startIndex: 0)
        await window.markReady(0)
        await window.fail(CancellationError())
        try await window.awaitReady(0)
        do { try await window.awaitReady(1); XCTFail("Unprepared audio must report producer failure") }
        catch is CancellationError { }
    }

}

// Cache lifecycle cases live in this already registered source file so the
// owner-managed generated Xcode project does not need to be regenerated.
@MainActor
final class SharedChunkAudioCacheLifecycleTests: XCTestCase {
    private actor SynthesisGate {
        private var started = false
        private var released = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var finishWaiter: CheckedContinuation<Void, Never>?
        private(set) var calls = 0

        // Deliberately ignore cancellation to model a native inference that
        // cannot be interrupted in the middle of session.run().
        func synthesize(_ audio: KokoroAudio) async -> KokoroAudio {
            calls += 1
            started = true
            let waiters = startWaiters
            startWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            if !released {
                await withCheckedContinuation { finishWaiter = $0 }
            }
            return audio
        }

        func waitUntilStarted() async {
            if !started {
                await withCheckedContinuation { startWaiters.append($0) }
            }
        }

        func release() {
            released = true
            finishWaiter?.resume()
            finishWaiter = nil
        }
    }

    private enum FixtureError: Error, Equatable { case schedulingTimeout, synthesisFailed }

    private func request(itemID: UUID = UUID(), generation: String = "original") -> ChunkAudioRequest {
        ChunkAudioRequest(
            itemID: itemID, index: 0,
            chunk: SpeechChunk(
                id: 0, text: "A spoken sentence.",
                sourceRange: AudioSourceRange(startUTF16: 0, endUTF16: 18),
                targetBucketSeconds: 3, maxChunkSeconds: 3, estimatedDurationSeconds: 1
            ),
            generationKey: generation,
            resolved: ResolvedNarrationSettings(voiceID: "af_heart", speed: 1),
            runtimeRevision: "lifecycle-test", synthesisConfigVersion: 4
        )
    }

    private func audio(_ sample: Float = 0.25) -> KokoroAudio {
        KokoroAudio(samples: Array(repeating: sample, count: 240), sampleRate: 24_000)
    }

    private func packageURL() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "ReadAloud-CacheLifecycle-\(UUID().uuidString).readaloud",
            directoryHint: .isDirectory
        )
    }

    private func waitForCounts(
        _ cache: SharedChunkAudioCache, consumers: Int, producers: Int
    ) async throws {
        // Only used to arrange a race; assertions below check consumer
        // cancellation, cache contents and independent replacement results.
        for _ in 0..<10_000 {
            let actualConsumers = await cache.activeConsumerCount
            let actualProducers = await cache.activeProducerCount
            if actualConsumers == consumers, actualProducers == producers { return }
            await Task.yield()
        }
        XCTFail("Cache did not reach the required race boundary")
        throw FixtureError.schedulingTimeout
    }

    private func assertCancelled(_ result: Result<KokoroAudio, Error>) {
        switch result {
        case .success: XCTFail("Cancelled consumer received audio")
        case .failure(let error): XCTAssertTrue(error is CancellationError)
        }
    }

    func testCancellingOneConsumerPreservesSharedSynthesisAndCommittedAudio() async throws {
        let url = packageURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = SharedChunkAudioCache(packageURL: url)
        let request = request()
        let audio = audio()
        let gate = SynthesisGate()
        defer { Task { await gate.release() } }
        let first = Task { try await cache.audio(for: request) { await gate.synthesize(audio) } }
        await gate.waitUntilStarted()
        let second = Task { try await cache.audio(for: request) { await gate.synthesize(audio) } }
        try await waitForCounts(cache, consumers: 2, producers: 1)
        first.cancel()
        assertCancelled(await first.result)
        // Cancellation must complete while the native producer is still held.
        await gate.release()
        let completed = try await second.value
        XCTAssertEqual(completed.samples, audio.samples)
        let calls = await gate.calls
        XCTAssertEqual(calls, 1)
        let cached = try await cache.load(request)
        XCTAssertEqual(cached?.samples.count, audio.samples.count)
        await cache.shutdown()
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.directory.path))
    }

    func testCancelledProducerCannotWriteOrRemoveSameKeyReplacement() async throws {
        let url = packageURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = SharedChunkAudioCache(packageURL: url)
        let request = request()
        let oldAudio = audio(0.2)
        let newAudio = audio(0.4)
        let oldGate = SynthesisGate()
        let newGate = SynthesisGate()
        defer { Task { await oldGate.release(); await newGate.release() } }
        let old = Task { try await cache.audio(for: request) { await oldGate.synthesize(oldAudio) } }
        await oldGate.waitUntilStarted()
        old.cancel()
        assertCancelled(await old.result)
        let replacement = Task {
            try await cache.audio(for: request) { await newGate.synthesize(newAudio) }
        }
        await newGate.waitUntilStarted()
        await oldGate.release()
        try await waitForCounts(cache, consumers: 1, producers: 1)
        let stale = try await cache.load(request)
        XCTAssertNil(stale)
        await newGate.release()
        let completed = try await replacement.value
        XCTAssertEqual(completed.samples, newAudio.samples)
        await cache.shutdown()
    }

    func testClearDrainsUninterruptibleWorkAndPreventsLateRepopulation() async throws {
        let url = packageURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = SharedChunkAudioCache(packageURL: url)
        let request = request()
        let audio = audio()
        let gate = SynthesisGate()
        defer { Task { await gate.release() } }
        let consumer = Task { try await cache.audio(for: request) { await gate.synthesize(audio) } }
        await gate.waitUntilStarted()
        let clearing = Task { try await cache.clearAll() }
        assertCancelled(await consumer.result)
        do {
            _ = try await cache.audio(for: request) { audio }
            XCTFail("Clear must close admission while inference is draining")
        } catch is CancellationError { }
        await gate.release()
        try await clearing.value
        let stale = try await cache.load(request)
        XCTAssertNil(stale)
        let regenerated = try await cache.audio(for: request) { audio }
        XCTAssertEqual(regenerated.samples, audio.samples)
        await cache.shutdown()
    }

    func testScopedNestedInvalidationBlocksChangedGenerationUntilBothTokensRelease() async throws {
        let url = packageURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = SharedChunkAudioCache(packageURL: url)
        let itemID = UUID()
        let original = request(itemID: itemID)
        let changed = request(itemID: itemID, generation: "changed")
        let other = request()
        let audio = audio()
        let gate = SynthesisGate()
        defer { Task { await gate.release() } }
        let consumer = Task { try await cache.audio(for: original) { await gate.synthesize(audio) } }
        await gate.waitUntilStarted()
        let invalidating = Task { await cache.suspendAndDrain(itemIDs: [itemID]) }
        assertCancelled(await consumer.result)
        await gate.release()
        let firstToken = await invalidating.value
        let secondToken = await cache.suspendAndDrain(itemIDs: [itemID])
        await cache.resumeAdmission(firstToken)
        do {
            _ = try await cache.audio(for: changed) { audio }
            XCTFail("A nested invalidation still owns admission")
        } catch is CancellationError { }
        let unrelated = try await cache.audio(for: other) { audio }
        XCTAssertEqual(unrelated.samples, audio.samples)
        await cache.resumeAdmission(secondToken)
        let stale = try await cache.load(original)
        XCTAssertNil(stale)
        let regenerated = try await cache.audio(for: changed) { audio }
        XCTAssertEqual(regenerated.samples, audio.samples)
        await cache.shutdown()
    }

    func testShutdownRejectsFutureRequestsWithoutDeletingCompletedChunks() async throws {
        let url = packageURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = SharedChunkAudioCache(packageURL: url)
        let request = request()
        let audio = audio()
        _ = try await cache.audio(for: request) { audio }
        await cache.shutdown()
        do {
            _ = try await cache.audio(for: request) { audio }
            XCTFail("A shut-down runtime cannot admit new consumers")
        } catch is CancellationError { }
        let reopened = SharedChunkAudioCache(packageURL: url)
        let preserved = try await reopened.load(request)
        XCTAssertEqual(preserved?.samples.count, audio.samples.count)
        await reopened.shutdown()
    }

    func testAlreadyCancelledConsumerCannotReceiveCachedAudio() async throws {
        let url = packageURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = SharedChunkAudioCache(packageURL: url)
        let request = request()
        let audio = audio()
        _ = try await cache.audio(for: request) { audio }
        let gate = SynthesisGate()
        let consumer = Task {
            _ = await gate.synthesize(audio)
            return try await cache.audio(for: request) { audio }
        }
        await gate.waitUntilStarted()
        consumer.cancel()
        await gate.release()
        assertCancelled(await consumer.result)
        let cached = try await cache.load(request)
        XCTAssertNotNil(cached)
        await cache.shutdown()
    }

    func testSharedFailureReleasesAllConsumersAndAllowsRetry() async throws {
        let url = packageURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = SharedChunkAudioCache(packageURL: url)
        let request = request()
        let audio = audio()
        let gate = SynthesisGate()
        defer { Task { await gate.release() } }
        let first = Task {
            try await cache.audio(for: request) {
                _ = await gate.synthesize(audio)
                throw FixtureError.synthesisFailed
            }
        }
        await gate.waitUntilStarted()
        let second = Task { try await cache.audio(for: request) { audio } }
        try await waitForCounts(cache, consumers: 2, producers: 1)
        await gate.release()
        for result in [await first.result, await second.result] {
            switch result {
            case .success: XCTFail("Both coalesced consumers must receive the failure")
            case .failure(let error):
                XCTAssertEqual(error as? FixtureError, .synthesisFailed)
            }
        }
        let retried = try await cache.audio(for: request) { audio }
        XCTAssertEqual(retried.samples, audio.samples)
        await cache.shutdown()
    }

    private actor AttemptCounter {
        private(set) var count = 0
        func next() -> Int { count += 1; return count }
    }

    func testStoppedReadAheadReleasesCacheConsumerAndReplacementRetriesSameChunk() async throws {
        let url = packageURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = SharedChunkAudioCache(packageURL: url)
        let request = request()
        let audio = audio()
        let gate = SynthesisGate()
        let attempts = AttemptCounter()
        let window = ChunkReadAhead(startIndex: 0)
        defer { Task { await gate.release() } }
        let listener = Task {
            try await window.loadAudio(for: 0) {
                try await cache.audio(for: request) {
                    if await attempts.next() == 1 { return await gate.synthesize(audio) }
                    return audio
                }
            }
        }
        await gate.waitUntilStarted()
        listener.cancel()
        do { _ = try await listener.value; XCTFail("Stopped producer must unwind") }
        catch is CancellationError { }
        try await waitForCounts(cache, consumers: 0, producers: 1)
        await gate.release()
        try await waitForCounts(cache, consumers: 0, producers: 0)
        let replacement = ChunkReadAhead(startIndex: 0)
        let received = try await replacement.loadAudio(for: 0) {
            try await cache.audio(for: request) {
                _ = await attempts.next()
                return audio
            }
        }
        XCTAssertEqual(received.samples, audio.samples)
        let count = await attempts.count
        XCTAssertEqual(count, 2)
        await cache.shutdown()
    }

    func testRapidReadAheadReplacementDoesNotLetOldProducerOverwriteRetry() async throws {
        let url = packageURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = SharedChunkAudioCache(packageURL: url)
        let request = request()
        let oldAudio = audio(0.2)
        let newAudio = audio(0.5)
        let gate = SynthesisGate()
        let attempts = AttemptCounter()
        let window = ChunkReadAhead(startIndex: 0)
        defer { Task { await gate.release() } }
        let listener = Task {
            try await window.loadAudio(for: 0) {
                try await cache.audio(for: request) {
                    if await attempts.next() == 1 { return await gate.synthesize(oldAudio) }
                    return newAudio
                }
            }
        }
        await gate.waitUntilStarted()
        listener.cancel()
        do { _ = try await listener.value; XCTFail("Replaced producer must unwind") }
        catch is CancellationError { }
        let replacement = ChunkReadAhead(startIndex: 0)
        let received = try await replacement.loadAudio(for: 0) {
            try await cache.audio(for: request) { newAudio }
        }
        XCTAssertEqual(received.samples, newAudio.samples)
        // The old native call is still held while its replacement finishes.
        await gate.release()
        try await waitForCounts(cache, consumers: 0, producers: 0)
        let cached = try await cache.load(request)
        XCTAssertEqual(cached?.samples.first ?? 0, 0.5, accuracy: 0.001)
        await cache.shutdown()
    }

    func testEngineUnloadDoesNotReopenAnExternallyHeldAdmissionBarrier() async throws {
        // No model assets are needed: closed admission must fail before load.
        let engine = KokoroONNXEngine()
        let first = await engine.suspendAndDrain()
        let second = await engine.suspendAndDrain()
        await engine.unload()
        await engine.resumeAdmission(first)
        do {
            try await engine.load()
            XCTFail("Unload must preserve the external suspension")
        } catch is CancellationError { }
        do {
            _ = try await engine.synthesize(text: "Hello.", voice: .heart, speed: 1, maxChunkSeconds: 3)
            XCTFail("New inference must be rejected while resources are released")
        } catch is CancellationError { }
        await engine.resumeAdmission(second)
    }
}

/// Disk-backed regression tests: no PDF extraction or ONNX inference needed.
/// They exercise the storage contract used by reader-side policy changes.
final class PDFReadingPersistenceTests: XCTestCase {
    private struct Fixture: Sendable {
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
        root existingRoot: URL? = nil,
        firstText: String = "First spoken passage."
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
            order: 0, text: firstText
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

    /// All listening actions/assertions run without a suspension. Playback tasks
    /// are stopped before they can reach synthesis; transport uses fake output.
    @MainActor private static func withPlaybackRuntimes(
        _ fixtures: [Fixture],
        body: @MainActor (ProjectRuntimeManager, [ProjectRuntime]) throws -> Void
    ) async throws {
        let preferenceKey = ReadAloudPreferences.Key.backgroundPrefetchPaused
        let previous = UserDefaults.standard.object(forKey: preferenceKey)
        UserDefaults.standard.set(true, forKey: preferenceKey)
        defer { UserDefaults.standard.set(previous, forKey: preferenceKey) }
        let manager = ProjectRuntimeManager(
            store: fixtures[0].store,
            makePipeline: { ReadAloudPipeline(playback: PlaybackContinuityTests.Playback()) }
        )
        defer { manager.shutdownAll() }
        var runtimes: [ProjectRuntime] = []
        for fixture in fixtures {
            runtimes.append(try await manager.prepareRuntime(projectID: fixture.projectID))
        }
        let result = Result { try body(manager, runtimes) }
        for runtime in runtimes { runtime.stopPlayback() }
        for runtime in runtimes { await runtime.shutdownAndDrain() }
        try result.get()
    }

    func testExplicitListeningPreservesSessionWhileBrowsingAndOnRepeatedTaps() async throws {
        let a = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: a.root) }
        let b = try await makeFixture(root: a.root)
        try await Self.withPlaybackRuntimes([a, b]) { manager, runtimes in
            let first = runtimes[0], second = runtimes[1]
            XCTAssertNil(manager.playerRuntime)
            try first.listen(itemID: a.first.id)
            let operation = try XCTUnwrap(first.playbackOperationID)
            XCTAssertTrue(manager.playerRuntime === first)
            manager.beginReader(second)
            manager.makeActive(second)
            XCTAssertTrue(manager.activeRuntime === second)
            XCTAssertTrue(manager.playbackRuntime === first)
            try first.listen(itemID: a.first.id)
            XCTAssertEqual(first.playbackOperationID, operation)
            first.pausePlayback()
            try first.listen(itemID: a.first.id)
            XCTAssertFalse(first.isPlaybackPaused)
            XCTAssertEqual(first.playbackOperationID, operation)
            XCTAssertTrue(manager.playerRuntime === first)
        }
    }

    func testSwitchingBooksStopsPausedPreparationAndRejectsLateActivity() async throws {
        let a = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: a.root) }
        let b = try await makeFixture(root: a.root)
        try await Self.withPlaybackRuntimes([a, b]) { manager, runtimes in
            let first = runtimes[0], second = runtimes[1]
            let bookmark = first.project?.playback?.contentBookmark
            try first.listen(itemID: a.first.id)
            first.pausePlayback()
            manager.isPlayerExpanded = true
            try second.listen(itemID: b.first.id)
            XCTAssertTrue(manager.playerRuntime === second)
            XCTAssertFalse(manager.isPlayerExpanded)
            XCTAssertNil(first.playbackOperationID)
            XCTAssertFalse(first.isPlaybackActive)
            XCTAssertEqual(first.project?.playback?.contentBookmark, bookmark)
            first.pipeline.onEvent?(.state(.playing))
            XCTAssertFalse(first.isPlaybackActive)
            first.resumePlayback()
            XCTAssertTrue(manager.playbackRuntime === second)
        }
    }

    func testRapidBookSwitchThenCloseCannotResurrectEarlierPlayer() async throws {
        let a = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: a.root) }
        let b = try await makeFixture(root: a.root)
        let c = try await makeFixture(root: a.root)
        try await Self.withPlaybackRuntimes([a, b, c]) { manager, runtimes in
            try runtimes[0].listen(itemID: a.first.id)
            try runtimes[1].listen(itemID: b.first.id)
            try runtimes[2].listen(itemID: c.first.id)
            XCTAssertTrue(manager.playerRuntime === runtimes[2])
            XCTAssertNil(runtimes[0].playbackOperationID)
            XCTAssertNil(runtimes[1].playbackOperationID)
            manager.closePlayer(runtimes[0]) // A stale view cannot close C.
            XCTAssertTrue(manager.playerRuntime === runtimes[2])
            manager.closePlayer(runtimes[2])
            XCTAssertNil(manager.playerRuntime)
            XCTAssertNil(manager.playbackRuntime)
            XCTAssertTrue(runtimes[2].isPlayerDismissed)
            XCTAssertTrue(runtimes.allSatisfy { $0.playbackOperationID == nil })
            for runtime in runtimes { runtime.pipeline.onEvent?(.state(.loading)) }
            XCTAssertNil(manager.playerRuntime)
            XCTAssertTrue(runtimes.allSatisfy { !$0.isPlaybackActive })
            try runtimes[0].listen(itemID: a.first.id)
            XCTAssertTrue(manager.playerRuntime === runtimes[0])
            XCTAssertFalse(runtimes[0].isPlayerDismissed)
        }
    }

    func testFailedPreparationCanRetryBeforeOldTaskFinishesWithoutRevivingPreviousBook() async throws {
        let a = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: a.root) }
        let b = try await makeFixture(root: a.root)
        try await Self.withPlaybackRuntimes([a, b]) { manager, runtimes in
            let first = runtimes[0], second = runtimes[1]
            try first.listen(itemID: a.first.id)
            try second.listen(itemID: b.first.id)
            let failedOperation = second.playbackOperationID
            second.pipeline.onEvent?(.state(.failed("Fixture failure")))
            XCTAssertNotNil(second.playbackTask)
            XCTAssertEqual(second.playerActionLabel, "Retry")
            XCTAssertEqual(second.playerActionSymbol, "arrow.clockwise")
            try second.togglePlayer(itemID: b.first.id)
            XCTAssertNotEqual(second.playbackOperationID, failedOperation)
            XCTAssertEqual(second.activity.playbackState, .loading)
            XCTAssertTrue(manager.playerRuntime === second)
            XCTAssertFalse(first.isPlaybackActive)
        }
    }

    func testInterruptionCannotResumeReplacementSessionOrOverrideExplicitPause() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await Self.withPlaybackRuntimes([fixture]) { _, runtimes in
            let runtime = runtimes[0]
            try runtime.listen(itemID: fixture.first.id)
            runtime.pipeline.onAudioSessionEvent?(.interruptionBegan)
            XCTAssertTrue(runtime.isPlaybackPaused)
            try runtime.listen(itemID: fixture.second.id)
            runtime.pausePlayback()
            runtime.pipeline.onAudioSessionEvent?(.interruptionEnded(shouldResume: true))
            XCTAssertTrue(runtime.isPlaybackPaused)
            runtime.resumePlayback()
            runtime.pipeline.onAudioSessionEvent?(.interruptionBegan)
            runtime.pipeline.onAudioSessionEvent?(.interruptionEnded(shouldResume: true))
            XCTAssertFalse(runtime.isPlaybackPaused)
            runtime.pipeline.onAudioSessionEvent?(.interruptionBegan)
            runtime.pausePlayback() // An explicit pause cancels automatic resume.
            runtime.pipeline.onAudioSessionEvent?(.interruptionEnded(shouldResume: true))
            XCTAssertTrue(runtime.isPlaybackPaused)
        }
    }

    func testInvalidListeningRequestDoesNotInterruptCurrentBook() async throws {
        let a = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: a.root) }
        let b = try await makeFixture(root: a.root)
        try await Self.withPlaybackRuntimes([a, b]) { manager, runtimes in
            try runtimes[0].listen(itemID: a.first.id)
            let operation = runtimes[0].playbackOperationID
            XCTAssertThrowsError(try runtimes[1].listen(itemID: UUID()))
            XCTAssertTrue(manager.playerRuntime === runtimes[0])
            XCTAssertEqual(runtimes[0].playbackOperationID, operation)
            XCTAssertNil(runtimes[1].playbackOperationID)
        }
    }

    func testColdCustomPDFListeningCanClaimPreparationBeforeProjectionLoads() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.store.updatePDFReadingPolicy(
            projectID: fixture.projectID,
            policy: PdfReadingPolicy(includesFootnotes: true)
        )
        try await Self.withPlaybackRuntimes([fixture]) { manager, runtimes in
            let runtime = runtimes[0]
            XCTAssertFalse(runtime.pdfProjectionMatchesStoredText)
            try runtime.listen(itemID: fixture.first.id)
            XCTAssertTrue(manager.playerRuntime === runtime)
            XCTAssertEqual(runtime.activity.playbackState, .loading)
            manager.closePlayer(runtime)
            XCTAssertNil(runtime.playbackOperationID)
            XCTAssertNil(manager.playerRuntime)
        }
    }

    func testPlayerReaderNavigationAndOwnerRemovalKeepOneSession() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await Self.withPlaybackRuntimes([fixture]) { manager, runtimes in
            let runtime = runtimes[0]
            try runtime.listen(itemID: fixture.first.id)
            let operation = runtime.playbackOperationID
            manager.isPlayerExpanded = true
            manager.openPlayerReader()
            XCTAssertEqual(manager.playerReaderTarget?.projectID, fixture.projectID)
            XCTAssertEqual(manager.playerReaderTarget?.itemID, fixture.first.id)
            XCTAssertFalse(manager.isPlayerExpanded)
            manager.playerReaderTarget = nil
            manager.beginReader(runtime)
            let followRevision = manager.readerFollowRevision
            manager.openPlayerReader()
            XCTAssertNil(manager.playerReaderTarget)
            XCTAssertNotEqual(manager.readerFollowRevision, followRevision)
            XCTAssertEqual(runtime.playbackOperationID, operation)
            manager.endReader(runtime)
            manager.openPlayerReader()
            manager.forget(projectID: runtime.id)
            XCTAssertNil(manager.playerRuntime)
            XCTAssertNil(manager.playerReaderTarget)
            XCTAssertFalse(runtime.isPlaybackActive)
        }
    }

    func testReaderActivationReusesLoadedContentAndPreservesPausedOwner() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await Self.checkWarmReaderActivation(fixture)
    }

    @MainActor private static func checkWarmReaderActivation(_ fixture: Fixture) async throws {
        let key = ReadAloudPreferences.Key.backgroundPrefetchPaused
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        let manager = ProjectRuntimeManager(
            store: fixture.store,
            makePipeline: { ReadAloudPipeline(playback: PlaybackContinuityTests.Playback()) }
        )
        defer { manager.shutdownAll() }
        let runtime = try await manager.prepareRuntime(projectID: fixture.projectID)
        let originalTitle = runtime.project?.title
        let bookmark = runtime.project?.playback?.contentBookmark
        let revision = runtime.revision
        // A retained paused owner without launching real audio or synthesis.
        let operation = UUID()
        runtime.playerItemID = fixture.first.id
        runtime.activity.activeItemID = fixture.first.id
        runtime.activity.playbackState = .paused
        runtime.readerPauseRequested = true
        runtime.playbackOperationID = operation
        manager.claimPlayback(runtime)

        _ = try await fixture.store.renameProject(projectID: fixture.projectID, to: "Changed on disk")
        let activated = try await manager.activate(projectID: fixture.projectID)
        XCTAssertTrue(activated === runtime)
        XCTAssertTrue(manager.activeRuntime === runtime)
        XCTAssertTrue(manager.playerRuntime === runtime)
        XCTAssertEqual(runtime.project?.title, originalTitle, "Navigation must not hydrate disk content again")
        XCTAssertEqual(runtime.revision, revision)
        XCTAssertEqual(runtime.project?.playback?.contentBookmark, bookmark)
        XCTAssertEqual(runtime.playbackOperationID, operation)
        XCTAssertTrue(runtime.isPlaybackPaused)

        // Explicit refresh remains the way to observe durable content changes.
        try await manager.refreshIfLoaded(projectID: fixture.projectID)
        XCTAssertEqual(runtime.project?.title, "Changed on disk")

        let source = try XCTUnwrap(runtime.project?.source)
        let sourceURL = runtime.packageURL.appendingPathComponent(source.relativePath)
        try Data("changed source bytes".utf8).write(to: sourceURL)
        let reopened = try await manager.activate(projectID: fixture.projectID)
        XCTAssertTrue(reopened === runtime, "Warm navigation must not rehash the retained source")
        do {
            try await manager.refreshIfLoaded(projectID: fixture.projectID)
            XCTFail("Explicit refresh must retain source integrity checks")
        } catch {
            XCTAssertTrue(error is ProjectStoreError)
        }
        manager.forget(projectID: fixture.projectID)
        do {
            _ = try await manager.activate(projectID: fixture.projectID)
            XCTFail("Cold loads must retain source integrity checks")
        } catch {
            XCTAssertTrue(error is ProjectStoreError)
        }
        XCTAssertNil(manager.runtimeIfLoaded(projectID: fixture.projectID))
    }

    func testRecoveryPreservesIntentIdentityAndRejectsChangedSettings() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let oldKey = ProjectDigest.sha256("old")
        let newKey = ProjectDigest.sha256("new")
        let now = Date(timeIntervalSince1970: 100)
        let jobs = [fixture.first, fixture.second].map { item in
            GenerationJobRecord(
                id: UUID(), projectID: fixture.projectID, itemID: item.id,
                operation: .generate, generationKey: oldKey, state: .generating,
                createdAt: now, updatedAt: now, attempt: 2, lastError: nil
            )
        }
        try await fixture.store.saveQueue(projectID: fixture.projectID, queue: ProjectQueueDocument(jobs: jobs))
        let recovered = try await fixture.store.recoverGenerationQueue(
            projectID: fixture.projectID,
            generationKeys: [fixture.first.id: oldKey, fixture.second.id: newKey],
            now: now.addingTimeInterval(1)
        )
        XCTAssertEqual(recovered.jobs.map(\.id), jobs.map(\.id))
        XCTAssertEqual(recovered.jobs.map(\.attempt), [2, 2])
        XCTAssertEqual(recovered.jobs.map(\.state), [.queued, .failed])
        XCTAssertNotNil(recovered.jobs[1].lastError)
        let again = try await fixture.store.recoverGenerationQueue(
            projectID: fixture.projectID,
            generationKeys: [fixture.first.id: oldKey, fixture.second.id: newKey],
            now: now.addingTimeInterval(2)
        )
        XCTAssertEqual(again, recovered)
        // Recovery of a user-cancelled queue cannot recreate its old intent.
        _ = try await fixture.store.removeGenerationJobs(
            projectID: fixture.projectID, itemIDs: [fixture.first.id], states: [.queued]
        )
        let cancelled = try await fixture.store.recoverGenerationQueue(projectID: fixture.projectID)
        XCTAssertFalse(cancelled.jobs.contains { $0.id == jobs[0].id })
    }

    func testRecoveryCompletesOnlyMatchingValidatedOfflineIntent() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let key = ProjectDigest.sha256("original")
        let changed = ProjectDigest.sha256("changed")
        let now = Date()
        let jobs = [fixture.first, fixture.second].map { item in
            GenerationJobRecord(
                id: UUID(), projectID: fixture.projectID, itemID: item.id,
                operation: .generate, generationKey: key, state: .generating,
                createdAt: now, updatedAt: now, attempt: 1, lastError: nil
            )
        }
        try await fixture.store.saveQueue(projectID: fixture.projectID, queue: ProjectQueueDocument(jobs: jobs))
        let queue = try await fixture.store.recoverGenerationQueue(
            projectID: fixture.projectID,
            generationKeys: [fixture.first.id: key, fixture.second.id: changed],
            readyOfflineItemIDs: [fixture.first.id, fixture.second.id]
        )
        XCTAssertEqual(queue.jobs.map(\.state), [.completed, .failed])
    }

    func testDormantRecoveryIsSingleFlightAndPreservesSelectedProject() async throws {
        let selected = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: selected.root) }
        let dormant = try await makeFixture(root: selected.root)
        let resolved = try NarrationSettingsResolver.resolve(
            item: dormant.first.settings, project: ProjectNarrationSettings(), hasPro: false
        )
        let key = try ReadAloudSynthesisContract.generationKey(item: dormant.first, resolved: resolved)
        let now = Date()
        let job = GenerationJobRecord(
            id: UUID(), projectID: dormant.projectID, itemID: dormant.first.id,
            operation: .generate, generationKey: key, state: .generating,
            createdAt: now, updatedAt: now, attempt: 3, lastError: nil
        )
        try await selected.store.saveQueue(projectID: dormant.projectID, queue: ProjectQueueDocument(jobs: [job]))
        try await Self.checkDormantRecovery(store: selected.store, selectedID: selected.projectID, dormantID: dormant.projectID)
        let queue = try await selected.store.loadQueue(projectID: dormant.projectID)
        XCTAssertEqual(queue.jobs.count, 1)
        XCTAssertEqual(queue.jobs.first?.id, job.id)
        XCTAssertEqual(queue.jobs.first?.state, .queued)
        XCTAssertEqual(queue.jobs.first?.attempt, 3)
    }

    @MainActor private static func checkDormantRecovery(
        store: ProjectStore, selectedID: UUID, dormantID: UUID
    ) async throws {
        let preferenceKey = ReadAloudPreferences.Key.backgroundPrefetchPaused
        let previous = UserDefaults.standard.object(forKey: preferenceKey)
        UserDefaults.standard.set(true, forKey: preferenceKey)
        defer { UserDefaults.standard.set(previous, forKey: preferenceKey) }
        let manager = ProjectRuntimeManager(store: store)
        defer { manager.shutdownAll() }
        let selected = try await manager.activate(projectID: selectedID)
        let first = Task { await manager.recoverPendingGeneration() }
        let second = Task { await manager.recoverPendingGeneration() }
        await first.value
        await second.value
        let dormant = try XCTUnwrap(manager.runtimeIfLoaded(projectID: dormantID))
        XCTAssertTrue(manager.activeRuntime === selected)
        XCTAssertFalse(dormant.queueController.hasGlobalAdmission)
        await manager.recoverPendingGeneration()
        XCTAssertTrue(manager.runtimeIfLoaded(projectID: dormantID) === dormant)
        XCTAssertTrue(manager.activeRuntime === selected)
        // A paused/preparing session owns hero/mini-player selection even
        // when another project remains the reader selection.
        dormant.playerItemID = dormant.itemStates.first?.id
        dormant.activity.activeItemID = dormant.playerItemID
        dormant.activity.playbackState = .paused
        manager.claimPlayback(dormant)
        XCTAssertTrue(manager.playerRuntime === dormant)
        UserDefaults.standard.set(false, forKey: preferenceKey)
        dormant.queueController.reconcileScheduling()
        XCTAssertEqual(selected.queueController.schedulingStatus, "Waiting for listening")
        XCTAssertFalse(dormant.queueController.hasGlobalAdmission)
        UserDefaults.standard.set(true, forKey: preferenceKey)
        dormant.activity.playbackState = .loading
        XCTAssertTrue(manager.playerRuntime === dormant)
        XCTAssertFalse(dormant.itemStates.contains { $0.generationStatus.state == .readyOffline })
        dormant.activity.playbackState = .idle
        dormant.playerItemID = nil
        dormant.activity.activeItemID = nil
        await dormant.shutdownAndDrain()
        await selected.shutdownAndDrain()
    }

    func testOfflineAdmissionRevocationDrainsUncooperativeWork() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await Self.checkAdmissionDrain(store: fixture.store, projectID: fixture.projectID)
    }

    @MainActor private final class GenerationDrainGate {
        let entered = XCTestExpectation(description: "Offline operation entered")
        var continuation: CheckedContinuation<Void, Never>?
        var drained = false
        func run() async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                entered.fulfill()
            }
        }
        func release() { continuation?.resume(); continuation = nil }
    }

    @MainActor private static func checkAdmissionDrain(store: ProjectStore, projectID: UUID) async throws {
        let key = ReadAloudPreferences.Key.backgroundPrefetchPaused
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        let manager = ProjectRuntimeManager(store: store)
        defer { manager.shutdownAll() }
        let runtime = try await manager.activate(projectID: projectID)
        let controller = runtime.queueController
        let gate = GenerationDrainGate()
        await ProjectGenerationExecutionRegistry.shared.drainForPlayback()
        controller.setGlobalAdmission(true)
        let operation = Task { try await controller.executeGeneration { await gate.run() } }
        defer { operation.cancel(); gate.release() }
        let entered = await XCTWaiter.fulfillment(of: [gate.entered], timeout: 2)
        guard entered == .completed else {
            operation.cancel(); gate.release()
            _ = await operation.result
            await runtime.shutdownAndDrain()
            XCTFail("Offline operation did not enter")
            return
        }
        controller.setGlobalAdmission(false)
        let drainStarted = XCTestExpectation(description: "Drain started")
        let drain = Task {
            drainStarted.fulfill()
            await controller.cancelAndDrain()
            gate.drained = true
        }
        _ = await XCTWaiter.fulfillment(of: [drainStarted], timeout: 2)
        XCTAssertFalse(gate.drained)
        do {
            try await controller.executeGeneration { XCTFail("Revoked queue admitted another operation") }
            XCTFail("Revoked queue must throw cancellation")
        } catch is CancellationError { }
        gate.release()
        await drain.value
        XCTAssertTrue(gate.drained)
        do { try await operation.value; XCTFail("Cancelled work completed as success") }
        catch is CancellationError { }
        await runtime.shutdownAndDrain()
    }

    func testLatePauseCannotUndoCompletedOfflineIntent() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let now = Date()
        let job = GenerationJobRecord(
            id: UUID(), projectID: fixture.projectID, itemID: fixture.first.id,
            operation: .generate, generationKey: ProjectDigest.sha256("final"), state: .completed,
            createdAt: now, updatedAt: now, attempt: 1, lastError: nil
        )
        try await fixture.store.saveQueue(projectID: fixture.projectID, queue: ProjectQueueDocument(jobs: [job]))
        let lateStates: [GenerationJobState] = [.queued, .generating, .failed]
        for state in lateStates {
            let queue = try await fixture.store.updateGenerationJob(
                projectID: fixture.projectID, jobID: job.id, state: state,
                incrementAttempt: true, errorMessage: "Late executor event"
            )
            XCTAssertEqual(queue.jobs, [job])
        }
    }

    private actor ChunkUseGate {
        private var entered = false
        private var released = false
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiter: CheckedContinuation<Void, Never>?
        func hold() async {
            entered = true
            let waiters = entryWaiters
            entryWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            if !released { await withCheckedContinuation { releaseWaiter = $0 } }
        }
        func waitUntilEntered() async {
            if !entered { await withCheckedContinuation { entryWaiters.append($0) } }
        }
        func release() {
            released = true
            releaseWaiter?.resume()
            releaseWaiter = nil
        }
    }

    private enum ReclamationTestError: Error { case schedulingTimeout, cleanupFailed }

    private func waitForCacheBoundary(
        _ cache: SharedChunkAudioCache,
        condition: @Sendable (Int, Int, Int) -> Bool
    ) async throws {
        for _ in 0..<10_000 {
            let producers = await cache.activeProducerCount
            let pending = await cache.pendingReclamationCount
            let suspensions = await cache.activeSuspensionCount
            if condition(producers, pending, suspensions) { return }
            await Task.yield()
        }
        XCTFail("Cache did not reach the expected race boundary")
        throw ReclamationTestError.schedulingTimeout
    }

    private struct ReclamationFixture: Sendable {
        let project: Fixture
        let cache: SharedChunkAudioCache
        let chunks: [ChunkAudioRequest]
        let request: ProjectGenerationStatusRequest
        let metadata: GeneratedAudioMetadata
        let finalBytes: Data

        func reclaim() async throws -> Int {
            try await project.store.reclaimFinalizedChunks(
                projectID: project.projectID, request: request,
                expectedAudioRevision: metadata.audioRevision, chunks: chunks
            )
        }
        func schedule() async {
            await cache.requestReclamation(itemID: request.itemID, audioRevision: metadata.audioRevision) {
                _ = try await self.reclaim()
            }
        }
    }

    private static func chunkRequests(
        item: ProjectContentItem, resolved: ResolvedNarrationSettings,
        generationKey: String, runtimeRevision: String
    ) -> [ChunkAudioRequest] {
        SpeechChunkScheduler().chunks(for: item.text, speed: Float(resolved.speed))
            .enumerated().map { index, chunk in
                ChunkAudioRequest(
                    itemID: item.id, index: index, chunk: chunk,
                    generationKey: generationKey, resolved: resolved,
                    runtimeRevision: runtimeRevision,
                    synthesisConfigVersion: ReadAloudNarrationCatalog.synthesisConfigVersion
                )
            }
    }

    private func makeReclamationFixture(commitFinal: Bool = true) async throws -> ReclamationFixture {
        let project = try await makeFixture()
        let cache = SharedChunkAudioCache(packageURL: project.paths.packageURL)
        let resolved = ResolvedNarrationSettings(voiceID: "af_heart", speed: 1)
        let revision = try ReadAloudSynthesisContract.runtimeRevision()
        let key = try ReadAloudSynthesisContract.generationKey(item: project.first, resolved: resolved, runtimeRevision: revision)
        let chunks = Self.chunkRequests(item: project.first, resolved: resolved, generationKey: key, runtimeRevision: revision)
        let audio = KokoroAudio(samples: Array(repeating: 0.25, count: 240), sampleRate: 24_000)
        for chunk in chunks { _ = try await cache.audio(for: chunk) { audio } }
        let bytes = try ProjectWAVCodec.encode(samples: Array(repeating: 0.25, count: 240 * chunks.count), sampleRate: 24_000)
        let metadata = GeneratedAudioMetadata(
            itemID: project.first.id, generationKey: key, audioRevision: ProjectDigest.sha256(bytes),
            contentRevision: project.first.contentRevision, voiceID: resolved.voiceID, speed: resolved.speed,
            runtimeRevision: ReadAloudSynthesisContract.generationRuntimeRevision(
                base: revision, pronunciationMode: ReadAloudPreferences.pronunciationFallbackMode
            ),
            synthesisConfigVersion: ReadAloudNarrationCatalog.synthesisConfigVersion,
            durationSeconds: Double(chunks.count) * 0.01,
            segments: chunks.enumerated().map { index, chunk in
                AudioSegmentMetadata(sourceRange: chunk.chunk.sourceRange,
                    startSeconds: Double(index) * 0.01, endSeconds: Double(index + 1) * 0.01)
            }
        )
        if commitFinal {
            let wav = project.paths.tempDirectory.appending(path: "cleanup-fixture.wav")
            try bytes.write(to: wav)
            try await project.store.commitGeneratedAudio(projectID: project.projectID, wavURL: wav, metadata: metadata)
        }
        return ReclamationFixture(
            project: project, cache: cache, chunks: chunks,
            request: ProjectGenerationStatusRequest(itemID: project.first.id, generationKey: key,
                contentRevision: project.first.contentRevision, voiceID: resolved.voiceID, speed: resolved.speed),
            metadata: metadata, finalBytes: bytes
        )
    }

    private func seedRetryQueue(_ fixture: Fixture) async throws -> [GenerationJobRecord] {
        let now = Date()
        let jobs = [GenerationJobState.failed, .queued, .generating, .completed].map { state in
            GenerationJobRecord(
                id: UUID(), projectID: fixture.projectID, itemID: fixture.first.id,
                operation: .generate, generationKey: ProjectDigest.sha256("old retry key"), state: state,
                createdAt: now, updatedAt: now, attempt: 3,
                lastError: state == .failed ? "Original failure" : nil
            )
        } + [GenerationJobRecord(
            id: UUID(), projectID: fixture.projectID, itemID: fixture.second.id,
            operation: .generate, generationKey: ProjectDigest.sha256("unrelated job"), state: .queued,
            createdAt: now, updatedAt: now, attempt: 1, lastError: nil
        )]
        try await fixture.store.saveQueue(projectID: fixture.projectID, queue: ProjectQueueDocument(jobs: jobs))
        return jobs
    }

    func testRetryAtomicallyReplacesPendingJobsAndPreservesHistoryAndOtherChapters() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = try await seedRetryQueue(fixture)
        let key = ProjectDigest.sha256("replacement key")
        let bridge = ProjectRuntimePersistenceBridge(projectID: fixture.projectID, store: fixture.store)
        try await bridge.retryGeneration([ProjectGenerationRequest(itemID: fixture.first.id, generationKey: key)])
        let reopened = try ProjectStore(rootURL: fixture.root)
        let queue = try await reopened.loadQueue(projectID: fixture.projectID)
        let retained = original.filter { $0.itemID != fixture.first.id || $0.state == .completed }
        XCTAssertEqual(Array(queue.jobs.prefix(retained.count)), retained)
        XCTAssertEqual(queue.jobs.count, retained.count + 1)
        let replacement = try XCTUnwrap(queue.jobs.last)
        XCTAssertFalse(original.contains { $0.id == replacement.id })
        XCTAssertEqual(replacement.itemID, fixture.first.id)
        XCTAssertEqual(replacement.generationKey, key)
        XCTAssertEqual(replacement.state, .queued)
        XCTAssertEqual(replacement.attempt, 0)
        XCTAssertNil(replacement.lastError)
    }

    func testInvalidRetryBatchLeavesOriginalQueueBytesUntouched() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await seedRetryQueue(fixture)
        let before = try Data(contentsOf: fixture.paths.queueJobs)
        let valid = ProjectGenerationRequest(itemID: fixture.first.id, generationKey: ProjectDigest.sha256("new key"))
        let batches = [
            [valid, ProjectGenerationRequest(itemID: fixture.second.id, generationKey: "invalid")],
            [valid, ProjectGenerationRequest(itemID: UUID(), generationKey: valid.generationKey)],
            [valid, valid]
        ]
        for requests in batches {
            do {
                try await fixture.store.retryGeneration(projectID: fixture.projectID, requests: requests)
                XCTFail("Invalid batch must not replace any original requests")
            } catch is ProjectStoreError { }
            XCTAssertEqual(try Data(contentsOf: fixture.paths.queueJobs), before)
        }
        try await fixture.store.retryGeneration(projectID: fixture.projectID, requests: [])
        XCTAssertEqual(try Data(contentsOf: fixture.paths.queueJobs), before)
    }

    func testRetryWriteFailurePreservesOriginalDurableIntent() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = try await seedRetryQueue(fixture)
        let before = try Data(contentsOf: fixture.paths.queueJobs)
        // Block staging without changing the existing, readable queue file.
        try FileManager.default.removeItem(at: fixture.paths.tempDirectory)
        try Data("not a directory".utf8).write(to: fixture.paths.tempDirectory)
        do {
            try await fixture.store.retryGeneration(projectID: fixture.projectID, requests: [
                ProjectGenerationRequest(itemID: fixture.first.id, generationKey: ProjectDigest.sha256("new key"))
            ])
            XCTFail("Retry must fail when atomic queue staging is unavailable")
        } catch is ProjectStoreError { }
        XCTAssertEqual(try Data(contentsOf: fixture.paths.queueJobs), before)
        let queue = try await fixture.store.loadQueue(projectID: fixture.projectID)
        XCTAssertEqual(queue.jobs, original)
    }

    func testCancelledRetryPreservesOriginalQueue() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await seedRetryQueue(fixture)
        let before = try Data(contentsOf: fixture.paths.queueJobs)
        let request = ProjectGenerationRequest(itemID: fixture.first.id, generationKey: ProjectDigest.sha256("new key"))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await fixture.store.retryGeneration(projectID: fixture.projectID, requests: [request])
        }
        do { try await task.value; XCTFail("Cancelled retry must not commit") }
        catch is CancellationError { }
        XCTAssertEqual(try Data(contentsOf: fixture.paths.queueJobs), before)
    }

    func testNarrationEditsPreserveEquivalentWorkAndInvalidateOnlyRealChanges() async throws {
        let fixture = try await makeReclamationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.project.root) }
        await fixture.cache.shutdown()
        try await Self.checkNarrationEdits(fixture)
    }

    @MainActor private static func checkNarrationEdits(_ fixture: ReclamationFixture) async throws {
        let preferenceKey = ReadAloudPreferences.Key.backgroundPrefetchPaused
        let previous = UserDefaults.standard.object(forKey: preferenceKey)
        UserDefaults.standard.set(true, forKey: preferenceKey)
        defer { UserDefaults.standard.set(previous, forKey: preferenceKey) }
        let project = fixture.project
        _ = try await project.store.updateSettings(
            projectID: project.projectID, settings: ProjectNarrationSettings(voiceID: "af_heart", speed: 1)
        )
        let runtime = ProjectRuntime(
            id: project.projectID, packageURL: project.paths.packageURL,
            persistence: ProjectRuntimePersistenceBridge(projectID: project.projectID, store: project.store),
            hasPro: { true }
        )
        defer { runtime.shutdown() }
        // Refresh without configuring an executor: these are durable-state
        // tests and must never start inference or recover away seeded states.
        try await runtime.refresh()
        let itemID = fixture.request.itemID
        let initialKey = try XCTUnwrap(runtime.itemState(itemID)).generationKey
        let other = try XCTUnwrap(runtime.itemState(project.second.id))
        let now = Date()
        func jobs(for key: String) -> [GenerationJobRecord] {
            let pending = [GenerationJobState.queued, .generating, .failed, .completed].map { state in
                GenerationJobRecord(
                    id: UUID(), projectID: project.projectID, itemID: itemID,
                    operation: .generate, generationKey: key, state: state,
                    createdAt: now, updatedAt: now, attempt: 2,
                    lastError: state == .failed ? "Retry me" : nil
                )
            }
            return pending + [GenerationJobRecord(
                id: UUID(), projectID: project.projectID, itemID: other.id,
                operation: .generate, generationKey: other.generationKey, state: .queued,
                createdAt: now, updatedAt: now, attempt: 0, lastError: nil
            )]
        }
        let originalJobs = jobs(for: initialKey)
        try await project.store.saveQueue(projectID: project.projectID, queue: ProjectQueueDocument(jobs: originalJobs))
        let equivalentEdits: [@MainActor () async throws -> Void] = [
            { try await runtime.updateItemVoiceMode(itemID: itemID, mode: .custom) },
            { try await runtime.updateItemVoiceMode(itemID: itemID, mode: .inherit) },
            { try await runtime.updateItemVoice(itemID: itemID, voiceID: "af_heart") },
            { try await runtime.updateItemVoice(itemID: itemID, voiceID: "af_heart") },
            { try await runtime.updateItemVoiceMode(itemID: itemID, mode: .inherit) },
            { try await runtime.updateItemSpeedMode(itemID: itemID, mode: .custom) },
            { try await runtime.updateItemSpeedMode(itemID: itemID, mode: .inherit) },
            { try await runtime.updateItemSpeed(itemID: itemID, speed: 1) },
            { try await runtime.updateItemSpeed(itemID: itemID, speed: 1) },
            { try await runtime.updateItemSpeedMode(itemID: itemID, mode: .inherit) }
        ]
        for edit in equivalentEdits {
            try await edit()
            let queue = try await project.store.loadQueue(projectID: project.projectID)
            XCTAssertEqual(queue.jobs, originalJobs, "Equivalent edits must preserve IDs, states, attempts and errors")
            XCTAssertEqual(runtime.itemState(itemID)?.generationKey, initialKey)
            XCTAssertEqual(runtime.itemState(itemID)?.generationStatus.state, .readyOffline)
            XCTAssertEqual(try Data(contentsOf: project.paths.audioWAV(itemID)), fixture.finalBytes)
        }
        let saved = try await project.store.loadContentItem(projectID: project.projectID, itemID: itemID)
        XCTAssertEqual(saved.settings.voice.mode, .inherit)
        XCTAssertEqual(saved.settings.voice.customValue, "af_heart")
        XCTAssertEqual(saved.settings.speed.mode, .inherit)
        XCTAssertEqual(saved.settings.speed.customValue, 1)
        let chunk = try await runtime.chunkCache.load(fixture.chunks[0])
        XCTAssertNotNil(chunk)

        let newVoice = try XCTUnwrap(SpeechVoice.all.first { $0.id != "af_heart" })
        let changedEdits: [@MainActor () async throws -> Void] = [
            { try await runtime.updateItemVoice(itemID: itemID, voiceID: newVoice.id) },
            { try await runtime.updateItemVoiceMode(itemID: itemID, mode: .inherit) },
            { try await runtime.updateItemSpeed(itemID: itemID, speed: 1.1) },
            { try await runtime.updateItemSpeedMode(itemID: itemID, mode: .inherit) }
        ]
        for edit in changedEdits {
            let oldKey = try XCTUnwrap(runtime.itemState(itemID)).generationKey
            let seeded = jobs(for: oldKey)
            try await project.store.saveQueue(projectID: project.projectID, queue: ProjectQueueDocument(jobs: seeded))
            try await edit()
            let queue = try await project.store.loadQueue(projectID: project.projectID)
            XCTAssertEqual(queue.jobs, seeded.filter { $0.itemID != itemID || $0.state == .completed })
            XCTAssertNotEqual(runtime.itemState(itemID)?.generationKey, oldKey)
        }
        await runtime.shutdownAndDrain()
    }

    private func writeAudioRecoveryJournal(
        in directory: URL, itemID: UUID, phase: String,
        hadPrevious: Bool = true
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "itemID": itemID.uuidString,
            "hadWAV": hadPrevious, "hadMetadata": hadPrevious, "phase": phase
        ])
        try data.write(to: directory.appending(path: "transaction.json"), options: .atomic)
    }

    private func replacementAudio(
        for fixture: ReclamationFixture
    ) throws -> (Data, GeneratedAudioMetadata) {
        let bytes = try ProjectWAVCodec.encode(
            samples: Array(repeating: 0.7, count: 240 * fixture.chunks.count), sampleRate: 24_000
        )
        let original = fixture.metadata
        return (bytes, GeneratedAudioMetadata(
            itemID: original.itemID, generationKey: original.generationKey,
            audioRevision: ProjectDigest.sha256(bytes), contentRevision: original.contentRevision,
            voiceID: original.voiceID, speed: original.speed, runtimeRevision: original.runtimeRevision,
            synthesisConfigVersion: original.synthesisConfigVersion,
            durationSeconds: original.durationSeconds, segments: original.segments
        ))
    }

    func testAudioCommitReopenRecoversEveryReplacementBoundary() async throws {
        // Recreate the durable state left by a process kill at each boundary;
        // use a fresh store, not a catchable-error rollback on the old instance.
        for stage in ["preparing", "before-swap", "wav-only", "both-files", "mid-rollback", "finished", "cleanup"] {
            let fixture = try await makeReclamationFixture()
            defer { try? FileManager.default.removeItem(at: fixture.project.root) }
            await fixture.cache.shutdown()
            let paths = fixture.project.paths
            let itemID = fixture.request.itemID
            let oldMetadata = try Data(contentsOf: paths.audioMetadata(itemID))
            let (bytes, metadata) = try replacementAudio(for: fixture)
            let directory = paths.tempDirectory.appending(path: "audio-commit-\(UUID().uuidString)")
            let phase = stage == "preparing" ? "preparing" : (stage == "finished" || stage == "cleanup" ? "finished" : "replacing")
            try writeAudioRecoveryJournal(in: directory, itemID: itemID, phase: phase)
            // Preparing may have only a partial backup; final files are still old.
            try fixture.finalBytes.write(to: directory.appending(path: "previous.wav"))
            if stage != "preparing" {
                try oldMetadata.write(to: directory.appending(path: "previous.metadata.json"))
            }
            if ["wav-only", "both-files", "finished", "cleanup"].contains(stage) {
                try bytes.write(to: paths.audioWAV(itemID), options: .atomic)
            }
            if ["both-files", "mid-rollback", "finished", "cleanup"].contains(stage) {
                try ProjectJSONCodec.encode(metadata).write(to: paths.audioMetadata(itemID), options: .atomic)
            }
            if stage == "finished" {
                // A completed transaction must not require its backups again.
                try FileManager.default.removeItem(at: directory.appending(path: "previous.wav"))
            }
            if stage == "cleanup" {
                let cleanup = paths.tempDirectory.appending(path: "audio-cleanup-\(UUID().uuidString)")
                try FileManager.default.moveItem(at: directory, to: cleanup)
                try FileManager.default.removeItem(at: cleanup.appending(path: "transaction.json"))
            }
            let keepsNew = stage == "finished" || stage == "cleanup"
            for _ in 0..<2 {
                let reopened = try ProjectStore(rootURL: fixture.project.root)
                let asset = try await reopened.loadCompatibleFinalAudio(
                    projectID: fixture.project.projectID, request: fixture.request
                )
                XCTAssertEqual(asset?.metadata, keepsNew ? metadata : fixture.metadata, stage)
                XCTAssertEqual(try Data(contentsOf: paths.audioWAV(itemID)), keepsNew ? bytes : fixture.finalBytes, stage)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), stage)
        }
    }

    func testInterruptedFirstAudioCommitRemovesOnlyUncommittedPair() async throws {
        for wroteMetadata in [false, true] {
            let fixture = try await makeReclamationFixture(commitFinal: false)
            defer { try? FileManager.default.removeItem(at: fixture.project.root) }
            await fixture.cache.shutdown()
            let paths = fixture.project.paths
            let itemID = fixture.request.itemID
            let directory = paths.tempDirectory.appending(path: "audio-commit-\(UUID().uuidString)")
            try writeAudioRecoveryJournal(in: directory, itemID: itemID, phase: "replacing", hadPrevious: false)
            try fixture.finalBytes.write(to: paths.audioWAV(itemID))
            if wroteMetadata {
                try ProjectJSONCodec.encode(fixture.metadata).write(to: paths.audioMetadata(itemID))
            }
            let reopened = try ProjectStore(rootURL: fixture.project.root)
            let asset = try await reopened.loadCompatibleFinalAudio(
                projectID: fixture.project.projectID, request: fixture.request
            )
            XCTAssertNil(asset)
            XCTAssertFalse(FileManager.default.fileExists(atPath: paths.audioWAV(itemID).path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: paths.audioMetadata(itemID).path))
            let cache = SharedChunkAudioCache(packageURL: paths.packageURL)
            let chunk = try await cache.load(fixture.chunks[0])
            XCTAssertNotNil(chunk, "Recovery must preserve chunks for retry")
            await cache.shutdown()
        }
    }

    func testFailedAudioRecoveryRetainsBackupsForAnotherAttempt() async throws {
        let fixture = try await makeReclamationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.project.root) }
        await fixture.cache.shutdown()
        let paths = fixture.project.paths
        let itemID = fixture.request.itemID
        let oldMetadata = try Data(contentsOf: paths.audioMetadata(itemID))
        let (bytes, metadata) = try replacementAudio(for: fixture)
        let directory = paths.tempDirectory.appending(path: "audio-commit-\(UUID().uuidString)")
        try writeAudioRecoveryJournal(in: directory, itemID: itemID, phase: "replacing")
        let backupWAV = directory.appending(path: "previous.wav")
        try fixture.finalBytes.write(to: backupWAV)
        try bytes.write(to: paths.audioWAV(itemID), options: .atomic)
        try ProjectJSONCodec.encode(metadata).write(to: paths.audioMetadata(itemID), options: .atomic)
        XCTAssertThrowsError(try ProjectStore(rootURL: fixture.project.root))
        XCTAssertEqual(try Data(contentsOf: backupWAV), fixture.finalBytes)
        XCTAssertEqual(try Data(contentsOf: paths.audioWAV(itemID)), bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appending(path: "transaction.json").path))

        try oldMetadata.write(to: directory.appending(path: "previous.metadata.json"))
        // Simulate a second interruption after restoring just the first file.
        try fixture.finalBytes.write(to: paths.audioWAV(itemID), options: .atomic)
        let reopened = try ProjectStore(rootURL: fixture.project.root)
        let asset = try await reopened.loadCompatibleFinalAudio(
            projectID: fixture.project.projectID, request: fixture.request
        )
        XCTAssertEqual(asset?.metadata, fixture.metadata)
        XCTAssertEqual(try Data(contentsOf: paths.audioWAV(itemID)), fixture.finalBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testReclamationDefersForBothCachedReaderAndAssembler() async throws {
        let fixture = try await makeReclamationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.project.root) }
        let readerGate = ChunkUseGate()
        let assemblerGate = ChunkUseGate()
        defer { Task { await readerGate.release(); await assemblerGate.release() } }
        let reader = Task {
            try await fixture.cache.withUsage(itemID: fixture.request.itemID) {
                let cached = try await fixture.cache.load(fixture.chunks[0])
                await readerGate.hold()
                return cached?.samples.count
            }
        }
        await readerGate.waitUntilEntered()
        let assembler = Task {
            try await fixture.cache.withUsage(itemID: fixture.request.itemID) {
                await assemblerGate.hold()
            }
        }
        await assemblerGate.waitUntilEntered()
        await fixture.schedule()
        let pending = await fixture.cache.pendingReclamationCount
        XCTAssertEqual(pending, 1)
        await readerGate.release()
        let count = try await reader.value
        XCTAssertEqual(count, 240)
        let retained = try await fixture.cache.load(fixture.chunks[0])
        XCTAssertNotNil(retained)
        await assemblerGate.release()
        try await assembler.value
        await fixture.cache.waitForReclamation(itemID: fixture.request.itemID)
        let removed = try await fixture.cache.load(fixture.chunks[0])
        XCTAssertNil(removed)
        let asset = try await fixture.project.store.loadCompatibleFinalAudio(projectID: fixture.project.projectID, request: fixture.request)
        XCTAssertEqual(asset?.metadata, fixture.metadata)
        await fixture.cache.shutdown()
    }

    func testNewReaderWaitsForReclamationAndCannotLoseItsReplacementChunks() async throws {
        let fixture = try await makeReclamationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.project.root) }
        let gate = ChunkUseGate()
        defer { Task { await gate.release() } }
        await fixture.cache.requestReclamation(itemID: fixture.request.itemID, audioRevision: fixture.metadata.audioRevision) {
            await gate.hold()
            _ = try await fixture.reclaim()
        }
        await gate.waitUntilEntered()
        let replacement = KokoroAudio(samples: Array(repeating: 0.5, count: 240), sampleRate: 24_000)
        let reader = Task {
            try await fixture.cache.withUsage(itemID: fixture.request.itemID) {
                try await fixture.cache.audio(for: fixture.chunks[0]) { replacement }
            }
        }
        await gate.release()
        let received = try await reader.value
        XCTAssertEqual(received.samples, replacement.samples)
        let cached = try await fixture.cache.load(fixture.chunks[0])
        XCTAssertEqual(cached?.samples.count, replacement.samples.count)
        XCTAssertEqual(cached?.samples.first ?? 0, 0.5, accuracy: 0.001)
        await fixture.cache.shutdown()
    }

    func testReclamationPreservesIncompleteGenerationWithoutFinalAudio() async throws {
        let fixture = try await makeReclamationFixture(commitFinal: false)
        defer { try? FileManager.default.removeItem(at: fixture.project.root) }
        await fixture.schedule()
        await fixture.cache.waitForReclamation(itemID: fixture.request.itemID)
        let cached = try await fixture.cache.load(fixture.chunks[0])
        XCTAssertNotNil(cached)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.project.paths.audioWAV(fixture.request.itemID).path))
        await fixture.cache.shutdown()
    }

    func testReclamationRequiresCurrentValidFinalPairAndExpectedRevision() async throws {
        let fixture = try await makeReclamationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.project.root) }
        let wav = fixture.project.paths.audioWAV(fixture.request.itemID)
        let json = fixture.project.paths.audioMetadata(fixture.request.itemID)
        try Data("corrupt audio".utf8).write(to: wav)
        let corrupt = try await fixture.reclaim()
        XCTAssertEqual(corrupt, 0)
        try fixture.finalBytes.write(to: wav)
        try FileManager.default.removeItem(at: json)
        let missingMetadata = try await fixture.reclaim()
        XCTAssertEqual(missingMetadata, 0)
        try await fixture.project.store.saveAudioMetadata(projectID: fixture.project.projectID, metadata: fixture.metadata)
        let replaced = try await fixture.project.store.reclaimFinalizedChunks(
            projectID: fixture.project.projectID, request: fixture.request,
            expectedAudioRevision: ProjectDigest.sha256("different final audio"), chunks: fixture.chunks
        )
        XCTAssertEqual(replaced, 0)
        let stale = ProjectGenerationStatusRequest(itemID: fixture.request.itemID,
            generationKey: ProjectDigest.sha256("new settings"), contentRevision: fixture.request.contentRevision,
            voiceID: fixture.request.voiceID, speed: fixture.request.speed)
        let changed = try await fixture.project.store.reclaimFinalizedChunks(
            projectID: fixture.project.projectID, request: stale,
            expectedAudioRevision: fixture.metadata.audioRevision, chunks: fixture.chunks
        )
        XCTAssertEqual(changed, 0)
        let cached = try await fixture.cache.load(fixture.chunks[0])
        XCTAssertNotNil(cached)
        await fixture.cache.shutdown()
    }

    func testReclamationIsExactAndPreservesSourceBookmarkAndOtherGenerations() async throws {
        let fixture = try await makeReclamationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.project.root) }
        let before = try await fixture.project.store.loadProject(projectID: fixture.project.projectID)
        let original = fixture.chunks[0]
        let otherGeneration = ChunkAudioRequest(itemID: original.itemID, index: original.index, chunk: original.chunk,
            generationKey: ProjectDigest.sha256("another generation"), resolved: original.resolved,
            runtimeRevision: original.runtimeRevision, synthesisConfigVersion: original.synthesisConfigVersion)
        let otherChapter = Self.chunkRequests(item: fixture.project.second, resolved: original.resolved,
            generationKey: ProjectDigest.sha256("another chapter"), runtimeRevision: original.runtimeRevision)[0]
        let audio = KokoroAudio(samples: Array(repeating: 0.25, count: 240), sampleRate: 24_000)
        for request in [otherGeneration, otherChapter] { _ = try await fixture.cache.audio(for: request) { audio } }
        await fixture.schedule()
        await fixture.cache.waitForReclamation(itemID: fixture.request.itemID)
        let removed = try await fixture.cache.load(original)
        XCTAssertNil(removed)
        for request in [otherGeneration, otherChapter] {
            let preserved = try await fixture.cache.load(request)
            XCTAssertNotNil(preserved)
        }
        let after = try await fixture.project.store.loadProject(projectID: fixture.project.projectID)
        XCTAssertEqual(after.project.playback, before.project.playback)
        XCTAssertEqual(after.items, before.items)
        XCTAssertEqual(after.project.source, before.project.source)
        let asset = try await fixture.project.store.loadCompatibleFinalAudio(projectID: fixture.project.projectID, request: fixture.request)
        XCTAssertEqual(asset?.metadata, fixture.metadata)
        await fixture.cache.shutdown()
    }

    func testClearDrainsCleanupAndAllowsFreshChunksWithoutLateDeletion() async throws {
        let fixture = try await makeReclamationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.project.root) }
        let gate = ChunkUseGate()
        defer { Task { await gate.release() } }
        await fixture.cache.requestReclamation(itemID: fixture.request.itemID, audioRevision: fixture.metadata.audioRevision) {
            await gate.hold() // Model a cleanup already waiting on its store transaction.
            _ = try await fixture.reclaim()
        }
        await gate.waitUntilEntered()
        let clear = Task { try await fixture.cache.clearAll() }
        try await waitForCacheBoundary(fixture.cache) { _, _, suspensions in suspensions == 1 }
        // Cleanup is still held. Clear must have closed admission and must
        // wait for that reservation before deleting any derived files.
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.cache.directory.appending(path: "\(fixture.chunks[0].cacheKey).wav").path))
        await gate.release()
        try await clear.value
        let missing = try await fixture.cache.load(fixture.chunks[0])
        XCTAssertNil(missing)
        let audio = KokoroAudio(samples: Array(repeating: 0.4, count: 240), sampleRate: 24_000)
        _ = try await fixture.cache.audio(for: fixture.chunks[0]) { audio }
        await fixture.cache.waitForReclamation(itemID: fixture.request.itemID)
        let fresh = try await fixture.cache.load(fixture.chunks[0])
        XCTAssertNotNil(fresh)
        let asset = try await fixture.project.store.loadCompatibleFinalAudio(projectID: fixture.project.projectID, request: fixture.request)
        XCTAssertEqual(asset?.metadata, fixture.metadata)
        await fixture.cache.shutdown()
    }

    func testCancelledNativeProducerStillDefersReclamationUntilItDrains() async throws {
        let fixture = try await makeReclamationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.project.root) }
        let old = fixture.chunks[0]
        let request = ChunkAudioRequest(itemID: old.itemID, index: old.index, chunk: old.chunk,
            generationKey: ProjectDigest.sha256("incomplete replacement"), resolved: old.resolved,
            runtimeRevision: old.runtimeRevision, synthesisConfigVersion: old.synthesisConfigVersion)
        let gate = ChunkUseGate()
        defer { Task { await gate.release() } }
        let audio = KokoroAudio(samples: Array(repeating: 0.5, count: 240), sampleRate: 24_000)
        let consumer = Task {
            try await fixture.cache.audio(for: request) {
                await gate.hold() // Deliberately ignore cancellation, like native session.run().
                return audio
            }
        }
        await gate.waitUntilEntered()
        await fixture.schedule()
        consumer.cancel()
        do { _ = try await consumer.value; XCTFail("Cancelled consumer received audio") }
        catch is CancellationError { }
        let pending = await fixture.cache.pendingReclamationCount
        XCTAssertEqual(pending, 1)
        let retained = try await fixture.cache.load(old)
        XCTAssertNotNil(retained)
        await gate.release()
        try await waitForCacheBoundary(fixture.cache) { producers, pending, _ in producers == 0 && pending == 0 }
        await fixture.cache.waitForReclamation(itemID: old.itemID)
        let removed = try await fixture.cache.load(old)
        let cancelled = try await fixture.cache.load(request)
        XCTAssertNil(removed)
        XCTAssertNil(cancelled)
        await fixture.cache.shutdown()
    }

    func testDeferredReclamationRevalidatesAfterFinalAudioReplacement() async throws {
        let fixture = try await makeReclamationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.project.root) }
        let gate = ChunkUseGate()
        defer { Task { await gate.release() } }
        let reader = Task {
            try await fixture.cache.withUsage(itemID: fixture.request.itemID) { await gate.hold() }
        }
        await gate.waitUntilEntered()
        await fixture.schedule()
        let bytes = try ProjectWAVCodec.encode(samples: Array(repeating: 0.7, count: 240 * fixture.chunks.count), sampleRate: 24_000)
        let wav = fixture.project.paths.tempDirectory.appending(path: "replacement-final.wav")
        try bytes.write(to: wav)
        let original = fixture.metadata
        let replacement = GeneratedAudioMetadata(
            itemID: original.itemID, generationKey: original.generationKey,
            audioRevision: ProjectDigest.sha256(bytes), contentRevision: original.contentRevision,
            voiceID: original.voiceID, speed: original.speed, runtimeRevision: original.runtimeRevision,
            synthesisConfigVersion: original.synthesisConfigVersion,
            durationSeconds: original.durationSeconds, segments: original.segments
        )
        try await fixture.project.store.commitGeneratedAudio(projectID: fixture.project.projectID, wavURL: wav, metadata: replacement)
        await gate.release()
        try await reader.value
        await fixture.cache.waitForReclamation(itemID: fixture.request.itemID)
        let retained = try await fixture.cache.load(fixture.chunks[0])
        XCTAssertNotNil(retained)
        let asset = try await fixture.project.store.loadCompatibleFinalAudio(projectID: fixture.project.projectID, request: fixture.request)
        XCTAssertEqual(asset?.metadata, replacement)
        await fixture.cache.shutdown()
    }

    func testInvalidationAndShutdownDiscardDeferredCleanup() async throws {
        let fixture = try await makeReclamationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.project.root) }
        let gate = ChunkUseGate()
        defer { Task { await gate.release() } }
        let reader = Task {
            try await fixture.cache.withUsage(itemID: fixture.request.itemID) { await gate.hold() }
        }
        await gate.waitUntilEntered()
        await fixture.schedule()
        let token = await fixture.cache.suspendAndDrain(itemIDs: [fixture.request.itemID])
        let pending = await fixture.cache.pendingReclamationCount
        XCTAssertEqual(pending, 0)
        await fixture.cache.resumeAdmission(token)
        // Requeue while the reader still holds its usage; shutdown must also
        // discard this request, rather than deleting chunks after release.
        await fixture.schedule()
        await fixture.cache.shutdown()
        await gate.release()
        try await reader.value
        let reopened = SharedChunkAudioCache(packageURL: fixture.project.paths.packageURL)
        let preserved = try await reopened.load(fixture.chunks[0])
        XCTAssertNotNil(preserved)
        await reopened.shutdown()
    }

    func testFailedHousekeepingDoesNotPoisonSubsequentCachedPlayback() async throws {
        let fixture = try await makeReclamationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.project.root) }
        await fixture.cache.requestReclamation(itemID: fixture.request.itemID, audioRevision: fixture.metadata.audioRevision) {
            throw ReclamationTestError.cleanupFailed
        }
        await fixture.cache.waitForReclamation(itemID: fixture.request.itemID)
        let audio = try await fixture.cache.withUsage(itemID: fixture.request.itemID) {
            try await fixture.cache.load(fixture.chunks[0])
        }
        XCTAssertNotNil(audio)
        await fixture.cache.shutdown()
    }

    func testFinalMetadataMatchesGenerationIdentityForEveryPronunciationMode() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let base = try ReadAloudSynthesisContract.runtimeRevision()
        let resolved = ResolvedNarrationSettings(voiceID: "af_heart", speed: 1)
        for mode in PronunciationFallbackMode.allCases {
            let key = try ReadAloudSynthesisContract.generationKey(
                item: fixture.first, resolved: resolved, runtimeRevision: base, pronunciationMode: mode
            )
            let legacyKey = try ProjectGenerationKey.make(GenerationKeyInput(
                contentRevision: fixture.first.contentRevision, resolvedVoiceID: resolved.voiceID,
                canonicalSpeed: resolved.speed, kokoroRuntimeRevision: base + "-g2p-" + mode.rawValue,
                synthesisConfigVersion: ReadAloudNarrationCatalog.synthesisConfigVersion
            ))
            XCTAssertEqual(key, legacyKey)
            let metadata = GeneratedAudioMetadata(
                itemID: fixture.first.id, generationKey: key, audioRevision: ProjectDigest.sha256("test PCM"),
                contentRevision: fixture.first.contentRevision, voiceID: resolved.voiceID, speed: resolved.speed,
                runtimeRevision: ReadAloudSynthesisContract.generationRuntimeRevision(base: base, pronunciationMode: mode),
                synthesisConfigVersion: ReadAloudNarrationCatalog.synthesisConfigVersion,
                durationSeconds: 0.01,
                segments: [AudioSegmentMetadata(sourceRange: AudioSourceRange(startUTF16: 0, endUTF16: fixture.first.text.utf16.count), startSeconds: 0, endSeconds: 0.01)]
            )
            XCTAssertNoThrow(try ProjectValidation.validate(metadata))
        }
    }

    func testRuntimeFinalizationRetainsPartialChunksThenReclaimsAfterLastReader() async throws {
        let fixture = try await makeFixture(firstText: String(repeating: "A spoken sentence about a journey through the forest. ", count: 4))
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await Self.checkFinalizationAndCleanup(fixture)
    }

    @MainActor private static func checkFinalizationAndCleanup(_ fixture: Fixture) async throws {
        let modeKey = ReadAloudPreferences.Key.pronunciationFallbackMode
        let oldMode = UserDefaults.standard.object(forKey: modeKey)
        defer { UserDefaults.standard.set(oldMode, forKey: modeKey) }
        let preferenceKey = ReadAloudPreferences.Key.backgroundPrefetchPaused
        let previous = UserDefaults.standard.object(forKey: preferenceKey)
        UserDefaults.standard.set(true, forKey: preferenceKey)
        defer { UserDefaults.standard.set(previous, forKey: preferenceKey) }
        let manager = ProjectRuntimeManager(store: fixture.store)
        defer { manager.shutdownAll() }
        let runtime = try await manager.activate(projectID: fixture.projectID)
        let state = try XCTUnwrap(runtime.itemState(fixture.first.id))
        let revision = try ReadAloudSynthesisContract.runtimeRevision()
        let requests = chunkRequests(item: state.item, resolved: state.resolved,
            generationKey: state.generationKey, runtimeRevision: revision)
        XCTAssertGreaterThan(requests.count, 1)
        let audio = KokoroAudio(samples: Array(repeating: 0.25, count: 240), sampleRate: 24_000)
        for request in requests.dropLast() { _ = try await runtime.chunkCache.audio(for: request) { audio } }
        let paragraphs = runtime.cachedReaderParagraphs(for: state.item)
        let partial = try await runtime.finalizeItemIfComplete(itemState: state, paragraphs: paragraphs, runtimeRevision: revision)
        XCTAssertFalse(partial)
        let preserved = try await runtime.chunkCache.load(requests[0])
        XCTAssertNotNil(preserved)
        let before = try await fixture.store.loadProject(projectID: fixture.projectID)
        let last = try XCTUnwrap(requests.last)
        _ = try await runtime.chunkCache.audio(for: last) { audio }
        let gate = ChunkUseGate()
        defer { Task { await gate.release() } }
        let reader = Task {
            try await runtime.chunkCache.withUsage(itemID: state.id) { await gate.hold() }
        }
        await gate.waitUntilEntered()
        let complete = try await runtime.finalizeItemIfComplete(itemState: state, paragraphs: paragraphs, runtimeRevision: revision)
        XCTAssertTrue(complete)
        let stillUsed = try await runtime.chunkCache.load(requests[0])
        XCTAssertNotNil(stillUsed)
        await gate.release()
        try await reader.value
        await runtime.chunkCache.waitForReclamation(itemID: state.id)
        let ranges = await runtime.chunkCache.cachedSourceRanges(for: requests)
        XCTAssertTrue(ranges.isEmpty)
        try await runtime.refreshGenerationState()
        XCTAssertEqual(runtime.itemState(state.id)?.generationStatus.state, .readyOffline)
        let buffered = await runtime.playerBufferedRanges(for: state.id)
        XCTAssertEqual(buffered, [PlayerBufferedRange(start: 0, end: 1)])
        let asset = try await fixture.store.loadCompatibleFinalAudio(projectID: fixture.projectID,
            request: ProjectGenerationStatusRequest(itemID: state.id, generationKey: state.generationKey,
                contentRevision: state.item.contentRevision, voiceID: state.resolved.voiceID, speed: state.resolved.speed))
        XCTAssertEqual(asset?.metadata.segments.count, requests.count)
        let after = try await fixture.store.loadProject(projectID: fixture.projectID)
        XCTAssertEqual(after.project.playback, before.project.playback)
        XCTAssertEqual(after.items, before.items)
        // A policy change must invalidate a paused session even though its
        // resolved voice and speed are unchanged. Old final audio stays intact.
        runtime.playerItemID = state.id
        runtime.activity.activeItemID = state.id
        runtime.activity.playbackState = .paused
        let nextMode = try XCTUnwrap(PronunciationFallbackMode.allCases.first { $0 != state.pronunciationMode })
        UserDefaults.standard.set(nextMode.rawValue, forKey: modeKey)
        await runtime.refreshForExternalPreferencesChange()
        XCTAssertNil(runtime.activity.activeItemID)
        XCTAssertEqual(runtime.itemState(state.id)?.pronunciationMode, nextMode)
        XCTAssertNotEqual(runtime.itemState(state.id)?.generationKey, state.generationKey)
        XCTAssertNotEqual(runtime.itemState(state.id)?.generationStatus.state, .readyOffline)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.paths.audioWAV(state.id).path))
        await runtime.shutdownAndDrain()
    }

    func testBackgroundWithoutListeningRevokesGenerationAndPreservesIntent() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await Self.checkBackgroundAdmission(fixture)
    }

    @MainActor private static func checkBackgroundAdmission(_ fixture: Fixture) async throws {
        let registry = ProjectGenerationExecutionRegistry.shared
        let wasActive = registry.isApplicationActive
        let preferenceKey = ReadAloudPreferences.Key.backgroundPrefetchPaused
        let previous = UserDefaults.standard.object(forKey: preferenceKey)
        UserDefaults.standard.set(true, forKey: preferenceKey)
        let manager = ProjectRuntimeManager(store: fixture.store)
        defer {
            manager.shutdownAll()
            registry.setApplicationActive(wasActive)
            UserDefaults.standard.set(previous, forKey: preferenceKey)
        }
        manager.setApplicationActive(true)
        let runtime = try await manager.activate(projectID: fixture.projectID)
        await registry.drainForPlayback()
        let controller = runtime.queueController
        let gate = GenerationDrainGate()
        controller.setGlobalAdmission(true)
        let operation = Task { try await controller.executeGeneration { await gate.run() } }
        defer { operation.cancel(); gate.release() }
        let entered = await XCTWaiter.fulfillment(of: [gate.entered], timeout: 2)
        guard entered == .completed else { operation.cancel(); gate.release(); XCTFail("Generation did not enter"); return }
        manager.setApplicationActive(false)
        XCTAssertFalse(controller.hasGlobalAdmission)
        XCTAssertFalse(registry.canPerformGeneration)
        XCTAssertEqual(controller.schedulingStatus, "Paused while not listening in background")
        XCTAssertTrue(ReadAloudPreferences.backgroundPrefetchPaused)
        gate.release()
        do { try await operation.value; XCTFail("Background generation should cancel") }
        catch is CancellationError { }
        await controller.cancelAndDrain()
        let state = try XCTUnwrap(runtime.itemState(fixture.first.id))
        try await fixture.store.enqueueGeneration(projectID: fixture.projectID,
            requests: [ProjectGenerationRequest(itemID: state.id, generationKey: state.generationKey)], replaceExisting: false)
        try await runtime.refreshGenerationState()
        let before = try await fixture.store.loadQueue(projectID: fixture.projectID)
        runtime.activity.activeItemID = state.id
        let listeningStates: [ProjectRuntimePlaybackState] = [.loading, .buffering, .playing]
        for playback in listeningStates {
            runtime.activity.playbackState = playback
            controller.reconcileScheduling()
            XCTAssertTrue(registry.canPerformGeneration)
        }
        runtime.activity.playbackState = .paused
        controller.reconcileScheduling()
        XCTAssertFalse(registry.canPerformGeneration)
        runtime.activity.playbackState = .idle
        runtime.activity.activeItemID = nil
        manager.setApplicationActive(true)
        XCTAssertTrue(registry.canPerformGeneration)
        XCTAssertTrue(ReadAloudPreferences.backgroundPrefetchPaused)
        let after = try await fixture.store.loadQueue(projectID: fixture.projectID)
        XCTAssertEqual(after, before)
        await runtime.shutdownAndDrain()
    }

    func testInactiveCleanupWaitsForActivityAndIgnoresStalePolicyUpdates() async throws {
        let fixture = try await makeReclamationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.project.root) }
        await fixture.cache.setReclamationAllowed(false, revision: 2)
        await fixture.schedule()
        let pending = await fixture.cache.pendingReclamationCount
        XCTAssertEqual(pending, 1)
        await fixture.cache.setReclamationAllowed(true, revision: 1)
        let cached = try await fixture.cache.load(fixture.chunks[0])
        XCTAssertNotNil(cached)
        await fixture.cache.setReclamationAllowed(true, revision: 3)
        await fixture.cache.waitForReclamation(itemID: fixture.request.itemID)
        let removed = try await fixture.cache.load(fixture.chunks[0])
        XCTAssertNil(removed)
        await fixture.cache.shutdown()
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



final class GenerationAdmissionAndHeroTests: XCTestCase {
    private func candidate(
        _ id: UUID, age: Double?, eligible: Bool = true, playback: Bool = false
    ) -> GenerationAdmissionCandidate {
        GenerationAdmissionCandidate(
            projectID: id, oldestJob: age.map { Date(timeIntervalSince1970: $0) },
            isEligible: eligible, requiresPlaybackPriority: playback
        )
    }

    func testActivityPolicyAllowsForegroundWorkAndRequiresListeningInBackground() {
        XCTAssertTrue(GenerationActivityPolicy.allowsWork(isApplicationActive: true, hasListeningIntent: false))
        XCTAssertTrue(GenerationActivityPolicy.allowsWork(isApplicationActive: true, hasListeningIntent: true))
        XCTAssertTrue(GenerationActivityPolicy.allowsWork(isApplicationActive: false, hasListeningIntent: true))
        XCTAssertFalse(GenerationActivityPolicy.allowsWork(isApplicationActive: false, hasListeningIntent: false))
    }

    func testGlobalAdmissionSelectsOldestEligibleProjectAndStableTie() {
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let blocked = UUID()
        let input = [candidate(second, age: 20), candidate(blocked, age: 1, eligible: false), candidate(first, age: 10)]
        XCTAssertEqual(GenerationAdmissionPolicy.nextProject(candidates: input, paused: false), first)
        XCTAssertEqual(GenerationAdmissionPolicy.nextProject(candidates: [candidate(second, age: 10), candidate(first, age: 10)], paused: false), first)
        // No intent (including cancellation/completion) must release the slot.
        XCTAssertEqual(GenerationAdmissionPolicy.nextProject(candidates: [candidate(first, age: nil), candidate(second, age: 20)], paused: false), second)
    }

    func testPlaybackInAnotherProjectRevokesOfflineAdmission() {
        let queued = candidate(UUID(), age: 1)
        let live = candidate(UUID(), age: nil, playback: true)
        XCTAssertNil(GenerationAdmissionPolicy.nextProject(candidates: [queued, live], paused: false))
        XCTAssertNil(GenerationAdmissionPolicy.nextProject(candidates: [queued], paused: true))
        // Compatible file playback with generate-while-listening enabled has
        // no speech-model claim, so unrelated durable work can proceed.
        let file = candidate(live.projectID, age: nil, playback: false)
        XCTAssertEqual(GenerationAdmissionPolicy.nextProject(candidates: [queued, file], paused: false), queued.projectID)
    }

    func testMemoryOrInvalidationBlockDoesNotAdmitThatProject() {
        let suspended = candidate(UUID(), age: 1, eligible: false)
        XCTAssertNil(GenerationAdmissionPolicy.nextProject(candidates: [suspended], paused: false))
        let explicitRetry = candidate(suspended.projectID, age: 1)
        XCTAssertEqual(GenerationAdmissionPolicy.nextProject(candidates: [explicitRetry], paused: false), suspended.projectID)
    }

    func testHeroActionsFollowPlaybackIncludingPausedPreparationAndFailure() {
        let playing = ListeningHeroPresentation(state: .playing, active: true, paused: false, preparing: false, hasHistory: true)
        XCTAssertEqual(playing.action, .pause)
        XCTAssertEqual(playing.heading, "NOW LISTENING")
        let paused = ListeningHeroPresentation(state: .paused, active: true, paused: true, preparing: false, hasHistory: true)
        XCTAssertEqual(paused.action, .resume)
        XCTAssertEqual(paused.heading, "CONTINUE LISTENING")
        let preparingStates: [ProjectRuntimePlaybackState] = [.loading, .warmingUp, .buffering, .synthesizing(current: 1, total: 2)]
        for state in preparingStates {
            let preparing = ListeningHeroPresentation(state: state, active: true, paused: false, preparing: true, hasHistory: false)
            XCTAssertEqual(preparing.action, .cancel)
        }
        let failed = ListeningHeroPresentation(state: .failed("Speech failed"), active: false, paused: false, preparing: false, hasHistory: true)
        XCTAssertEqual(failed.action, .retry)
        XCTAssertEqual(failed.error, "Audio couldn’t play. Try again.")
    }

    func testHeroStartsOrContinuesWithoutCreatingAnotherPlaybackOwner() {
        let start = ListeningHeroPresentation(state: nil, active: false, paused: false, preparing: false, hasHistory: false)
        XCTAssertEqual(start.action, .start)
        XCTAssertEqual(start.heading, "READY TO LISTEN")
        let resume = ListeningHeroPresentation(state: .idle, active: false, paused: false, preparing: false, hasHistory: true)
        XCTAssertEqual(resume.action, .continueListening)
        XCTAssertNil(resume.error)
    }
}


// Adapter integration lives here so the owner-managed Xcode project keeps the
// same registered test sources. HTML is based on TextExtractor 1.2.0's original
// article-structured fixture; no networking or package-internal APIs are used.
final class WebArticleImportIntegrationTests: XCTestCase {
    private let finalURL = URL(string: "https://example.com/final/field-journal")!

    private var html: Data {
        Data("""
        <!doctype html>
        <html lang="en">
        <head><meta charset="utf-8"><title>Keep a Field Journal | Trail Letter</title>
        <meta property="og:site_name" content="Trail Letter">
        <meta name="author" content="Morgan Chen">
        <meta property="article:published_time" content="2026-04-20T10:00:00Z"></head>
        <body>
        <nav>All stories | Subscribe | About</nav>
        <article>
          <header><h1>Keep a Field Journal</h1><p class="byline">By Morgan Chen</p></header>
          <p>A field journal is a record of observations, not a test of drawing skill. A small notebook allows you to notice changes in light, plant growth, and weather patterns over weeks rather than minutes.</p>
          <h2>Start with three observations</h2>
          <p>Begin each visit by writing the date and location. Then record what you can see, hear, and smell before reaching for a camera or a guidebook.</p>
          <ul>
            <li><p>Notice the light and shadows.</p></li>
            <li><p>Listen for a repeated bird call.</p><p>Note where it comes from.</p></li>
            <li>Compare one leaf with your earlier notes.</li>
          </ul>
          <blockquote><p>Careful attention turns an ordinary path into a place you can recognize.</p></blockquote>
          <figure><img src="journal.jpg" alt="A notebook on a rock"><figcaption>A simple notebook beside the path.</figcaption></figure>
          <h2>An optional data format</h2>
          <p>People who keep digital copies sometimes use plain text so notes remain searchable. A small structure is often enough to make entries easy to revisit.</p>
          <pre><code>date: 2026-04-20
        place: north trail
        weather: cloudy</code></pre>
          <table>
            <thead><tr><th>Time</th><th>Observation</th></tr></thead>
            <tbody><tr><td>Morning</td><td>Cool breeze</td></tr><tr><td>Afternoon</td><td>Warm sunlight</td></tr></tbody>
          </table>
          <p>Record only what you observed and revisit the same location later. Patterns become easier to spot when the journal stays simple.</p>
        </article>
        <footer><a href="/archive">Older posts</a></footer>
        </body>
        </html>
        """.utf8)
    }

    func testTypedArticleMapsMetadataFinalURLAndOrderedSpeechBlocks() throws {
        let extracted = try WebArticleImportAdapter().importDocument(
            data: html, finalURL: finalURL, progress: nil
        )
        XCTAssertEqual(extracted.document.kind, .article)
        XCTAssertEqual(extracted.document.title, "Keep a Field Journal")
        XCTAssertEqual(extracted.document.author, "Morgan Chen")
        XCTAssertEqual(extracted.siteName, "Trail Letter")
        XCTAssertEqual(extracted.language, "en")
        XCTAssertEqual(extracted.publishedTime, "2026-04-20T10:00:00Z")
        let item = try XCTUnwrap(extracted.document.items.first)
        XCTAssertEqual(extracted.document.items.count, 1)
        XCTAssertEqual(item.sourceLocator.kind, .article)
        XCTAssertEqual(item.sourceLocator.value, finalURL.absoluteString)
        let blocks = item.normalizedText.components(separatedBy: "\n\n")
        guard blocks.count == 14 else {
            XCTFail("Expected 14 ordered article blocks, got \(blocks.count)")
            return
        }
        XCTAssertEqual(blocks[0], "Keep a Field Journal")
        XCTAssertEqual(blocks[4], "Notice the light and shadows.")
        XCTAssertEqual(blocks[5], "Listen for a repeated bird call. Note where it comes from.")
        XCTAssertEqual(blocks[7], "Careful attention turns an ordinary path into a place you can recognize.")
        XCTAssertEqual(blocks[11], "date: 2026-04-20\nplace: north trail\nweather: cloudy")
        // ReadAloud's existing speech normalization uses spaces for cell tabs.
        XCTAssertEqual(blocks[12], "Time Observation\nMorning Cool breeze\nAfternoon Warm sunlight")
        XCTAssertFalse(item.normalizedText.contains("Older posts"))
        XCTAssertFalse(item.normalizedText.contains("By Morgan Chen"))
        let content = try ReadAloudContentNormalizer.makeContent(from: extracted.document.items)
        XCTAssertEqual(content.items.first?.text, item.normalizedText)
        guard case .article(let cached)? = extracted.document.parsedOutput else {
            return XCTFail("Article import must retain typed parser output")
        }
        XCTAssertEqual(cached.sourceURL, finalURL)
        XCTAssertEqual(cached.blocks.count, 14)
        XCTAssertEqual(cached.blocks[0].kind, .heading(level: 1))
        XCTAssertEqual(cached.blocks[11].kind, .code)
        XCTAssertEqual(cached.blocks[12].kind, .table)
    }

    func testPackageFailuresKeepAppImportErrors() {
        let adapter = WebArticleImportAdapter()
        XCTAssertThrowsError(try adapter.importDocument(
            data: Data(repeating: 0x20, count: ArticleURLLoader.maxHTMLBytes + 1),
            finalURL: finalURL, progress: nil
        )) { error in
            guard let failure = error as? ArticleURLError, case .tooLarge = failure else {
                XCTFail("Expected the app's size error, got \(error)"); return
            }
        }
        XCTAssertThrowsError(try adapter.importDocument(
            data: Data([0]), finalURL: finalURL, progress: nil
        )) { error in
            guard let failure = error as? ArticleURLError, case .unreadableEncoding = failure else {
                XCTFail("Expected the app's encoding error, got \(error)"); return
            }
        }
        XCTAssertThrowsError(try adapter.importDocument(
            data: Data(), finalURL: finalURL, progress: nil
        )) { error in
            guard let failure = error as? ArticleURLError, case .unreadableArticle = failure else {
                XCTFail("Expected the app's article error, got \(error)"); return
            }
        }
        XCTAssertThrowsError(try adapter.importDocument(
            data: html, finalURL: URL(fileURLWithPath: "/article.html"), progress: nil
        )) { error in
            guard let failure = error as? ArticleURLError, case .invalidURL = failure else {
                XCTFail("Expected the app's URL error, got \(error)"); return
            }
        }
    }

    private actor ImportGate {
        private var started = false
        private var startWaiter: CheckedContinuation<Void, Never>?
        private var releaseWaiter: CheckedContinuation<Void, Never>?
        func hold() async {
            await withCheckedContinuation { continuation in
                releaseWaiter = continuation
                started = true
                startWaiter?.resume()
                startWaiter = nil
            }
        }
        func waitUntilStarted() async {
            if started { return }
            await withCheckedContinuation { startWaiter = $0 }
        }
        func release() { releaseWaiter?.resume(); releaseWaiter = nil }
    }

    func testCancelledImportDoesNotBecomeUnreadableArticle() async throws {
        let gate = ImportGate()
        let data = html
        let url = finalURL
        let worker = Task.detached {
            await gate.hold()
            return try WebArticleImportAdapter().importDocument(
                data: data, finalURL: url, progress: nil
            )
        }
        await gate.waitUntilStarted()
        worker.cancel()
        await gate.release()
        do { _ = try await worker.value; XCTFail("Cancelled import must unwind") }
        catch is CancellationError { }
    }
}


@MainActor
final class WeeklyListeningAllowanceTests: XCTestCase {
    private let wednesday = Date(timeIntervalSince1970: 1_791_979_200)

    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "readaloud-listening-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    func testUsageSurvivesRelaunchAndProDoesNotConsumeOrEraseIt() {
        withDefaults { defaults in
            let allowance = ReadAloudListeningAllowance(defaults: defaults, now: wednesday)
            allowance.record(seconds: 120, isPro: false, now: wednesday)
            allowance.record(seconds: 600, isPro: true, now: wednesday)
            allowance.record(seconds: 30, isPro: false, now: wednesday)
            allowance.persist(now: wednesday)
            let reloaded = ReadAloudListeningAllowance(defaults: defaults, now: wednesday)
            XCTAssertEqual(reloaded.usedSeconds(at: wednesday), 150)
            XCTAssertFalse(reloaded.isExhausted(at: wednesday))
        }
    }

    func testExhaustionCapsAtAllowanceAndWeekRolloverRestoresPlayback() {
        withDefaults { defaults in
            let allowance = ReadAloudListeningAllowance(defaults: defaults, now: wednesday)
            allowance.record(seconds: 20_000, isPro: false, now: wednesday)
            XCTAssertTrue(allowance.isExhausted(at: wednesday))
            XCTAssertEqual(allowance.usedSeconds(at: wednesday),
                           ReadAloudAccessPolicy.weeklyListeningSeconds)
            let reset = allowance.resetDate(at: wednesday)
            XCTAssertEqual(allowance.usedSeconds(at: reset), 0)
            XCTAssertFalse(allowance.isExhausted(at: reset))
            allowance.refresh(now: reset)
            XCTAssertEqual(allowance.usedSeconds(at: reset), 0)
        }
    }

    func testBoundarySampleChargesOnlyNewWeekPortion() {
        withDefaults { defaults in
            let allowance = ReadAloudListeningAllowance(defaults: defaults, now: wednesday)
            let reset = allowance.resetDate(at: wednesday)
            allowance.record(seconds: 4, isPro: false, now: reset.addingTimeInterval(1))
            XCTAssertEqual(allowance.usedSeconds(at: reset.addingTimeInterval(1)), 1)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            XCTAssertEqual(calendar.component(.weekday, from: reset), 2)
            XCTAssertEqual(calendar.component(.hour, from: reset), 0)
        }
    }

    func testMovingClockBackDoesNotReplenishUsage() {
        withDefaults { defaults in
            let allowance = ReadAloudListeningAllowance(defaults: defaults, now: wednesday)
            allowance.record(seconds: 120, isPro: false, now: wednesday)
            let earlier = wednesday.addingTimeInterval(-7 * 24 * 3600)
            allowance.refresh(now: earlier)
            allowance.record(seconds: 30, isPro: false, now: earlier)
            XCTAssertEqual(allowance.usedSeconds(at: earlier), 150)
            XCTAssertEqual(allowance.resetDate(at: earlier), allowance.resetDate(at: wednesday))
        }
    }

    func testInvalidSamplesDoNotCorruptLedger() {
        withDefaults { defaults in
            let allowance = ReadAloudListeningAllowance(defaults: defaults, now: wednesday)
            for sample in [Double.nan, .infinity, -1, 0] {
                allowance.record(seconds: sample, isPro: false, now: wednesday)
            }
            XCTAssertEqual(allowance.usedSeconds(at: wednesday), 0)
        }
    }

    func testDamagedLedgerDoesNotSilentlyGrantAnotherAllowance() {
        withDefaults { defaults in
            defaults.set(Data("invalid".utf8), forKey: "readaloud.listening-allowance.v1")
            let allowance = ReadAloudListeningAllowance(defaults: defaults, now: wednesday)
            XCTAssertTrue(allowance.isExhausted(at: wednesday))
        }
    }

    func testRenderedMeterExcludesGapsAndDoesNotCountSamplesTwice() {
        var meter = SpeechRenderedUsage()
        let first = UUID(), second = UUID()
        meter.schedule(first, duration: 2, at: 0)
        XCTAssertEqual(meter.consume(at: 1), 1)
        XCTAssertEqual(meter.consume(at: 1), 0)
        XCTAssertEqual(meter.consume(at: 5, completing: first), 1)
        meter.remove(first)
        meter.schedule(second, duration: 3, at: 10)
        XCTAssertEqual(meter.consume(at: 10), 0)
        XCTAssertEqual(meter.consume(at: 11), 1)
        XCTAssertEqual(meter.consume(at: 20, completing: second), 2)
    }

    func testRenderedMeterBillsReplayButNotSavedFileSeekOffset() {
        var meter = SpeechRenderedUsage()
        let first = UUID(), next = UUID()
        // File seek offsets are deliberately not supplied to this node meter.
        meter.schedule(first, duration: 10, at: 0)
        XCTAssertEqual(meter.consume(at: 2), 2)
        meter = SpeechRenderedUsage() // stop/seek resets the node timeline
        meter.schedule(next, duration: 10, at: 0)
        XCTAssertEqual(meter.consume(at: 1), 1)
    }
}

