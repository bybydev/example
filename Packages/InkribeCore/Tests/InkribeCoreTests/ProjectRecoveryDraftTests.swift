import Foundation
import Testing
@testable import InkribeCore

private struct RecoveryDocument: ProjectPackageDocument, Equatable {
    static let supportedPackageDocumentSchema = 7
    var id = UUID()
    var schema = 7
    var revision: UInt64 = 1
    var title = "Saved project"
    var editedText = "Original captions"
    var packageIdentity: ProjectPackageIdentity { .init(id: id, schemaVersion: schema, revision: revision) }
    var packageSources: [ProjectPackageSource] { [.init(relativePath: "Originals/source.mov", byteCount: 4)] }
    func validatePackageDocument() throws {
        guard schema <= 7, revision > 0, !title.isEmpty else { throw ProjectStoreError.invalidDocument("Invalid fixture") }
    }
}

private struct RecoveryFixture {
    let root: URL
    let store: ProjectPackageStore<RecoveryDocument>
    let document: RecoveryDocument
    let package: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = ProjectPackageStore(rootURL: root)
        document = RecoveryDocument()
        let staging = try store.directory("Pending").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("Originals"), withIntermediateDirectories: true)
        try Data([1, 2, 3, 4]).write(to: staging.appendingPathComponent("Originals/source.mov"))
        package = try store.commitNew(document, stagedAt: staging)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
    var draftURL: URL { package.appendingPathComponent(ProjectPackageLayout.recoveryDraftName) }
}

struct ProjectRecoveryDraftTests {
    @Test func freshProjectHasNoRecoverySidecarsAndAcceptsItsFirstJournaledSave() throws {
        let f = try RecoveryFixture(); defer { f.cleanup() }
        #expect(try !f.store.hasRecoveryDraft(for: f.document.id))
        #expect(try f.store.recoveryDraft(for: f.document.id) == nil)
        let checkpoint = try f.store.file(ProjectPackageLayout.checkpointName, in: f.package)
        #expect(!FileManager.default.fileExists(atPath: checkpoint.path))
        var proposed = f.document
        proposed.title = "My first project"
        let draft = ProjectRecoveryDraft(ownerID: UUID(), sequence: 1, base: f.document, proposed: proposed)
        try f.store.saveRecoveryDraft(draft)
        #expect(try f.store.recoveryDraft(for: f.document.id)?.proposed == proposed)
        proposed.revision += 1
        try f.store.save(proposed, replacing: f.document)
        try f.store.discardRecoveryDraft(for: f.document.id, ownerID: draft.ownerID, through: draft.sequence)
        #expect(try f.store.load(f.document.id) == proposed)
        #expect(try !f.store.hasRecoveryDraft(for: f.document.id))
        #expect(try Data(contentsOf: f.package.appendingPathComponent("Originals/source.mov")) == Data([1, 2, 3, 4]))
    }

    @Test func unfinishedDraftSurvivesNewStoreWithoutChangingCanonicalOrMedia() throws {
        let f = try RecoveryFixture(); defer { f.cleanup() }
        let before = try Data(contentsOf: f.package.appendingPathComponent("document.json"))
        var proposed = f.document
        proposed.title = ""
        proposed.editedText = "Tiếng Việt — edited 👋"
        let draft = ProjectRecoveryDraft(ownerID: UUID(), sequence: 4, base: f.document, proposed: proposed)
        try f.store.saveRecoveryDraft(draft)
        let reopened = ProjectPackageStore<RecoveryDocument>(rootURL: f.root)
        let recovered = try #require(try reopened.recoveryDraft(for: f.document.id))
        #expect(recovered.ownerID == draft.ownerID)
        #expect(recovered.sequence == 4)
        #expect(recovered.proposed == proposed)
        #expect(try reopened.load(f.document.id) == f.document)
        #expect(try Data(contentsOf: f.package.appendingPathComponent("document.json")) == before)
        #expect(try Data(contentsOf: f.package.appendingPathComponent("Originals/source.mov")) == Data([1, 2, 3, 4]))
    }

    @Test func staleCleanupAndDifferentOwnerCannotRemoveOrReplaceNewerEdits() throws {
        let f = try RecoveryFixture(); defer { f.cleanup() }
        let owner = UUID()
        var proposed = f.document; proposed.editedText = "First edit"
        try f.store.saveRecoveryDraft(.init(ownerID: owner, sequence: 1, base: f.document, proposed: proposed))
        proposed.editedText = "Newer edit"
        try f.store.saveRecoveryDraft(.init(ownerID: owner, sequence: 2, base: f.document, proposed: proposed))
        try f.store.discardRecoveryDraft(for: f.document.id, ownerID: owner, through: 1)
        try f.store.discardRecoveryDraft(for: f.document.id, ownerID: UUID(), through: 9)
        #expect(try f.store.recoveryDraft(for: f.document.id)?.sequence == 2)
        #expect(throws: ProjectStoreError.self) {
            try f.store.saveRecoveryDraft(.init(ownerID: UUID(), sequence: 3, base: f.document, proposed: proposed))
        }
        try f.store.discardRecoveryDraft(for: f.document.id, ownerID: owner, through: 2)
        #expect(try !f.store.hasRecoveryDraft(for: f.document.id))
    }

    @Test func equalSequenceIsIdempotentButCannotRewriteItsContents() throws {
        let f = try RecoveryFixture(); defer { f.cleanup() }
        let owner = UUID()
        let value = ProjectRecoveryDraft(ownerID: owner, sequence: 3, base: f.document, proposed: f.document)
        try f.store.saveRecoveryDraft(value)
        let bytes = try Data(contentsOf: f.draftURL)
        try f.store.saveRecoveryDraft(value)
        #expect(try Data(contentsOf: f.draftURL) == bytes)
        var changed = f.document; changed.editedText = "Different"
        #expect(throws: ProjectStoreError.self) {
            try f.store.saveRecoveryDraft(.init(ownerID: owner, sequence: 3, base: f.document, proposed: changed))
        }
    }

    @Test func corruptAndFutureDraftsBlockReplacementAndRemainUntilExplicitDiscard() throws {
        let f = try RecoveryFixture(); defer { f.cleanup() }
        let draft = ProjectRecoveryDraft(ownerID: UUID(), sequence: 1, base: f.document, proposed: f.document)
        for bytes in [Data("{corrupt".utf8), try JSONEncoder().encode(draft)] {
            var data = bytes
            if var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                json["version"] = 99
                data = try JSONSerialization.data(withJSONObject: json)
            }
            try data.write(to: f.draftURL, options: .atomic)
            #expect(throws: (any Error).self) { try f.store.saveRecoveryDraft(draft) }
            #expect(try Data(contentsOf: f.draftURL) == data)
            #expect(try f.store.load(f.document.id) == f.document)
            try f.store.discardRecoveryDraft(for: f.document.id, ownerID: nil)
            #expect(try !f.store.hasRecoveryDraft(for: f.document.id))
        }
    }

    @Test func missingMediaDoesNotPreventProtectingAnEditingDraft() throws {
        let f = try RecoveryFixture(); defer { f.cleanup() }
        try FileManager.default.removeItem(at: f.package.appendingPathComponent("Originals/source.mov"))
        var proposed = f.document; proposed.editedText = "Recover these edits"
        try f.store.saveRecoveryDraft(.init(ownerID: UUID(), sequence: 1, base: f.document, proposed: proposed))
        #expect(try f.store.recoveryDraft(for: f.document.id)?.proposed == proposed)
    }

    @Test func symlinkDraftCannotRedirectReadsWritesOrDiscard() throws {
        let f = try RecoveryFixture(); defer { f.cleanup() }
        let outside = f.root.appendingPathComponent("keep.json")
        let bytes = Data("keep".utf8)
        try bytes.write(to: outside)
        try FileManager.default.createSymbolicLink(at: f.draftURL, withDestinationURL: outside)
        #expect(throws: ProjectStoreError.self) { try f.store.recoveryDraft(for: f.document.id) }
        #expect(throws: ProjectStoreError.self) { try f.store.discardRecoveryDraft(for: f.document.id, ownerID: nil) }
        #expect(try Data(contentsOf: outside) == bytes)
    }
}
