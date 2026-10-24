import Foundation
import Testing
@testable import InkribeCore

/// Source specifications only; do not execute under the current work agreement.
struct ProjectFilePathTests {
    @Test func existingAndMissingChildrenUseTheSameOwnerAcrossDirectoryURLForms() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? files.removeItem(at: root) }
        let owner = root.appendingPathComponent("real/project.inkribe", isDirectory: true)
        try files.createDirectory(at: owner, withIntermediateDirectories: true)
        try files.createSymbolicLink(at: root.appendingPathComponent("alias"),
                                     withDestinationURL: root.appendingPathComponent("real"))
        let existing = owner.appendingPathComponent("document.json")
        try Data("saved".utf8).write(to: existing)
        let canonical = owner.resolvingSymlinksInPath().standardizedFileURL
        let paths = [owner.path, root.appendingPathComponent("alias/project.inkribe").path]
        for path in paths {
            for directoryHint in [false, true] {
                let form = URL(fileURLWithPath: path, isDirectory: directoryHint)
                let saved = try ProjectFilePath.url(for: "document.json", in: form)
                #expect(try Data(contentsOf: saved) == Data("saved".utf8))
                for name in ["editor-draft.json", "speech-checkpoint.json", "Originals/new.mov"] {
                    let missing = try ProjectFilePath.url(for: name, in: form)
                    #expect(missing.pathComponents == canonical.pathComponents + name.split(separator: "/").map(String.init))
                    #expect(!files.fileExists(atPath: missing.path))
                }
            }
        }
        #expect(try files.contentsOfDirectory(atPath: owner.path) == ["document.json"])
    }

    @Test func unsafeChildrenAndLinkedOwnersRemainRejected() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: root) }
        let owner = root.appendingPathComponent("project.inkribe", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try files.createDirectory(at: owner, withIntermediateDirectories: true)
        try files.createDirectory(at: outside, withIntermediateDirectories: true)
        for name in ["", "/absolute", "..", "../outside", "Originals/../escape", "Originals//source",
                     "Originals/.", "Originals/a%2fb", "Originals/a:b", "Originals/a\\b", "Originals/a\0b"] {
            #expect(throws: ProjectStoreError.self) { try ProjectFilePath.url(for: name, in: owner) }
        }
        try files.createSymbolicLink(at: owner.appendingPathComponent("linked"), withDestinationURL: outside)
        try files.createSymbolicLink(at: owner.appendingPathComponent("dangling"),
                                     withDestinationURL: outside.appendingPathComponent("absent"))
        try Data("keep".utf8).write(to: owner.appendingPathComponent("regular"))
        for name in ["linked/new.json", "dangling", "dangling/new.json", "regular/child"] {
            #expect(throws: ProjectStoreError.self) { try ProjectFilePath.url(for: name, in: owner) }
        }
        let linkedOwner = root.appendingPathComponent("linked.inkribe")
        try files.createSymbolicLink(at: linkedOwner, withDestinationURL: owner)
        #expect(throws: ProjectStoreError.self) { try ProjectFilePath.url(for: "document.json", in: linkedOwner) }
        #expect(try files.contentsOfDirectory(atPath: outside.path).isEmpty)
    }
}
