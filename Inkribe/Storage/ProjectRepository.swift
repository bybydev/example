import InkribeCore
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

    private func packageStore() throws -> ProjectPackageStore<ProjectDocument> {
        ProjectPackageStore(rootURL: try root())
    }

    private func directory(_ name: String) throws -> URL {
        try packageStore().directory(name)
    }

    private func projectDirectory(_ id: UUID) throws -> URL {
        try packageStore().packageURL(for: id)
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
        _ = try packageStore().commitNew(document, stagedAt: staging)
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
                           clearingEmptyRecognitionID: UUID? = nil,
                           appendingRecognitionID: UUID? = nil) throws -> ProjectDocument {
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
        if let raw = current.recognition, !clearsEmptyRecognition, raw.id != appendingRecognitionID {
            guard let proposed = next.recognition, proposed.id == raw.id,
                  proposed.rawWindows == raw.rawWindows, proposed.modelID == raw.modelID,
                  proposed.modelSHA256 == raw.modelSHA256,
                  proposed.requestedLanguageCode == raw.requestedLanguageCode,
                  proposed.completedAt == raw.completedAt, proposed.progress == raw.progress else {
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
        try packageStore().save(next, replacing: current)
        return next
    }

    /// Only append-only inference publication may be rebased. Concurrent user
    /// edits from another owner still fail instead of being silently overwritten.
    func commitEditorEdit(_ proposed: ProjectDocument, basedOn base: ProjectDocument) throws -> ProjectDocument {
        let current = try open(proposed.id)
        if current.contentRevision == base.contentRevision {
            guard try encoder.encode(current) == encoder.encode(base) else {
                throw ProjectStoreError.invalidDocument("The saved project changed outside this editor. Your latest changes are still open in Inkribe.")
            }
            return try commitEdit(proposed, expectedRevision: base.contentRevision)
        }
        guard current.isSpeechPublication(since: base) else {
            throw ProjectStoreError.staleRevision(expected: base.contentRevision, actual: current.contentRevision)
        }
        var merged = proposed
        merged.recognition = try current.recognition?.keepingEdits(from: proposed.recognition)
        return try commitEdit(merged, expectedRevision: current.contentRevision)
    }

    /// Successful windows are immediately usable/editable on the video. This
    /// repository transaction appends new units and preserves every existing edit.
    /// Also exposes compatible work retained by the earlier complete-only build,
    /// without loading a model or repeating inference when the editor opens.
    func restoreRetainedCaptions(projectID: UUID) throws -> ProjectDocument {
        let project = try open(projectID)
        guard project.recognition == nil, let checkpoint = try readSpeechCheckpoint(projectID),
              checkpoint.projectID == projectID, checkpoint.revision == project.contentRevision,
              checkpoint.assets == project.assets, checkpoint.clips == project.clips,
              checkpoint.usesCurrentModelAndRuntime else { return project }
        try checkpoint.validate(recheckingMapping: true)
        return try publishSpeechProgress(checkpoint, chargeOnCompletion: true)
    }

    /// Append accepted source units into the latest saved manual edits.
    func publishSpeechProgress(_ checkpoint: SpeechCheckpoint,
                               chargeOnCompletion: Bool) throws -> ProjectDocument {
        try Task.checkCancellation()
        var current = try open(checkpoint.projectID)
        guard current.assets == checkpoint.assets, current.clips == checkpoint.clips else {
            throw ProjectStoreError.invalidDocument("Transcription source graph changed")
        }
        if let existing = current.recognition {
            guard existing.id == checkpoint.jobID else { throw SpeechError.alreadyTranscribed }
            if !existing.isIncomplete {
                if chargeOnCompletion { try finishSpeechAllowance(existing.id) }
                return current
            }
        }
        guard let result = try checkpoint.publication(merging: current.recognition) else { return current }
        try result.validate(clips: current.clips, assets: current.assets)
        if current.recognition != result {
            let revision = current.contentRevision
            let existingID = current.recognition?.id
            current.recognition = result
            current = try writeEdit(current, expectedRevision: revision, appendingRecognitionID: existingID)
        }
        if chargeOnCompletion, !result.isIncomplete { try finishSpeechAllowance(result.id) }
        return current
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

    /// Fixed sidecar inside the project: moves with Trash, is included in storage
    /// accounting, is not derived cache, and is never copied by duplicate().
    private func speechCheckpointURL(_ projectID: UUID) throws -> URL {
        let package = try projectDirectory(projectID)
        return try packageStore().file(ProjectPackageLayout.checkpointName, in: package)
    }

    private func readSpeechCheckpoint(_ projectID: UUID) throws -> SpeechCheckpoint? {
        let url = try speechCheckpointURL(projectID)
        guard files.fileExists(atPath: url.path) else { return nil }
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw SpeechRecoveryError.corrupt
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        guard let data = try file.read(upToCount: SpeechCheckpoint.maximumBytes + 1),
              data.count <= SpeechCheckpoint.maximumBytes else { throw SpeechRecoveryError.tooLarge }
        do {
            let value = try decoder.decode(SpeechCheckpoint.self, from: data)
            guard value.projectID == projectID else { throw SpeechRecoveryError.corrupt }
            try value.validate()
            return value
        } catch let error as SpeechRecoveryError { throw error }
        catch { throw SpeechRecoveryError.corrupt }
    }

    func loadSpeechCheckpoint(matching fresh: SpeechCheckpoint) throws -> SpeechCheckpoint {
        let project = try open(fresh.projectID)
        guard project.recognition == nil ||
                (project.recognition?.id == fresh.jobID && project.recognition?.isIncomplete == true) else {
            throw SpeechError.alreadyTranscribed
        }
        guard project.contentRevision == fresh.revision else {
            throw ProjectStoreError.staleRevision(expected: fresh.revision, actual: project.contentRevision)
        }
        var seeded = try fresh.seeded(from: project.recognition)
        guard let saved = try readSpeechCheckpoint(fresh.projectID),
              saved.matches(fresh) || (project.recognition?.isIncomplete == true && saved.matchesInputs(fresh)) else { return seeded }
        do { try saved.validate(recheckingMapping: true) }
        catch let error as SpeechRecoveryError { throw error }
        catch { throw SpeechRecoveryError.corrupt }
        var entries = Dictionary(uniqueKeysWithValues: saved.entries.map { ($0.index, $0) })
        for entry in seeded.entries {
            if let prior = entries[entry.index], prior != entry { throw SpeechRecoveryError.corrupt }
            entries[entry.index] = entry
        }
        seeded.entries = entries.values.sorted { $0.index < $1.index }
        return seeded
    }

    func saveSpeechCheckpoint(_ checkpoint: SpeechCheckpoint) throws -> SpeechCheckpoint {
        try Task.checkCancellation()
        var value = checkpoint
        let project = try open(value.projectID)
        guard project.recognition == nil ||
                (project.recognition?.id == value.jobID && project.recognition?.isIncomplete == true) else {
            throw SpeechError.alreadyTranscribed
        }
        guard project.assets == value.assets, project.clips == value.clips else {
            throw ProjectStoreError.invalidDocument("Transcription source graph changed")
        }
        value.revision = project.contentRevision
        try value.validate()
        let data = try encoder.encode(value)
        guard data.count <= SpeechCheckpoint.maximumBytes else { throw SpeechRecoveryError.tooLarge }
        try data.write(to: speechCheckpointURL(value.projectID), options: .atomic)
        return value
    }

    func speechRecovery(projectID: UUID) throws -> SpeechRecoverySummary? {
        let project = try open(projectID)
        guard project.recognition?.isIncomplete != false else { return nil }
        guard let value = try readSpeechCheckpoint(projectID) else {
            guard let recognition = project.recognition, let progress = recognition.progress else { return nil }
            let plan = try SpeechCheckpoint.plan(clips: project.clips, assets: project.assets)
            let resolved = Set(progress.resolved.map(\.index))
            let unresolved = plan.filter { !resolved.contains($0.index) }.map { window in
                SpeechRecoverySummary.Unresolved(id: window.index,
                    clipNumber: (project.clips.firstIndex { $0.id == window.clip.id } ?? 0) + 1,
                    source: window.core, reason: "Needs transcription")
            }
            return SpeechRecoverySummary(jobID: recognition.id, reusableRevision: true,
                compatibleRuntime: SpeechCheckpoint.usesCurrentModelAndRuntime(modelID: recognition.modelID,
                    hash: recognition.modelSHA256, revision: progress.runtimeRevision),
                resolved: resolved.count, total: plan.count,
                words: recognition.words.count, modelID: recognition.modelID,
                language: recognition.requestedLanguageCode, unresolved: unresolved)
        }
        let plan = try SpeechCheckpoint.plan(clips: value.clips, assets: value.assets)
        let entries = Dictionary(uniqueKeysWithValues: value.entries.map { ($0.index, $0) })
        let unresolved = plan.compactMap { window -> SpeechRecoverySummary.Unresolved? in
            let entry = entries[window.index]
            guard entry == nil || entry?.failure != nil else { return nil }
            return .init(id: window.index,
                clipNumber: (value.clips.firstIndex(where: { $0.id == window.clip.id }) ?? 0) + 1,
                source: window.core, reason: entry?.failure?.description ?? "Not processed yet")
        }
        return SpeechRecoverySummary(jobID: value.jobID,
            reusableRevision: (value.revision == project.contentRevision || project.recognition?.id == value.jobID) &&
                value.assets == project.assets && value.clips == project.clips,
            compatibleRuntime: value.usesCurrentModelAndRuntime,
            resolved: plan.count - unresolved.count, total: plan.count, words: value.wordCount,
            modelID: value.modelID, language: value.language, unresolved: unresolved)
    }

    /// Explicit user action only, while the controller excludes active jobs.
    /// Does not clear recognition, refund usage or mutate the project revision.
    func discardSpeechCheckpoint(projectID: UUID, expectedRevision: UInt64) throws {
        let project = try open(projectID)
        guard project.contentRevision == expectedRevision else {
            throw ProjectStoreError.staleRevision(expected: expectedRevision, actual: project.contentRevision)
        }
        guard project.recognition?.isIncomplete != false else { throw SpeechError.alreadyTranscribed }
        let url = try speechCheckpointURL(projectID)
        if files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
    }

    /// Cleanup after publication is optional. A leftover checkpoint is ignored
    /// once recognition exists, so a cleanup failure cannot undo saved captions.
    func removePublishedSpeechCheckpoint(projectID: UUID, recognitionID: UUID) throws {
        let recognition = try open(projectID).recognition
        guard recognition?.id == recognitionID, recognition?.isIncomplete == false else { return }
        let url = try speechCheckpointURL(projectID)
        if files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
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
        let package = try projectDirectory(projectID)
        let folder = try packageStore().file("RecognitionRecovery", in: package)
        if !files.fileExists(atPath: folder.path) {
            try files.createDirectory(at: folder, withIntermediateDirectories: false)
        }
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
        let store = try packageStore()
        if try store.contains(reservation.projectID, in: .projects),
           try store.contains(reservation.projectID, in: .trash) {
            throw ProjectStoreError.packageConflict(reservation.projectID)
        }
        for location in [ProjectPackageLocation.projects, .trash] {
            guard try store.contains(reservation.projectID, in: location) else { continue }
            let document = try store.load(reservation.projectID, in: location)
            return document.recognition.map { $0.id == reservation.jobID && !$0.words.isEmpty && !$0.isIncomplete } ?? false
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
        guard project.contentRevision == revision,
              project.recognition == nil || (project.recognition?.id == jobID && project.recognition?.isIncomplete == true) else {
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
        try packageStore().load(id)
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
        try OwnedPath.validate(asset.relativeOriginalPath, base: ProjectPackageLayout.originalsName)
        let url = try packageStore().file(asset.relativeOriginalPath, in: projectDirectory(projectID))
        guard files.fileExists(atPath: url.path) else {
            throw ProjectStoreError.missingOriginal(asset.displayName)
        }
        let attributes = try files.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value == asset.byteCount else {
            throw ProjectStoreError.invalidDocument("Original media file size changed: " + asset.displayName)
        }
        return url
    }

    func list(titleQuery: String = "", sort: LibrarySort = .recent,
              filter: LibraryFilter = .all) throws -> LibrarySnapshot {
        let identities = try packageStore().identities()
        var projects: [ProjectSummary] = []
        var issues: [LibraryIssue] = []
        for id in identities {
            do {
                let document = try open(id)
                let package = try projectDirectory(id)
                let available = (try? originalsExist(of: document, in: package)) ?? false
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
                    captionState = recognition.words.isEmpty ? .emptyResult : recognition.isIncomplete ? .incomplete : .saved
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
                if !available { issues.append(LibraryIssue(id: id, description: "Original media is missing or changed")) }
            } catch {
                issues.append(LibraryIssue(id: id, description: error.localizedDescription))
            }
        }
        switch sort {
        case .recent: projects.sort { $0.updatedAt > $1.updatedAt }
        case .oldest: projects.sort { $0.updatedAt < $1.updatedAt }
        case .title: projects.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
        let combined = Dictionary(grouping: issues, by: \.id).map { id, values in
            LibraryIssue(id: id, description: values.map(\.description).joined(separator: "\n"))
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        return LibrarySnapshot(projects: projects, issues: combined)
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
                captionStyle: original.captionStyle, mediaEdits: original.mediaEdits,
                clipSettings: original.clipSettings?.compactMap { settings in
                    guard let id = clipMapping[settings.id] else { return nil }
                    var copy = settings; copy.id = id; return copy
                })
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
        try packageStore().move(id, from: .projects, to: .trash)
        let thumbnail = try thumbnailURL(id: id)
        try? files.removeItem(at: thumbnail)
    }

    func restoreFromTrash(_ id: UUID) throws {
        try packageStore().move(id, from: .trash, to: .projects)
    }

    /// Recovery shares the package publication path and excludes live imports.
    func recoverCommittedStaging() throws -> [UUID] {
        try packageStore().recoverCommittedStaging(excluding: activeStaging)
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
        let issue: String?
    }

    func trashedProjects() throws -> [TrashedProject] {
        let store = try packageStore()
        return try store.identities(in: .trash).map { id in
            do {
                let document = try store.load(id, in: .trash)
                return TrashedProject(id: id, title: document.title, issue: nil)
            } catch {
                // Corrupt/future packages stay visible instead of disappearing
                // from storage management or being silently reset/restored.
                return TrashedProject(id: id, title: "Project " + String(id.uuidString.prefix(8)),
                                      issue: error.localizedDescription)
            }
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Explicitly destructive action, called only after user confirmation.
    func emptyTrash() throws {
        try settlePublishedSpeechAllowance()
        let store = try packageStore()
        for id in try store.identities(in: .trash) { try store.removeFromTrash(id) }
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
        try OwnedPath.validate(source.relativeOriginalPath, base: ProjectPackageLayout.originalsName)
        let destination = try packageStore().file(source.relativeOriginalPath, in: projectDirectory(projectID))
        guard !files.fileExists(atPath: destination.path) else {
            throw ProjectStoreError.invalidDocument("The original still exists; it was not replaced")
        }
        guard externalURL.isFileURL else { throw ProjectStoreError.unsupportedURL }
        // Relink can reconstruct the missing Originals directory, but never
        // recreate the package itself or traverse a symlinked parent.
        let package = try projectDirectory(projectID)
        let originals = try packageStore().file(ProjectPackageLayout.originalsName, in: package)
        if !files.fileExists(atPath: originals.path) {
            try files.createDirectory(at: originals, withIntermediateDirectories: false)
        }
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
        guard try retainedExportIDs().count < ExportController.retainedRecordLimit else { throw ProcessingError.retentionFull }
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
            let manifest = ExportManifest(version: 1, jobID: id, document: saved, profile: profile, createdAt: Date())
            let metadata = try encoder.encode(manifest)
            guard metadata.count <= 256 * 1024 * 1024 else { throw ProjectStoreError.oversizedProjectMetadata }
            try metadata.write(to: folder.appendingPathComponent("request.json"), options: .atomic)
        } catch {
            try? files.removeItem(at: folder)
            throw error
        }
    }

    private func exportDirectory(_ id: UUID) throws -> URL {
        let parent = try directory("Exports")
        let matches = try files.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) == id }
        guard matches.count <= 1 else { throw ExportError.invalidRequest }
        let folder = matches.first ?? parent.appendingPathComponent(id.uuidString, isDirectory: true)
        if files.fileExists(atPath: folder.path) {
            let values = try folder.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isSymbolicLink != true, values.isDirectory == true else { throw ExportError.invalidRequest }
        }
        return folder
    }

    func frozenExport(_ id: UUID) throws -> FrozenExport {
        let folder = try exportDirectory(id)
        let store = try packageStore()
        let metadata = try store.file("request.json", in: folder)
        let values = try metadata.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize,
              size <= 256 * 1024 * 1024 else { throw ExportError.invalidRequest }
        let input = try FileHandle(forReadingFrom: metadata)
        defer { try? input.close() }
        var data = Data()
        let limit = 256 * 1024 * 1024
        while let part = try input.read(upToCount: min(1_048_576, limit + 1 - data.count)), !part.isEmpty {
            data.append(part)
            guard data.count <= limit else { throw ProjectStoreError.oversizedProjectMetadata }
        }
        let manifest = try decoder.decode(ExportManifest.self, from: data)
        guard manifest.version == 1, manifest.jobID == id else { throw ExportError.invalidRequest }
        try manifest.document.validate()
        var urls: [UUID: URL] = [:]
        for asset in manifest.document.assets where manifest.profile.format == .mp4 {
            let ext = URL(fileURLWithPath: asset.relativeOriginalPath).pathExtension
            urls[asset.id] = try store.file("Media/" + asset.id.uuidString + "." + ext, in: folder)
        }
        let result = FrozenExport(manifest: manifest, directory: folder, urls: urls)
        _ = try store.file("Result/" + result.outputURL.lastPathComponent, in: folder)
        _ = try store.file("partial." + manifest.profile.format.rawValue, in: folder)
        return result
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

    /// Disk inventory is independent of queue metadata. Never auto-delete an
    /// unrepresented result: it can be the survivor of a queue recovery/crash.
    private func retainedExportIDs() throws -> [UUID] {
        let ids = try files.contentsOfDirectory(at: directory("Exports"), includingPropertiesForKeys: nil)
            .compactMap { UUID(uuidString: $0.lastPathComponent) }
        return Set(ids).sorted { $0.uuidString < $1.uuidString }
    }

    func exportArtifacts() throws -> [ExportArtifact] {
        try retainedExportIDs().map { id in
            do {
                let request = try frozenExport(id)
                let bytes = try folderSize(request.directory)
                let values = try? request.outputURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                let available = values?.isRegularFile == true && values?.isSymbolicLink != true && (values?.fileSize ?? 0) > 0
                return ExportArtifact(id: id, projectID: request.manifest.document.id,
                    title: request.manifest.document.title, revision: request.manifest.document.contentRevision,
                    profile: request.manifest.profile, outputURL: available ? request.outputURL : nil,
                    bytes: bytes, issue: nil,
                    createdAt: request.manifest.createdAt ?? (try? request.directory.appendingPathComponent("request.json").resourceValues(forKeys: [.creationDateKey]).creationDate),
                    duration: request.manifest.document.outputDuration, outputBytes: (values?.fileSize).map { Int64($0) })
            } catch {
                return ExportArtifact(id: id, projectID: nil, title: "Unreadable export " + id.uuidString.prefix(8),
                    revision: nil, profile: nil, outputURL: nil,
                    bytes: (try? folderSize(exportDirectory(id))) ?? 0, issue: error.localizedDescription,
                    createdAt: nil, duration: nil, outputBytes: nil)
            }
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

    /// Publish a derived preview only while its original project/source still
    /// exists. A late image task cannot resurrect cache for a trashed project.
    func publishThumbnail(_ data: Data, projectID: UUID, assetID: UUID, sourceHash: String) throws -> URL {
        let project = try open(projectID)
        guard project.assets.contains(where: { $0.id == assetID && $0.sha256 == sourceHash }) else {
            throw ProjectStoreError.invalidDocument("The preview source changed")
        }
        _ = try sourceURL(projectID: projectID, assetID: assetID)
        let url = try thumbnailURL(id: projectID)
        try data.write(to: url, options: .atomic)
        return url
    }

    func purgeDerivedCache() throws {
        let cache = try directory("Cache")
        let items = try files.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)
        for item in items { try files.removeItem(at: item) }
    }

    struct ProjectStorageUsage: Identifiable, Sendable {
        let id: UUID
        let title: String
        let bytes: ProjectPackageStorage
    }

    struct StorageUsage: Sendable {
        let projectBytes: Int64
        let cacheBytes: Int64
        let pendingBytes: Int64
        let trashBytes: Int64
        let exportBytes: Int64
        let projects: [ProjectStorageUsage]
        let issues: [LibraryIssue]
    }

    func storageUsage() throws -> StorageUsage {
        let store = try packageStore()
        var projects: [ProjectStorageUsage] = []
        var issues: [LibraryIssue] = []
        for id in try store.identities() {
            do {
                let document = try store.load(id)
                let usage = try store.storage(of: id)
                projects.append(ProjectStorageUsage(id: id, title: document.title, bytes: usage))
            } catch {
                // Keep aggregate bytes and report the failed breakdown instead
                // of hiding damaged/future packages from storage management.
                issues.append(LibraryIssue(id: id, description: error.localizedDescription))
            }
        }
        projects.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return StorageUsage(projectBytes: try folderSize(try directory("Projects")),
                            cacheBytes: try folderSize(try directory("Cache")),
                            pendingBytes: try folderSize(try directory("Pending")),
                            trashBytes: try folderSize(try directory("Trash")),
                            exportBytes: try folderSize(try directory("Exports")),
                            projects: projects, issues: issues)
    }

    private func folderSize(_ root: URL) throws -> Int64 {
        try ProjectStorageScanner.byteCount(at: root)
    }

    private func originalsExist(of project: ProjectDocument, in folder: URL) throws -> Bool {
        for asset in project.assets {
            try OwnedPath.validate(asset.relativeOriginalPath, base: ProjectPackageLayout.originalsName)
            let url = try packageStore().file(asset.relativeOriginalPath, in: folder)
            guard files.fileExists(atPath: url.path) else { return false }
            let attributes = try files.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? NSNumber)?.int64Value == asset.byteCount else { return false }
        }
        return true
    }

}
