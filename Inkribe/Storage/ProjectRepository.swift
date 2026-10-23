import CryptoKit
import Foundation

/// One document repository per app process. Views, imports, transcription and editor
/// sessions must all receive this same instance, never create per-screen stores.
actor ProjectRepository {
    static let shared = ProjectRepository()

    private let overrideRoot: URL?
    private let files = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var activeStaging: Set<UUID> = []

    init(root: URL? = nil) {
        overrideRoot = root
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    private func root() throws -> URL {
        if let overrideRoot { return overrideRoot.standardizedFileURL }
        guard let appSupport = files.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw ProjectStoreError.unavailableRoot
        }
        return appSupport.appendingPathComponent("InkribeIOSProjects", isDirectory: true)
    }

    private func directory(_ name: String) throws -> URL {
        let url = try root().appendingPathComponent(name, isDirectory: true)
        try files.createDirectory(at: url, withIntermediateDirectories: true)
        if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            throw ProjectStoreError.invalidPath(url.path)
        }
        return url
    }

    private func projectDirectory(_ id: UUID) throws -> URL {
        try directory("Projects").appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func documentURL(in project: URL) -> URL {
        project.appendingPathComponent("document.json")
    }

    private func recoveryURL(in project: URL) -> URL {
        project.appendingPathComponent("document.previous.json")
    }

    func makeStagingDirectory() throws -> URL {
        let url = try directory("Pending").appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: url.appendingPathComponent("Originals", isDirectory: true),
                                  withIntermediateDirectories: true)
        if let id = UUID(uuidString: url.lastPathComponent) { activeStaging.insert(id) }
        return url
    }

    func discardStaging(_ url: URL) throws {
        let parent = try directory("Pending").resolvingSymlinksInPath().standardizedFileURL
        guard url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL == parent,
              UUID(uuidString: url.lastPathComponent) != nil else {
            throw ProjectStoreError.invalidPath(url.path)
        }
        defer { if let id = UUID(uuidString: url.lastPathComponent) { activeStaging.remove(id) } }
        if files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
    }

    /// The staging directory is on the same volume as Projects. One final rename
    /// publishes a complete immutable set of originals and a validated document.
    func commitNew(_ document: ProjectDocument, stagedAt staging: URL) throws -> ProjectDocument {
        try Task.checkCancellation()
        try document.validate()
        let pending = try directory("Pending").resolvingSymlinksInPath().standardizedFileURL
        guard staging.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL == pending,
              UUID(uuidString: staging.lastPathComponent) != nil else {
            throw ProjectStoreError.invalidPath(staging.path)
        }
        let destination = try projectDirectory(document.id)
        guard !files.fileExists(atPath: destination.path) else {
            throw ProjectStoreError.duplicateProject(document.id)
        }
        try verifyOriginals(of: document, in: staging)
        let encoded = try encoder.encode(document)
        try encoded.write(to: documentURL(in: staging), options: .atomic)
        try Task.checkCancellation()
        try files.moveItem(at: staging, to: destination)
        if let id = UUID(uuidString: staging.lastPathComponent) { activeStaging.remove(id) }
        return document
    }

    /// Do not report a successful edit until the complete document was atomically
    /// committed. A previous valid JSON copy remains available for recovery.
    func commitEdit(_ proposed: ProjectDocument, expectedRevision: UInt64) throws -> ProjectDocument {
        try writeEdit(proposed, expectedRevision: expectedRevision)
    }

    /// Only the explicit empty-result recovery operation may clear recognition.
    private func writeEdit(_ proposed: ProjectDocument, expectedRevision: UInt64,
                           clearingEmptyRecognitionID: UUID? = nil) throws -> ProjectDocument {
        let current = try open(proposed.id)
        guard current.contentRevision == expectedRevision else {
            throw ProjectStoreError.staleRevision(expected: expectedRevision,
                                                      actual: current.contentRevision)
        }
        guard expectedRevision < UInt64.max else { throw ProjectEditConflict.revisionOverflow }
        var next = proposed
        next.schemaVersion = ProjectSchema.current
        next.contentRevision = expectedRevision + 1
        next.updatedAt = max(Date(), current.updatedAt)
        guard next.id == current.id, next.createdAt == current.createdAt else {
            throw ProjectStoreError.invalidDocument("Project identity cannot be rewritten")
        }
        let clearsEmptyRecognition = current.recognition.map {
            $0.id == clearingEmptyRecognitionID && $0.words.isEmpty && $0.cues.isEmpty && next.recognition == nil
        } ?? false
        if let raw = current.recognition, !clearsEmptyRecognition {
            guard let proposed = next.recognition, proposed.id == raw.id,
                  proposed.rawWindows == raw.rawWindows, proposed.modelID == raw.modelID,
                  proposed.modelSHA256 == raw.modelSHA256,
                  proposed.requestedLanguageCode == raw.requestedLanguageCode,
                  proposed.completedAt == raw.completedAt else {
                throw ProjectStoreError.invalidDocument("Raw recognition is immutable")
            }
            let nativeWords = Dictionary(uniqueKeysWithValues: raw.words.map { ($0.id, $0) })
            guard Set(proposed.words.map(\.id)) == Set(nativeWords.keys),
                  proposed.words.allSatisfy({ word in
                      guard let native = nativeWords[word.id] else { return false }
                      return word.clipID == native.clipID && word.rawWindowID == native.rawWindowID &&
                          word.sourceInterval == native.sourceInterval && word.timingProvenance == native.timingProvenance
                  }) else {
                throw ProjectStoreError.invalidDocument("Native word anchors are immutable")
            }
        }
        let existing = Dictionary(uniqueKeysWithValues: current.assets.map { ($0.id, $0) })
        for asset in next.assets {
            guard existing[asset.id] == asset else {
                throw ProjectStoreError.invalidDocument("Existing originals are immutable")
            }
        }
        guard Set(next.assets.map(\.id)) == Set(current.assets.map(\.id)) else {
            throw ProjectStoreError.invalidDocument("Use the importer to add originals")
        }
        try next.validate()
        let directory = try projectDirectory(next.id)
        try verifyOriginals(of: next, in: directory)
        let url = documentURL(in: directory)
        let previous = recoveryURL(in: directory)
        // Never replace the prior recovery point before a valid new document is ready.
        let data = try encoder.encode(next)
        let backup = try encoder.encode(current)
        try backup.write(to: previous, options: .atomic)
        try data.write(to: url, options: .atomic)
        return next
    }

    /// One atomic publication of raw output and editable captions. The job ID
    /// handles a crash after publication but before JobQueue marks completion.
    func saveRecognition(_ result: Recognition, projectID: UUID,
                         expectedRevision: UInt64, chargeAllowance: Bool = false) throws {
        try Task.checkCancellation()
        // Empty legacy results remain readable, but can never be newly published.
        guard !result.words.isEmpty else { throw SpeechError.noRecognizedWords }
        var current = try open(projectID)
        if current.recognition?.id == result.id {
            if chargeAllowance { try finishSpeechAllowance(result.id) }
            return
        }
        guard current.recognition == nil else { throw SpeechError.alreadyTranscribed }
        guard current.contentRevision == expectedRevision else {
            throw ProjectStoreError.staleRevision(expected: expectedRevision,
                                                      actual: current.contentRevision)
        }
        current.recognition = result
        _ = try commitEdit(current, expectedRevision: expectedRevision)
        // The reservation remains durable if charging fails after publication.
        // Retrying/reconciling can settle it without running or charging twice.
        if chargeAllowance { try finishSpeechAllowance(result.id) }
    }

    /// User-requested retry of an empty legacy result. Preserve raw evidence and
    /// all originals/style/media settings; never replace even one existing word.
    func recoverEmptyRecognition(projectID: UUID, recognitionID: UUID,
                                 expectedRevision: UInt64) throws -> ProjectDocument {
        try Task.checkCancellation()
        var project = try open(projectID)
        guard project.contentRevision == expectedRevision else {
            throw ProjectStoreError.staleRevision(expected: expectedRevision, actual: project.contentRevision)
        }
        guard let result = project.recognition, result.id == recognitionID,
              result.words.isEmpty, result.cues.isEmpty else { throw SpeechError.alreadyTranscribed }
        let folder = try projectDirectory(projectID).appendingPathComponent("RecognitionRecovery", isDirectory: true)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        if try folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            throw ProjectStoreError.invalidPath(folder.path)
        }
        let archive = folder.appendingPathComponent(result.id.uuidString + ".json")
        if !files.fileExists(atPath: archive.path) {
            try encoder.encode(result).write(to: archive, options: .atomic)
        }
        // Refund before clearing the document: a crash can leave an empty result
        // to retry again, but never lose the evidence needed for an exact refund.
        try refundEmptySpeech(result, in: project)
        project.recognition = nil
        return try writeEdit(project, expectedRevision: expectedRevision, clearingEmptyRecognitionID: result.id)
    }

    private func refundEmptySpeech(_ result: Recognition, in project: ProjectDocument) throws {
        guard result.words.isEmpty, result.cues.isEmpty,
              files.fileExists(atPath: try speechAllowanceURL().path) else { return }
        var value = try loadSpeechAllowance()
        if value.charged.contains(result.id) {
            let seconds = try CaptionAllowanceLedger.seconds(for: project)
            guard value.used >= seconds else { throw ProError.allowanceStorage }
            value.used -= seconds
            value.charged.remove(result.id)
        }
        value.reservations.removeAll { $0.jobID == result.id }
        try writeSpeechAllowance(value)
    }

    private func speechAllowanceURL() throws -> URL {
        try directory("Usage").appendingPathComponent("caption-allowance-v1.json")
    }

    private func loadSpeechAllowance() throws -> CaptionAllowanceLedger {
        do {
            let url = try speechAllowanceURL()
            var value: CaptionAllowanceLedger
            if files.fileExists(atPath: url.path) {
                let input = try FileHandle(forReadingFrom: url)
                defer { try? input.close() }
                // A normal ledger is a few KB. Bound malformed input before decoding.
                let data = try input.read(upToCount: 1_048_577) ?? Data()
                guard data.count <= 1_048_576 else { throw ProError.allowanceStorage }
                value = try decoder.decode(CaptionAllowanceLedger.self, from: data)
                try value.validate()
            } else {
                value = CaptionAllowanceLedger(weekStart: CaptionAllowanceLedger.week(containing: Date()))
            }
            value.advance(at: Date())
            return value
        } catch { throw ProError.allowanceStorage }
    }

    private func writeSpeechAllowance(_ value: CaptionAllowanceLedger) throws {
        do {
            try value.validate()
            try encoder.encode(value).write(to: speechAllowanceURL(), options: .atomic)
        } catch { throw ProError.allowanceStorage }
    }

    private func hasPublishedSpeech(_ reservation: CaptionAllowanceLedger.Reservation) throws -> Bool {
        let candidates = [try projectDirectory(reservation.projectID),
            try directory("Trash").appendingPathComponent(reservation.projectID.uuidString)]
        for folder in candidates where files.fileExists(atPath: folder.path) {
            let document = try readRecoverable(in: folder)
            guard document.id == reservation.projectID else { throw ProError.allowanceStorage }
            return document.recognition.map { $0.id == reservation.jobID && !$0.words.isEmpty } ?? false
        }
        return false
    }

    /// Called under the controller's request/reconciliation guard. It cannot
    /// race a reservation that has not yet been published into JobQueue.
    func reconcileSpeechAllowance(activeJobIDs: Set<UUID>) throws -> CaptionAllowance {
        var value = try loadSpeechAllowance()
        for reservation in value.reservations {
            if try hasPublishedSpeech(reservation) { value.finish(reservation.jobID) }
            else if !activeJobIDs.contains(reservation.jobID) {
                value.reservations.removeAll { $0.jobID == reservation.jobID }
            }
        }
        try writeSpeechAllowance(value)
        return value.snapshot
    }

    func reserveSpeechAllowance(jobID: UUID, projectID: UUID, revision: UInt64) throws {
        let project = try open(projectID)
        guard project.contentRevision == revision, project.recognition == nil else {
            throw ProjectStoreError.staleRevision(expected: revision, actual: project.contentRevision)
        }
        var value = try loadSpeechAllowance()
        guard !value.charged.contains(jobID), !value.reservations.contains(where: { $0.jobID == jobID }) else {
            throw SpeechError.busy
        }
        let seconds = try CaptionAllowanceLedger.seconds(for: project)
        guard seconds <= value.snapshot.remaining else { throw ProError.requiresPro(.captioning) }
        value.reservations.append(.init(jobID: jobID, projectID: projectID, revision: revision,
                                       weekStart: value.weekStart, seconds: seconds))
        try writeSpeechAllowance(value)
    }

    func requireSpeechAllowance(jobID: UUID, projectID: UUID, revision: UInt64) throws {
        let value = try loadSpeechAllowance()
        guard value.reservations.contains(where: { $0.jobID == jobID && $0.projectID == projectID && $0.revision == revision }) else {
            throw ProError.authorizationUnavailable
        }
    }

    func finishSpeechAllowance(_ jobID: UUID) throws {
        // Older jobs and Pro-authorized jobs carry no free reservation.
        let url = try speechAllowanceURL()
        guard files.fileExists(atPath: url.path) else { return }
        var value = try loadSpeechAllowance()
        guard let reservation = value.reservations.first(where: { $0.jobID == jobID }) else { return }
        guard try hasPublishedSpeech(reservation) else {
            value.reservations.removeAll { $0.jobID == jobID }
            try writeSpeechAllowance(value)
            return
        }
        value.finish(jobID)
        try writeSpeechAllowance(value)
    }

    func releaseSpeechAllowance(_ jobID: UUID) throws {
        guard files.fileExists(atPath: try speechAllowanceURL().path) else { return }
        var value = try loadSpeechAllowance()
        guard value.reservations.contains(where: { $0.jobID == jobID }) else { return }
        value.reservations.removeAll { $0.jobID == jobID }
        try writeSpeechAllowance(value)
    }

    private func settlePublishedSpeechAllowance() throws {
        guard files.fileExists(atPath: try speechAllowanceURL().path) else { return }
        var value = try loadSpeechAllowance()
        for reservation in value.reservations {
            if try hasPublishedSpeech(reservation) { value.finish(reservation.jobID) }
        }
        try writeSpeechAllowance(value)
    }

    func rename(_ id: UUID, title: String, expectedRevision: UInt64) throws -> ProjectDocument {
        var value = try open(id)
        value.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return try commitEdit(value, expectedRevision: expectedRevision)
    }

    func open(_ id: UUID) throws -> ProjectDocument {
        let directory = try projectDirectory(id)
        guard files.fileExists(atPath: directory.path) else { throw ProjectStoreError.missingProject(id) }
        let document = try readRecoverable(in: directory)
        guard document.id == id else {
            throw ProjectStoreError.invalidDocument("Directory and document identities differ")
        }
        return document
    }

    private func readRecoverable(in directory: URL) throws -> ProjectDocument {
        do {
            return try read(documentURL(in: directory))
        } catch ProjectStoreError.unsupportedSchema(let version) {
            throw ProjectStoreError.unsupportedSchema(version)
        } catch {
            // A corrupt last write never causes an implicit destructive reset.
            return try read(recoveryURL(in: directory))
        }
    }

    private func read(_ url: URL) throws -> ProjectDocument {
        let data = try Data(contentsOf: url)
        if let header = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let version = header["schemaVersion"] as? Int,
           version > ProjectSchema.current {
            throw ProjectStoreError.unsupportedSchema(version)
        }
        let document = try decoder.decode(ProjectDocument.self, from: data)
        try document.validate()
        return document
    }


    /// Explicit integrity review (not on every library list/launch). Hash
    /// verification is streamed and cannot silently rewrite corrupted media.
    func integrityIssues(projectID: UUID) throws -> [LibraryIssue] {
        let project = try open(projectID)
        var issues: [LibraryIssue] = []
        for asset in project.assets {
            do {
                let url = try sourceURL(projectID: projectID, assetID: asset.id)
                let input = try FileHandle(forReadingFrom: url)
                defer { try? input.close() }
                var digest = SHA256()
                var bytes: Int64 = 0
                while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                    try Task.checkCancellation()
                    let (sum, overflow) = bytes.addingReportingOverflow(Int64(chunk.count))
                    guard !overflow else { throw ProjectStoreError.oversizedImport }
                    bytes = sum
                    digest.update(data: chunk)
                }
                let actualHash = digest.finalize().map { String(format: "%02x", $0) }.joined()
                if bytes != asset.byteCount || actualHash != asset.sha256 {
                    issues.append(LibraryIssue(id: asset.id,
                                                  description: "Original media integrity check failed: " + asset.displayName))
                }
            } catch {
                issues.append(LibraryIssue(id: asset.id,
                                              description: asset.displayName + ": " + error.localizedDescription))
            }
        }
        return issues
    }

    func sourceURL(projectID: UUID, assetID: UUID) throws -> URL {
        let project = try open(projectID)
        guard let asset = project.assets.first(where: { $0.id == assetID }) else {
            throw ProjectStoreError.invalidDocument("Asset is not in this project")
        }
        let url = try OwnedPath.secureURL(for: asset.relativeOriginalPath,
                                             base: "Originals", in: projectDirectory(projectID))
        guard files.fileExists(atPath: url.path) else {
            throw ProjectStoreError.missingOriginal(asset.displayName)
        }
        return url
    }

    func list(titleQuery: String = "", sort: LibrarySort = .recent,
              filter: LibraryFilter = .all) throws -> LibrarySnapshot {
        let base = try directory("Projects")
        let children = try files.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
        var projects: [ProjectSummary] = []
        var issues: [LibraryIssue] = []
        for child in children where child.hasDirectoryPath {
            guard let id = UUID(uuidString: child.lastPathComponent) else { continue }
            do {
                let document = try open(id)
                let available = (try? originalsExist(of: document, in: child)) ?? false
                let matches: Bool
                switch filter {
                case .all: matches = true
                case .video: matches = document.assets.contains { $0.kind == .video }
                case .audio: matches = !document.assets.contains { $0.kind == .video }
                case .missingMedia: matches = !available
                }
                guard matches, titleQuery.isEmpty ||
                      document.title.localizedStandardContains(titleQuery) else { continue }
                let duration = document.outputDuration
                let cache = try? thumbnailURL(id: id)
                let captionState: ProjectCaptionState
                if let recognition = document.recognition {
                    captionState = recognition.words.isEmpty ? .emptyResult : .saved
                } else {
                    captionState = document.assets.contains { $0.metadata.audioTrackCount > 0 } ? .needsTranscription : .noAudio
                }
                projects.append(ProjectSummary(
                    id: id, title: document.title, updatedAt: document.updatedAt,
                    duration: duration,
                    mediaKind: document.assets.contains { $0.kind == .video } ? .video : .audio,
                    available: available,
                    thumbnailURL: cache.flatMap { files.fileExists(atPath: $0.path) ? $0 : nil },
                    contentRevision: document.contentRevision,
                    captionState: captionState
                ))
                if !available { issues.append(LibraryIssue(id: id, description: "Original media is missing")) }
            } catch {
                issues.append(LibraryIssue(id: id, description: error.localizedDescription))
            }
        }
        switch sort {
        case .recent: projects.sort { $0.updatedAt > $1.updatedAt }
        case .oldest: projects.sort { $0.updatedAt < $1.updatedAt }
        case .title: projects.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
        return LibrarySnapshot(projects: projects, issues: issues)
    }

    /// Duplicates own physical originals. Clip and asset instance IDs never alias
    /// a previous project, so later deletion cannot break another document.
    func duplicate(_ id: UUID) throws -> ProjectDocument {
        let original = try open(id)
        let staging = try makeStagingDirectory()
        do {
            var newAssets: [SourceAsset] = []
            var mapping: [UUID: UUID] = [:]
            for asset in original.assets {
                let newID = UUID()
                mapping[asset.id] = newID
                let ext = URL(fileURLWithPath: asset.relativeOriginalPath).pathExtension
                let name = newID.uuidString + (ext.isEmpty ? "" : "." + ext)
                let path = "Originals/" + name
                let origin = try sourceURL(projectID: id, assetID: asset.id)
                let destination = try OwnedPath.secureURL(for: path, base: "Originals", in: staging)
                try files.copyItem(at: origin, to: destination)
                newAssets.append(SourceAsset(id: newID, relativeOriginalPath: path,
                    kind: asset.kind, origin: asset.origin, displayName: asset.displayName,
                    byteCount: asset.byteCount, sha256: asset.sha256, metadata: asset.metadata))
            }
            var clipMapping: [UUID: UUID] = [:]
            let newClips = try original.clips.map { clip -> ProjectClip in
                guard let targetID = mapping[clip.sourceAssetID] else {
                    throw ProjectStoreError.invalidDocument("Missing duplicated asset mapping")
                }
                let clipID = UUID()
                clipMapping[clip.id] = clipID
                return ProjectClip(id: clipID, sourceAssetID: targetID,
                    sourceInterval: clip.sourceInterval, timelineInterval: clip.timelineInterval)
            }
            let now = Date()
            let copy = ProjectDocument(schemaVersion: ProjectSchema.current,
                id: UUID(), contentRevision: 1, title: String(original.title.prefix(251)) + " Copy",
                createdAt: now, updatedAt: now, preset: original.preset,
                canvas: original.canvas, assets: newAssets, clips: newClips,
                recognition: original.recognition?.duplicated(assetClips: clipMapping),
                captionStyle: original.captionStyle, mediaEdits: original.mediaEdits)
            return try commitNew(copy, stagedAt: staging)
        } catch {
            try? discardStaging(staging)
            throw error
        }
    }

    /// Explicit user deletion moves a *whole* project to recoverable Trash.
    /// Neither cache clearing nor pruning pending imports calls this.
    func moveToTrash(_ id: UUID) throws {
        try settlePublishedSpeechAllowance()
        _ = try open(id)
        let destination = try directory("Trash").appendingPathComponent(id.uuidString)
        guard !files.fileExists(atPath: destination.path) else {
            throw ProjectStoreError.duplicateProject(id)
        }
        try files.moveItem(at: projectDirectory(id), to: destination)
        let thumbnail = try thumbnailURL(id: id)
        try? files.removeItem(at: thumbnail)
    }

    func restoreFromTrash(_ id: UUID) throws {
        let source = try directory("Trash").appendingPathComponent(id.uuidString)
        let destination = try projectDirectory(id)
        guard !files.fileExists(atPath: destination.path) else {
            throw ProjectStoreError.duplicateProject(id)
        }
        guard files.fileExists(atPath: source.path) else {
            throw ProjectStoreError.missingProject(id)
        }
        try files.moveItem(at: source, to: destination)
        _ = try open(id)
    }

    /// Recover fully committed staging documents left between atomic JSON
    /// publication and the directory rename. Incomplete copies stay quarantined
    /// for explicit cleanup; nothing is silently deleted at startup.
    func recoverCommittedStaging() throws -> [UUID] {
        let pending = try directory("Pending")
        let entries = try files.contentsOfDirectory(at: pending, includingPropertiesForKeys: nil)
        var recovered: [UUID] = []
        for staging in entries where staging.hasDirectoryPath {
            guard let stagingID = UUID(uuidString: staging.lastPathComponent), !activeStaging.contains(stagingID),
                  files.fileExists(atPath: documentURL(in: staging).path),
                  let document = try? read(documentURL(in: staging)),
                  (try? verifyOriginals(of: document, in: staging)) != nil else { continue }
            let destination = try projectDirectory(document.id)
            guard !files.fileExists(atPath: destination.path) else { continue }
            try files.moveItem(at: staging, to: destination)
            recovered.append(document.id)
        }
        return recovered
    }

    /// Explicitly discard incomplete imports by their staging UUID after
    /// showing the user's recoverable-space summary. Never touches Projects.
    func pendingStagingIDs() throws -> [UUID] {
        try files.contentsOfDirectory(at: directory("Pending"),
                                      includingPropertiesForKeys: nil)
            .compactMap { UUID(uuidString: $0.lastPathComponent) }
            .filter { !activeStaging.contains($0) }
    }

    func discardPendingImport(id: UUID) throws {
        guard !activeStaging.contains(id) else {
            throw ProjectStoreError.invalidDocument("This import is still running. Cancel it before cleanup.")
        }
        try discardStaging(try directory("Pending").appendingPathComponent(id.uuidString))
    }


    struct TrashedProject: Identifiable, Sendable {
        let id: UUID
        let title: String
    }

    func trashedProjects() throws -> [TrashedProject] {
        let trash = try directory("Trash")
        return try files.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)
            .compactMap { entry -> TrashedProject? in
                guard let id = UUID(uuidString: entry.lastPathComponent),
                      let document = try? readRecoverable(in: entry),
                      document.id == id else { return nil }
                return TrashedProject(id: id, title: document.title)
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Explicitly destructive action, called only after user confirmation.
    func emptyTrash() throws {
        try settlePublishedSpeechAllowance()
        let trash = try directory("Trash")
        for child in try files.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil) {
            guard UUID(uuidString: child.lastPathComponent) != nil,
                  child.deletingLastPathComponent() == trash else { continue }
            try files.removeItem(at: child)
        }
    }

    /// Restore only byte-identical originals. Never silently replace a
    /// different media file or rewrite the document's source identities.
    func restoreMissingOriginal(
        projectID: UUID, assetID: UUID, from externalURL: URL
    ) throws {
        let document = try open(projectID)
        guard let source = document.assets.first(where: { $0.id == assetID }) else {
            throw ProjectStoreError.invalidDocument("Unknown media identity")
        }
        let destination = try OwnedPath.secureURL(for: source.relativeOriginalPath,
                                                     base: "Originals",
                                                     in: projectDirectory(projectID))
        guard !files.fileExists(atPath: destination.path) else {
            throw ProjectStoreError.invalidDocument("The original still exists; it was not replaced")
        }
        guard externalURL.isFileURL else { throw ProjectStoreError.unsupportedURL }
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent("." + UUID().uuidString + ".relink")
        let granted = externalURL.startAccessingSecurityScopedResource()
        defer { if granted { externalURL.stopAccessingSecurityScopedResource() } }
        defer { try? files.removeItem(at: temp) }
        let fileManager = FileManager.default
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var outcome: Result<Void, Error>?
        coordinator.coordinate(readingItemAt: externalURL, options: [], error: &coordinationError) { readable in
            outcome = Result {
                let input = try FileHandle(forReadingFrom: readable)
                defer { try? input.close() }
                guard fileManager.createFile(atPath: temp.path, contents: nil) else {
                    throw ProjectStoreError.unavailableRoot
                }
                let output = try FileHandle(forWritingTo: temp)
                defer { try? output.close() }
                var bytes: Int64 = 0
                var hash = SHA256()
                while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                    try Task.checkCancellation()
                    let (newCount, overflow) = bytes.addingReportingOverflow(Int64(chunk.count))
                    guard !overflow, newCount <= source.byteCount else {
                        throw ProjectStoreError.invalidDocument("Replacement does not match original length")
                    }
                    bytes = newCount
                    hash.update(data: chunk)
                    try output.write(contentsOf: chunk)
                }
                let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
                guard bytes == source.byteCount, digest == source.sha256 else {
                    throw ProjectStoreError.invalidDocument(
                        "Selected file is not byte-identical to the original"
                    )
                }
                try output.synchronize()
            }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else { throw ProjectStoreError.unavailableRoot }
        try outcome.get()
        try files.moveItem(at: temp, to: destination)
    }

    /// Serialize snapshot publication with project deletion/Trash operations.
    /// Hard links pin immutable bytes on the same volume; copying is the fallback.
    func prepareExport(document: ProjectDocument, profile: ExportProfile, id: UUID) throws {
        try Task.checkCancellation()
        let saved = try open(document.id)
        // ISO-8601 disk dates omit fractional seconds; compare the canonical
        // persisted representation, not the returned in-memory Date precision.
        guard saved.contentRevision == document.contentRevision,
              try encoder.encode(saved) == encoder.encode(document) else {
            throw ProjectStoreError.staleRevision(expected: document.contentRevision, actual: saved.contentRevision)
        }
        try saved.validate()
        let snapshot = CaptionSnapshot(saved)
        if profile.format == .srt, !snapshot.cues.contains(where: { !snapshot.text(for: $0).isEmpty }) {
            throw ExportError.noCaptions
        }
        let folder = try exportDirectory(id)
        guard !files.fileExists(atPath: folder.path) else { throw ExportError.invalidRequest }
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var directory = folder
            try directory.setResourceValues(values)
            let media = folder.appendingPathComponent("Media", isDirectory: true)
            try files.createDirectory(at: media, withIntermediateDirectories: true)
            try files.createDirectory(at: folder.appendingPathComponent("Result", isDirectory: true), withIntermediateDirectories: true)
            if profile.format == .mp4 {
                let timeline = OutputTimeline(saved)
                let used = Set(saved.clips.filter { timeline.retained($0.timelineInterval) != nil }.map(\.sourceAssetID))
                for asset in saved.assets where used.contains(asset.id) {
                    try Task.checkCancellation()
                    let source = try sourceURL(projectID: saved.id, assetID: asset.id)
                    let attributes = try files.attributesOfItem(atPath: source.path)
                    guard (attributes[.size] as? NSNumber)?.int64Value == asset.byteCount else {
                        throw ProjectStoreError.missingOriginal(asset.displayName)
                    }
                    let destination = media.appendingPathComponent(asset.id.uuidString + "." + source.pathExtension)
                    do { try files.linkItem(at: source, to: destination) }
                    catch { try files.copyItem(at: source, to: destination) }
                }
            }
            try Task.checkCancellation()
            let manifest = ExportManifest(version: 1, jobID: id, document: saved, profile: profile)
            try encoder.encode(manifest).write(to: folder.appendingPathComponent("request.json"), options: .atomic)
        } catch {
            try? files.removeItem(at: folder)
            throw error
        }
    }

    private func exportDirectory(_ id: UUID) throws -> URL {
        let folder = try directory("Exports").appendingPathComponent(id.uuidString, isDirectory: true)
        if files.fileExists(atPath: folder.path),
           try folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            throw ExportError.invalidRequest
        }
        return folder
    }

    func frozenExport(_ id: UUID) throws -> FrozenExport {
        let folder = try exportDirectory(id)
        let manifest = try decoder.decode(ExportManifest.self,
            from: Data(contentsOf: folder.appendingPathComponent("request.json")))
        guard manifest.version == 1, manifest.jobID == id else { throw ExportError.invalidRequest }
        try manifest.document.validate()
        var urls: [UUID: URL] = [:]
        for asset in manifest.document.assets where manifest.profile.format == .mp4 {
            let ext = URL(fileURLWithPath: asset.relativeOriginalPath).pathExtension
            urls[asset.id] = folder.appendingPathComponent("Media", isDirectory: true)
                .appendingPathComponent(asset.id.uuidString + "." + ext)
        }
        return FrozenExport(manifest: manifest, directory: folder, urls: urls)
    }

    func removeExportPartial(_ id: UUID) throws {
        let folder = try exportDirectory(id)
        for ext in ["mp4", "srt"] {
            let url = folder.appendingPathComponent("partial." + ext)
            if files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
        }
    }

    func publishExport(_ id: UUID) throws {
        let request = try frozenExport(id)
        // Same-volume rename publishes only a finalized, validated file. Result
        // names live apart from working files, including a title of "partial".
        if !files.fileExists(atPath: request.outputURL.path) {
            try Task.checkCancellation()
            try files.moveItem(at: request.partialURL, to: request.outputURL)
        }
        let media = request.directory.appendingPathComponent("Media", isDirectory: true)
        if files.fileExists(atPath: media.path) { try files.removeItem(at: media) }
        try removeExportPartial(id)
    }

    func discardExport(_ id: UUID) throws {
        let folder = try exportDirectory(id)
        if files.fileExists(atPath: folder.path) { try files.removeItem(at: folder) }
    }

    /// Queue publication can be interrupted after staging but before enqueue.
    /// Retain only the one durable job; never touch project originals/cache.
    func removeOrphanedExports(keeping ids: Set<UUID>) throws {
        for folder in try files.contentsOfDirectory(at: directory("Exports"), includingPropertiesForKeys: nil) {
            if let id = UUID(uuidString: folder.lastPathComponent), !ids.contains(id) { try discardExport(id) }
        }
    }

    func thumbnailURL(id: UUID) throws -> URL {
        var cache = try directory("Cache").appendingPathComponent("Thumbnails", isDirectory: true)
        try files.createDirectory(at: cache, withIntermediateDirectories: true)
        var properties = URLResourceValues()
        properties.isExcludedFromBackup = true
        try? cache.setResourceValues(properties)
        return cache.appendingPathComponent(id.uuidString + ".jpg")
    }

    func purgeDerivedCache() throws {
        let cache = try directory("Cache")
        let items = try files.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)
        for item in items { try files.removeItem(at: item) }
    }

    struct StorageUsage: Sendable {
        let projectBytes: Int64
        let cacheBytes: Int64
        let pendingBytes: Int64
        let trashBytes: Int64
        let exportBytes: Int64
    }

    func storageUsage() throws -> StorageUsage {
        StorageUsage(projectBytes: try folderSize(try directory("Projects")),
                     cacheBytes: try folderSize(try directory("Cache")),
                     pendingBytes: try folderSize(try directory("Pending")),
                     trashBytes: try folderSize(try directory("Trash")),
                     exportBytes: try folderSize(try directory("Exports")))
    }

    private func folderSize(_ root: URL) throws -> Int64 {
        guard let walker = files.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey],
                                           options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { walker.skipDescendants(); continue }
            if values.isRegularFile == true { total += Int64(values.fileSize ?? 0) }
        }
        return total
    }

    private func originalsExist(of project: ProjectDocument, in folder: URL) throws -> Bool {
        for asset in project.assets {
            let url = try OwnedPath.secureURL(for: asset.relativeOriginalPath,
                                                 base: "Originals", in: folder)
            guard files.fileExists(atPath: url.path) else { return false }
        }
        return true
    }

    private func verifyOriginals(of document: ProjectDocument, in folder: URL) throws {
        for asset in document.assets {
            let url = try OwnedPath.secureURL(for: asset.relativeOriginalPath,
                                                 base: "Originals", in: folder)
            guard files.fileExists(atPath: url.path) else {
                throw ProjectStoreError.missingOriginal(asset.displayName)
            }
            let attributes = try files.attributesOfItem(atPath: url.path)
            guard (attributes[.size] as? NSNumber)?.int64Value == asset.byteCount else {
                throw ProjectStoreError.invalidDocument("Original media file size changed")
            }
        }
    }
}
