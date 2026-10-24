import Foundation

/// Synchronous transaction component: the application's single repository actor
/// owns this store. It creates no tasks, runtime handles, queue or competing index.
/// The root is supplied by the native adapter, never encoded in a document.
public struct ProjectPackageStore<Document: ProjectPackageDocument>: Sendable {
    public let rootURL: URL
    private var files: FileManager { .default }

    public init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    public func directory(_ name: String) throws -> URL {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\"),
              !name.contains("\0"), name != ".", name != ".." else { throw ProjectStoreError.invalidPath(name) }
        try requireDirectory(rootURL, create: true)
        let result = rootURL.appendingPathComponent(name, isDirectory: true)
        try requireDirectory(result, create: true)
        return result
    }

    /// A path for a NEW package only. It never creates the package itself.
    public func destination(for id: UUID, in location: ProjectPackageLocation = .projects) throws -> URL {
        try directory(location.rawValue).appendingPathComponent(ProjectPackageLayout.name(for: id), isDirectory: true)
    }

    /// Resolve/migrate before returning any native source URL. Every legacy
    /// directory is validated in place, receives a small format marker, then a
    /// same-parent atomic rename commits it. Crash: old path OR new path; there
    /// is no media copy, document rewrite, inference or half-adopted destination.
    public func packageURL(for id: UUID, in location: ProjectPackageLocation = .projects) throws -> URL {
        let candidates = try existingCandidates(for: id, in: location)
        guard candidates.count == 1, let source = candidates.first else {
            if candidates.isEmpty { throw ProjectStoreError.missingProject(id) }
            throw ProjectStoreError.packageConflict(id)
        }
        try requireDirectory(source, create: false)
        if source.pathExtension.lowercased() == ProjectPackageLayout.packageExtension {
            try validateManifest(in: source, expectedID: id)
            return source
        }
        // Reject unknown future documents before touching even the wrapper.
        let document = try readRecoverable(in: source, expectedID: id)
        try validateOwnedSources(document, in: source, requirePresent: false)
        let marker = try file(ProjectPackageLayout.manifestName, in: source)
        if try exists(marker) {
            try validateManifest(in: source, expectedID: id)
        } else {
            try encode(ProjectPackageManifest(projectID: id)).write(to: marker, options: .atomic)
        }
        try Task.checkCancellation()
        let target = try destination(for: id, in: location)
        guard try !exists(target) else { throw ProjectStoreError.packageConflict(id) }
        // Do not add a cancellation point after publication. The directory
        // remains authoritative at its new name even if a caller is cancelled.
        try files.moveItem(at: source, to: target)
        return target
    }

    public func load(_ id: UUID, in location: ProjectPackageLocation = .projects) throws -> Document {
        let package = try packageURL(for: id, in: location)
        return try readRecoverable(in: package, expectedID: id)
    }

    public func identities(in location: ProjectPackageLocation = .projects) throws -> [UUID] {
        let base = try directory(location.rawValue)
        let entries = try files.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
        return Array(Set(entries.compactMap { ProjectPackageLayout.identity(of: $0) }))
            .sorted { $0.uuidString < $1.uuidString }
    }

    public func contains(_ id: UUID, in location: ProjectPackageLocation) throws -> Bool {
        try !existingCandidates(for: id, in: location).isEmpty
    }

    /// Stage outside Projects; the caller retains ownership until publication.
    public func commitNew(_ document: Document, stagedAt staging: URL) throws -> URL {
        try Task.checkCancellation()
        try document.validatePackageDocument()
        let pending = try directory("Pending")
        guard staging.deletingLastPathComponent().standardizedFileURL == pending.standardizedFileURL,
              UUID(uuidString: staging.lastPathComponent) != nil else {
            throw ProjectStoreError.invalidPath(staging.path)
        }
        try requireDirectory(staging, create: false)
        let id = document.packageIdentity.id
        guard try !contains(id, in: .projects), try !contains(id, in: .trash) else {
            throw ProjectStoreError.duplicateProject(id)
        }
        try validateOwnedSources(document, in: staging, requirePresent: true)
        try encode(document).write(to: file(ProjectPackageLayout.documentName, in: staging), options: .atomic)
        try encode(ProjectPackageManifest(projectID: id)).write(
            to: file(ProjectPackageLayout.manifestName, in: staging), options: .atomic)
        try Task.checkCancellation()
        let target = try destination(for: id)
        try files.moveItem(at: staging, to: target)
        return target
    }

    /// Immutable-source/recognition rules and revision increments belong to the
    /// app's semantic transaction. Recheck the durable expected revision here.
    public func save(_ next: Document, replacing expected: Document) throws {
        let id = expected.packageIdentity.id
        guard next.packageIdentity.id == id else {
            throw ProjectStoreError.invalidDocument("Project identity cannot be rewritten")
        }
        let package = try packageURL(for: id)
        let current = try readRecoverable(in: package, expectedID: id)
        guard current.packageIdentity.revision == expected.packageIdentity.revision else {
            throw ProjectStoreError.staleRevision(expected: expected.packageIdentity.revision,
                                                  actual: current.packageIdentity.revision)
        }
        guard try encode(current) == encode(expected) else {
            throw ProjectStoreError.invalidDocument("The saved project changed without a matching revision. Reload before saving.")
        }
        guard expected.packageIdentity.revision < UInt64.max else { throw ProjectEditConflict.revisionOverflow }
        guard next.packageIdentity.revision == expected.packageIdentity.revision + 1 else {
            throw ProjectStoreError.invalidDocument("A project save must advance its revision exactly once")
        }
        try next.validatePackageDocument()
        try validateOwnedSources(next, in: package, requirePresent: true)
        let data = try encode(next)
        let previous = try encode(current)
        // Require existing structure. Atomic Data.write must not resurrect a
        // project deleted/moved by another owner at a stale URL.
        try requireDirectory(package, create: false)
        try previous.write(to: file(ProjectPackageLayout.previousDocumentName, in: package), options: .atomic)
        try data.write(to: file(ProjectPackageLayout.documentName, in: package), options: .atomic)
    }

    public func move(_ id: UUID, from source: ProjectPackageLocation, to target: ProjectPackageLocation) throws {
        guard source != target else { return }
        let origin = try packageURL(for: id, in: source)
        // Validate BEFORE changing location, including restore of corrupt/future
        // packages. Failed restore keeps the project in Trash.
        _ = try readRecoverable(in: origin, expectedID: id)
        guard try !contains(id, in: target) else { throw ProjectStoreError.duplicateProject(id) }
        let destination = try self.destination(for: id, in: target)
        try files.moveItem(at: origin, to: destination)
    }

    public func removeFromTrash(_ id: UUID) throws {
        let candidates = try existingCandidates(for: id, in: .trash)
        guard candidates.count == 1, let path = candidates.first else {
            if candidates.isEmpty { throw ProjectStoreError.missingProject(id) }
            throw ProjectStoreError.packageConflict(id)
        }
        try requireDirectory(path, create: false)
        // Explicit destructive cleanup may remove a corrupt/future package,
        // but never follows a symlink or removes a collision implicitly.
        try files.removeItem(at: path)
    }

    /// Startup import recovery does not remove uncommitted/corrupt staging.
    public func recoverCommittedStaging(excluding active: Set<UUID>) throws -> [UUID] {
        let entries = try files.contentsOfDirectory(at: directory("Pending"), includingPropertiesForKeys: nil)
        var restored: [UUID] = []
        for path in entries {
            guard let stagingID = UUID(uuidString: path.lastPathComponent), !active.contains(stagingID),
                  (try? requireDirectory(path, create: false)) != nil,
                  let value = try? readDocument(at: file(ProjectPackageLayout.documentName, in: path)) else { continue }
            let id = value.packageIdentity.id
            guard try !contains(id, in: .projects), try !contains(id, in: .trash) else { continue }
            guard (try? validateOwnedSources(value, in: path, requirePresent: true)) != nil else { continue }
            // Old committed staging has no wrapper; never rewrite its document.
            let marker = try file(ProjectPackageLayout.manifestName, in: path)
            if try exists(marker) {
                guard (try? validateManifest(in: path, expectedID: id)) != nil else { continue }
            } else {
                try encode(ProjectPackageManifest(projectID: id)).write(to: marker, options: .atomic)
            }
            try files.moveItem(at: path, to: destination(for: id))
            restored.append(id)
        }
        return restored
    }

    public func file(_ relativePath: String, in package: URL) throws -> URL {
        try ProjectFilePath.url(for: relativePath, in: package)
    }

    public func hasRecoveryDraft(for id: UUID) throws -> Bool {
        let package = try packageURL(for: id)
        return try exists(file(ProjectPackageLayout.recoveryDraftName, in: package))
    }

    public func recoveryDraft(for id: UUID) throws -> ProjectRecoveryDraft<Document>? {
        let package = try packageURL(for: id)
        let path = try file(ProjectPackageLayout.recoveryDraftName, in: package)
        guard try exists(path) else { return nil }
        let data = try boundedRead(path, maximumBytes: Self.maximumRecoveryDraftBytes)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let draft = try decoder.decode(ProjectRecoveryDraft<Document>.self, from: data)
        try validateRecoveryDraft(draft, id: id)
        return draft
    }

    public func saveRecoveryDraft(_ draft: ProjectRecoveryDraft<Document>) throws {
        let id = draft.base.packageIdentity.id
        try validateRecoveryDraft(draft, id: id)
        let package = try packageURL(for: id)
        if let previous = try recoveryDraft(for: id) {
            guard previous.ownerID == draft.ownerID, previous.sequence <= draft.sequence else {
                throw ProjectStoreError.invalidDocument("A newer or different editor draft must be recovered first")
            }
            if previous.sequence == draft.sequence {
                guard try encodeRecoveryDraft(previous) == encodeRecoveryDraft(draft) else {
                    throw ProjectStoreError.invalidDocument("The saved draft changed without a new edit sequence")
                }
                return
            }
        }
        try encodeRecoveryDraft(draft).write(to: file(ProjectPackageLayout.recoveryDraftName, in: package), options: .atomic)
    }

    private static var maximumRecoveryDraftBytes: Int { 2 * maximumDocumentBytes + 4096 }

    private func encodeRecoveryDraft(_ draft: ProjectRecoveryDraft<Document>) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(draft)
        guard data.count <= Self.maximumRecoveryDraftBytes else { throw ProjectStoreError.oversizedProjectMetadata }
        return data
    }

    /// Conditional cleanup cannot remove a newer editor's work. Nil identity is
    /// reserved for a separately confirmed, explicit discard of unreadable data.
    public func discardRecoveryDraft(for id: UUID, ownerID: UUID?, through sequence: UInt64? = nil) throws {
        let package = try packageURL(for: id)
        let path = try file(ProjectPackageLayout.recoveryDraftName, in: package)
        guard try exists(path) else { return }
        if let ownerID {
            guard let draft = try recoveryDraft(for: id), draft.ownerID == ownerID,
                  let sequence, draft.sequence <= sequence else { return }
        }
        let values = try path.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { throw ProjectStoreError.invalidPath(path.path) }
        try files.removeItem(at: path)
    }

    private func validateRecoveryDraft(_ draft: ProjectRecoveryDraft<Document>, id: UUID) throws {
        guard draft.version == 1, draft.sequence > 0,
              draft.base.packageIdentity.id == id, draft.proposed.packageIdentity.id == id,
              draft.proposed.packageIdentity.revision == draft.base.packageIdentity.revision,
              draft.proposed.packageIdentity.schemaVersion <= Document.supportedPackageDocumentSchema,
              draft.proposed.packageSources == draft.base.packageSources else {
            throw ProjectStoreError.invalidDocument("Unsupported or inconsistent editor recovery draft")
        }
        try draft.base.validatePackageDocument()
    }

    public func storage(of id: UUID) throws -> ProjectPackageStorage {
        let package = try packageURL(for: id)
        var sources: Int64 = 0, data: Int64 = 0, cache: Int64 = 0, temp: Int64 = 0
        try ProjectStorageScanner.forEachFile(at: package, rejectSymbolicLinks: true) { url, count in
            let relative = String(url.path.dropFirst(package.path.count + 1))
            switch relative.split(separator: "/").first {
            case "Originals": sources += count
            case "Cache": cache += count
            case "Temp": temp += count
            default: data += count // Includes sidecars and RecognitionRecovery.
            }
        }
        return ProjectPackageStorage(sources: sources, durableData: data, derivedCache: cache, temporaryWork: temp)
    }

    private func existingCandidates(for id: UUID, in location: ProjectPackageLocation) throws -> [URL] {
        let parent = try directory(location.rawValue)
        // Enumerate actual entries so mixed-case names, restored duplicates and
        // case-insensitive volumes have one unambiguous identity policy. Only
        // matching entries are inspected; there is no separate library index.
        return try files.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
            .filter { ProjectPackageLayout.identity(of: $0) == id }
    }

    private func validateManifest(in package: URL, expectedID: UUID) throws {
        let path = try file(ProjectPackageLayout.manifestName, in: package)
        let data = try boundedRead(path, maximumBytes: 16_384)
        let value = try JSONDecoder().decode(ProjectPackageManifest.self, from: data)
        guard value.formatVersion == ProjectPackageLayout.formatVersion else {
            throw ProjectStoreError.unsupportedPackageVersion(value.formatVersion)
        }
        guard value.projectID == expectedID else {
            throw ProjectStoreError.invalidDocument("Package and document identities differ")
        }
    }

    private func readRecoverable(in package: URL, expectedID: UUID) throws -> Document {
        let value: Document
        do { value = try readDocument(at: file(ProjectPackageLayout.documentName, in: package)) }
        catch let error as ProjectStoreError {
            guard case .invalidDocument = error else { throw error }
            value = try readDocument(at: file(ProjectPackageLayout.previousDocumentName, in: package))
        } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            [NSFileNoSuchFileError, NSFileReadNoSuchFileError, NSPropertyListReadCorruptError].contains(error.code) {
            value = try readDocument(at: file(ProjectPackageLayout.previousDocumentName, in: package))
        } catch { throw error }
        guard value.packageIdentity.id == expectedID else {
            throw ProjectStoreError.invalidDocument("Directory and document identities differ")
        }
        return value
    }

    private func readDocument(at url: URL) throws -> Document {
        // Same generous limit for reads/writes: no successful save may publish
        // a document that this store refuses to reopen. Metadata, never media.
        let data = try boundedRead(url, maximumBytes: Self.maximumDocumentBytes)
        if let header = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let version = header["schemaVersion"] as? Int, version > Document.supportedPackageDocumentSchema {
            throw ProjectStoreError.unsupportedSchema(version)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let value = try decoder.decode(Document.self, from: data)
            try value.validatePackageDocument()
            return value
        } catch let error as ProjectStoreError { throw error }
        catch { throw ProjectStoreError.invalidDocument(error.localizedDescription) }
    }

    private static var maximumDocumentBytes: Int { 256 * 1024 * 1024 }

    private func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        guard data.count <= Self.maximumDocumentBytes else {
            throw ProjectStoreError.oversizedProjectMetadata
        }
        return data
    }

    private func boundedRead(_ path: URL, maximumBytes: Int) throws -> Data {
        let attributes = try files.attributesOfItem(atPath: path.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.int64Value, size >= 0 else {
            throw ProjectStoreError.invalidPath(path.path)
        }
        guard size <= Int64(maximumBytes) else { throw ProjectStoreError.oversizedProjectMetadata }
        let input = try FileHandle(forReadingFrom: path)
        defer { try? input.close() }
        var data = Data()
        while let part = try input.read(upToCount: min(1_048_576, maximumBytes + 1 - data.count)), !part.isEmpty {
            data.append(part)
            guard data.count <= maximumBytes else {
                throw ProjectStoreError.oversizedProjectMetadata
            }
        }
        return data
    }

    private func validateOwnedSources(_ document: Document, in package: URL, requirePresent: Bool) throws {
        for source in document.packageSources {
            let url = try file(source.relativePath, in: package)
            // Adoption preserves damaged/missing media too: its captions must
            // stay readable and the native layer can report/relink the source.
            // New publications/saves still require exact original file sizes.
            guard requirePresent else { continue }
            if try !exists(url) {
                throw ProjectStoreError.missingOriginal(source.relativePath)
            }
            let attributes = try files.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? NSNumber)?.int64Value == source.byteCount else {
                throw ProjectStoreError.invalidDocument("Original media file size changed")
            }
        }
    }

    private func exists(_ path: URL) throws -> Bool {
        do { _ = try files.attributesOfItem(atPath: path.path); return true }
        catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) {
            return false
        }
    }

    private func requireDirectory(_ path: URL, create: Bool) throws {
        if try !exists(path) {
            guard create else { throw ProjectStoreError.invalidPath(path.path) }
            try files.createDirectory(at: path, withIntermediateDirectories: true)
        }
        let attributes = try files.attributesOfItem(atPath: path.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw ProjectStoreError.invalidPath(path.path)
        }
    }
}
