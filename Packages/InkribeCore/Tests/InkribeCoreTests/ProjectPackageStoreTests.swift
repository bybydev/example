import Foundation
import Testing
@testable import InkribeCore

// Regression specifications for the storage boundary. These do not run native
// inference or media frameworks; execution remains subject to repository rules.
private struct PackageFixtureDocument: ProjectPackageDocument, Equatable {
    static let supportedPackageDocumentSchema = 7
    var id = UUID()
    var schemaVersion = 7
    var contentRevision: UInt64 = 12
    var title = "Corrected captions"
    var relativePath = "Originals/retained.mov"
    var sourceByteCount: Int64 = 8
    var editedText = "Tiếng Việt — corrected 👋"
    var retainedTiming = ["value": 7_501, "timescale": 600]

    var packageIdentity: ProjectPackageIdentity {
        .init(id: id, schemaVersion: schemaVersion, revision: contentRevision)
    }
    var packageSources: [ProjectPackageSource] {
        [.init(relativePath: relativePath, byteCount: sourceByteCount)]
    }
    func validatePackageDocument() throws {
        guard (1...Self.supportedPackageDocumentSchema).contains(schemaVersion), contentRevision > 0 else {
            throw ProjectStoreError.invalidDocument("Invalid fixture header")
        }
    }
}

private struct PackageFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var store: ProjectPackageStore<PackageFixtureDocument> { .init(rootURL: root) }
    let source = Data("original".utf8)
    let checkpoint = Data("{\"jobID\":\"retained\",\"mappingVersion\":2,\"attempts\":1}".utf8)

    func cleanup() { try? FileManager.default.removeItem(at: root) }
    func encode<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder().encode(value) }

    func legacy(_ document: PackageFixtureDocument, location: ProjectPackageLocation = .projects) throws -> URL {
        let package = try store.directory(location.rawValue).appendingPathComponent(document.id.uuidString)
        try FileManager.default.createDirectory(at: package.appendingPathComponent("Originals"), withIntermediateDirectories: true)
        try source.write(to: package.appendingPathComponent("Originals/retained.mov"))
        try encode(document).write(to: package.appendingPathComponent("document.json"))
        try checkpoint.write(to: package.appendingPathComponent("speech-checkpoint.json"))
        return package
    }
}

@Suite struct ProjectPackageStoreTests {
    @Test func directProjectSaveDoesNotRequireOrCreateAnEditorSidecar() throws {
        let fixture = PackageFixture()
        defer { fixture.cleanup() }
        let value = PackageFixtureDocument()
        let staging = try fixture.store.directory("Pending").appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("Originals"), withIntermediateDirectories: true)
        try fixture.source.write(to: staging.appendingPathComponent(value.relativePath))
        let package = try fixture.store.commitNew(value, stagedAt: staging)
        let sidecar = package.appendingPathComponent(ProjectPackageLayout.recoveryDraftName)
        var next = value
        next.contentRevision += 1
        next.title = "My project"
        try fixture.store.save(next, replacing: value)
        #expect(try fixture.store.load(value.id) == next)
        #expect(!FileManager.default.fileExists(atPath: sidecar.path))

        // An unrelated leftover file cannot become a second project authority.
        let unrelated = Data("not project data".utf8)
        try unrelated.write(to: sidecar)
        var latest = next
        latest.contentRevision += 1
        latest.editedText = "Latest caption edit"
        try fixture.store.save(latest, replacing: next)
        #expect(try fixture.store.load(value.id) == latest)
        #expect(try Data(contentsOf: sidecar) == unrelated)
        #expect(try Data(contentsOf: package.appendingPathComponent(value.relativePath)) == fixture.source)
    }

    @Test func failedDirectSavePreservesTheLastSavedProject() throws {
        let fixture = PackageFixture()
        defer { fixture.cleanup() }
        let value = PackageFixtureDocument()
        _ = try fixture.legacy(value)
        let package = try fixture.store.packageURL(for: value.id)
        let saved = try Data(contentsOf: package.appendingPathComponent("document.json"))
        try FileManager.default.removeItem(at: package.appendingPathComponent(value.relativePath))
        var next = value
        next.contentRevision += 1
        next.title = "Unsaved change"
        #expect(throws: ProjectStoreError.self) { try fixture.store.save(next, replacing: value) }
        #expect(try Data(contentsOf: package.appendingPathComponent("document.json")) == saved)
        #expect(try fixture.store.load(value.id) == value)
    }

    @Test(arguments: [1, 2, 3, 4, 5, 6, 7])
    func migrationPreservesExactDocumentMediaAndCheckpointBytes(schema: Int) throws {
        let fixture = PackageFixture()
        defer { fixture.cleanup() }
        var value = PackageFixtureDocument()
        value.schemaVersion = schema
        let legacy = try fixture.legacy(value)
        let documentBytes = try Data(contentsOf: legacy.appendingPathComponent("document.json"))

        #expect(try fixture.store.load(value.id) == value)
        let package = try fixture.store.packageURL(for: value.id)
        #expect(package.pathExtension == "inkribe")
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(try Data(contentsOf: package.appendingPathComponent("document.json")) == documentBytes)
        #expect(try Data(contentsOf: package.appendingPathComponent(value.relativePath)) == fixture.source)
        #expect(try Data(contentsOf: package.appendingPathComponent("speech-checkpoint.json")) == fixture.checkpoint)
        #expect(try fixture.store.load(value.id) == value) // Re-entry is idempotent.
        #expect(try fixture.store.identities() == [value.id])
    }

    @Test func interruptedMarkerPublicationResumesWithoutRewritingContent() throws {
        let fixture = PackageFixture()
        defer { fixture.cleanup() }
        let value = PackageFixtureDocument()
        let legacy = try fixture.legacy(value)
        let marker = try fixture.encode(ProjectPackageManifest(projectID: value.id))
        try marker.write(to: legacy.appendingPathComponent("package.json"))
        #expect(try fixture.store.load(value.id) == value)
        let package = try fixture.store.packageURL(for: value.id)
        #expect(try Data(contentsOf: package.appendingPathComponent("package.json")) == marker)
    }

    @Test func newImportPublishesOneCompletePackageAndRejectsMissingSources() throws {
        let fixture = PackageFixture()
        defer { fixture.cleanup() }
        let value = PackageFixtureDocument()
        let staging = try fixture.store.directory("Pending").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("Originals"), withIntermediateDirectories: true)
        #expect(throws: ProjectStoreError.self) { try fixture.store.commitNew(value, stagedAt: staging) }
        #expect(try !fixture.store.contains(value.id, in: .projects))
        try fixture.source.write(to: staging.appendingPathComponent(value.relativePath))
        let package = try fixture.store.commitNew(value, stagedAt: staging)
        #expect(package.pathExtension == "inkribe")
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(try fixture.store.load(value.id) == value)
    }

    @Test func mixedCaseDuplicatePackageIsNotHiddenByCanonicalName() throws {
        let fixture = PackageFixture()
        defer { fixture.cleanup() }
        let value = PackageFixtureDocument()
        _ = try fixture.legacy(value)
        _ = try fixture.store.load(value.id)
        let duplicate = try fixture.store.directory("Projects")
            .appendingPathComponent(value.id.uuidString + ".INKRIBE")
        // On a case-insensitive volume this aliases the existing package and
        // cannot represent a duplicate; collision behavior is exercised above.
        guard !FileManager.default.fileExists(atPath: duplicate.path) else { return }
        try FileManager.default.createDirectory(at: duplicate, withIntermediateDirectories: false)
        #expect(throws: ProjectStoreError.self) { try fixture.store.load(value.id) }
        #expect(FileManager.default.fileExists(atPath: duplicate.path))
    }

    @Test func destinationCollisionPreservesBothDirectories() throws {
        let fixture = PackageFixture()
        defer { fixture.cleanup() }
        let value = PackageFixtureDocument()
        let legacy = try fixture.legacy(value)
        let destination = try fixture.store.destination(for: value.id)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let sentinel = destination.appendingPathComponent("keep.txt")
        try Data("do not overwrite".utf8).write(to: sentinel)
        #expect(throws: ProjectStoreError.self) { try fixture.store.load(value.id) }
        #expect(FileManager.default.fileExists(atPath: legacy.path))
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "do not overwrite")
        #expect(!FileManager.default.fileExists(atPath: legacy.appendingPathComponent("package.json").path))
    }

    @Test func futureDocumentNeverFallsBackToOlderRecoveryCopy() throws {
        let fixture = PackageFixture()
        defer { fixture.cleanup() }
        var value = PackageFixtureDocument()
        let legacy = try fixture.legacy(value)
        try fixture.encode(value).write(to: legacy.appendingPathComponent("document.previous.json"))
        value.schemaVersion = 8
        let future = try fixture.encode(value)
        try future.write(to: legacy.appendingPathComponent("document.json"))
        do {
            _ = try fixture.store.load(value.id)
            Issue.record("A future document must not be downgraded")
        } catch ProjectStoreError.unsupportedSchema(let version) { #expect(version == 8) }
        #expect(try Data(contentsOf: legacy.appendingPathComponent("document.json")) == future)
        #expect(!FileManager.default.fileExists(atPath: legacy.appendingPathComponent("package.json").path))
    }

    @Test func futurePackageNeverFallsBackToPreviousDocument() throws {
        let fixture = PackageFixture()
        defer { fixture.cleanup() }
        let value = PackageFixtureDocument()
        _ = try fixture.legacy(value)
        let package = try fixture.store.packageURL(for: value.id)
        let future = try JSONSerialization.data(withJSONObject: ["formatVersion": 2, "projectID": value.id.uuidString])
        try future.write(to: package.appendingPathComponent("package.json"))
        do {
            _ = try fixture.store.load(value.id)
            Issue.record("A future wrapper must not be downgraded")
        } catch ProjectStoreError.unsupportedPackageVersion(let version) { #expect(version == 2) }
        #expect(try Data(contentsOf: package.appendingPathComponent("package.json")) == future)
    }

    @Test func oversizedPrimaryIsNotReplacedByAnOlderBackup() throws {
        let fixture = PackageFixture()
        defer { fixture.cleanup() }
        let value = PackageFixtureDocument()
        let legacy = try fixture.legacy(value)
        try fixture.encode(value).write(to: legacy.appendingPathComponent("document.previous.json"))
        let primary = legacy.appendingPathComponent("document.json")
        let handle = try FileHandle(forWritingTo: primary)
        defer { try? handle.close() }
        // Sparse metadata file: exercise the preflight without allocating it.
        try handle.truncate(atOffset: 256 * 1024 * 1024 + 1)
        do {
            _ = try fixture.store.load(value.id)
            Issue.record("An oversized primary must not silently load an older revision")
        } catch ProjectStoreError.oversizedProjectMetadata { }
        #expect(FileManager.default.fileExists(atPath: legacy.path))
        #expect(!FileManager.default.fileExists(atPath: legacy.appendingPathComponent("package.json").path))
    }

    @Test func corruptPrimaryUsesPreviousWithoutDeletingEitherCopy() throws {
        let fixture = PackageFixture()
        defer { fixture.cleanup() }
        let value = PackageFixtureDocument()
        let legacy = try fixture.legacy(value)
        try fixture.encode(value).write(to: legacy.appendingPathComponent("document.previous.json"))
        let corrupt = Data("{incomplete".utf8)
        try corrupt.write(to: legacy.appendingPathComponent("document.json"))
        #expect(try fixture.store.load(value.id) == value)
        let package = try fixture.store.packageURL(for: value.id)
        #expect(try Data(contentsOf: package.appendingPathComponent("document.json")) == corrupt)
        #expect(FileManager.default.fileExists(atPath: package.appendingPathComponent("document.previous.json").path))
    }

    @Test func missingOrDamagedOriginalStillRetainsReadableEditsOnAdoption() throws {
        let fixture = PackageFixture()
        defer { fixture.cleanup() }
        let value = PackageFixtureDocument()
        let legacy = try fixture.legacy(value)
        try Data("bad".utf8).write(to: legacy.appendingPathComponent(value.relativePath))
        #expect(try fixture.store.load(value.id) == value)
        let package = try fixture.store.packageURL(for: value.id)
        try FileManager.default.removeItem(at: package.appendingPathComponent("Originals"))
        #expect(try fixture.store.load(value.id).editedText == value.editedText)
    }

    @Test func saveRejectsStaleRevisionAndRetainsPreviousGoodDocument() throws {
        let fixture = PackageFixture()
        defer { fixture.cleanup() }
        let value = PackageFixtureDocument()
        _ = try fixture.legacy(value)
        var next = value
        next.contentRevision += 1
        next.editedText = "A later correction"
        try fixture.store.save(next, replacing: value)
        #expect(try fixture.store.load(value.id) == next)
        #expect(throws: ProjectStoreError.self) { try fixture.store.save(next, replacing: value) }
        let package = try fixture.store.packageURL(for: value.id)
        let previous = try JSONDecoder().decode(PackageFixtureDocument.self,
            from: Data(contentsOf: package.appendingPathComponent("document.previous.json")))
        #expect(previous == value)
    }

    @Test func sameRevisionExternalChangeDoesNotGetOverwritten() throws {
        let fixture = PackageFixture()
        defer { fixture.cleanup() }
        let value = PackageFixtureDocument()
        _ = try fixture.legacy(value)
        let package = try fixture.store.packageURL(for: value.id)
        var changed = value
        changed.editedText = "External correction"
        try fixture.encode(changed).write(to: package.appendingPathComponent("document.json"))
        var proposed = value
        proposed.contentRevision += 1
        #expect(throws: ProjectStoreError.self) { try fixture.store.save(proposed, replacing: value) }
        #expect(try fixture.store.load(value.id) == changed)
    }

    @Test func movingAndDeletingProjectPreservesFrozenExportHardLink() throws {
        let fixture = PackageFixture()
        defer { fixture.cleanup() }
        let value = PackageFixtureDocument()
        let legacy = try fixture.legacy(value)
        let pinned = try fixture.store.directory("Exports").appendingPathComponent("pinned.mov")
        try FileManager.default.linkItem(at: legacy.appendingPathComponent(value.relativePath), to: pinned)
        try fixture.store.move(value.id, from: .projects, to: .trash)
        #expect(try fixture.store.load(value.id, in: .trash) == value)
        try fixture.store.move(value.id, from: .trash, to: .projects)
        #expect(try fixture.store.load(value.id) == value)
        try fixture.store.move(value.id, from: .projects, to: .trash)
        try fixture.store.removeFromTrash(value.id)
        #expect(try Data(contentsOf: pinned) == fixture.source)
    }

    @Test func staleSaveDoesNotRecreateAMovedPackage() throws {
        let fixture = PackageFixture()
        defer { fixture.cleanup() }
        let value = PackageFixtureDocument()
        _ = try fixture.legacy(value)
        let package = try fixture.store.packageURL(for: value.id)
        let moved = fixture.root.appendingPathComponent("manually-moved.inkribe")
        try FileManager.default.moveItem(at: package, to: moved)
        var proposed = value
        proposed.contentRevision += 1
        #expect(throws: ProjectStoreError.self) { try fixture.store.save(proposed, replacing: value) }
        #expect(!FileManager.default.fileExists(atPath: package.path))
        #expect(try Data(contentsOf: moved.appendingPathComponent(value.relativePath)) == fixture.source)
    }

    @Test func symlinkedProjectAndSourceAreRejected() throws {
        let fixture = PackageFixture()
        defer { fixture.cleanup() }
        let value = PackageFixtureDocument()
        let legacy = try fixture.legacy(value)
        let original = legacy.appendingPathComponent(value.relativePath)
        let outside = fixture.root.appendingPathComponent("outside.mov")
        try fixture.source.write(to: outside)
        try FileManager.default.removeItem(at: original)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: outside)
        #expect(throws: ProjectStoreError.self) { try fixture.store.load(value.id) }
        #expect(try Data(contentsOf: outside) == fixture.source)
        let linkID = UUID()
        let link = try fixture.store.directory("Projects").appendingPathComponent(linkID.uuidString)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: legacy)
        #expect(throws: ProjectStoreError.self) { try fixture.store.load(linkID) }
    }

    @Test func liveStagingIsExcludedAndOnlyValidatedImportsRecover() throws {
        let fixture = PackageFixture()
        defer { fixture.cleanup() }
        let value = PackageFixtureDocument()
        let stagingID = UUID()
        let staging = try fixture.store.directory("Pending").appendingPathComponent(stagingID.uuidString)
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("Originals"), withIntermediateDirectories: true)
        try fixture.source.write(to: staging.appendingPathComponent(value.relativePath))
        try fixture.encode(value).write(to: staging.appendingPathComponent("document.json"))
        #expect(try fixture.store.recoverCommittedStaging(excluding: [stagingID]).isEmpty)
        #expect(try fixture.store.recoverCommittedStaging(excluding: []) == [value.id])
        #expect(try fixture.store.load(value.id) == value)
        #expect(try fixture.store.recoverCommittedStaging(excluding: []).isEmpty)
    }

    @Test func corruptTrashCannotBeRestoredButStaysAvailableForExplicitRemoval() throws {
        let fixture = PackageFixture()
        defer { fixture.cleanup() }
        let value = PackageFixtureDocument()
        let trash = try fixture.legacy(value, location: .trash)
        try Data("broken".utf8).write(to: trash.appendingPathComponent("document.json"))
        #expect(throws: (any Error).self) { try fixture.store.move(value.id, from: .trash, to: .projects) }
        #expect(FileManager.default.fileExists(atPath: trash.path))
        #expect(try fixture.store.identities(in: .trash) == [value.id])
        try fixture.store.removeFromTrash(value.id)
        #expect(try fixture.store.identities(in: .trash).isEmpty)
    }

    @Test func storageClassifiesCheckpointAsDurableAndSourcesSeparately() throws {
        let fixture = PackageFixture()
        defer { fixture.cleanup() }
        let value = PackageFixtureDocument()
        _ = try fixture.legacy(value)
        let usage = try fixture.store.storage(of: value.id)
        #expect(usage.sources == Int64(fixture.source.count))
        #expect(usage.durableData >= Int64(fixture.checkpoint.count))
        #expect(usage.derivedCache == 0)
        #expect(usage.temporaryWork == 0)
        #expect(usage.total == usage.sources + usage.durableData)
    }
}
