@preconcurrency import AVFoundation
import Foundation
import Observation

/// A single owner for the working document, save revision, undo, selection and playback.
@MainActor
@Observable
final class IOSEditorSession {
    let projectID: UUID
    let player = AVPlayer()
    private(set) var document: IOSProjectDocument?
    private(set) var snapshot: IOSCaptionSnapshot?
    private(set) var originalAvailable: [UUID: Bool] = [:]
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var isPreparingPreview = false
    private(set) var isPlaying = false
    private(set) var time = MediaTime.zero
    private(set) var selectedCueID: UUID?
    private(set) var selectedWordID: UUID?
    private(set) var saveError: String?
    private(set) var loadError: String?
    private(set) var previewError: String?
    var commandError: String?
    private(set) var hasPendingChanges = false
    private(set) var canUndo = false
    private(set) var canRedo = false
    private let repository = IOSProjectRepository.shared
    private var isPresented = false
    private var committedRevision: UInt64 = 0
    private var editSequence: UInt64 = 0
    private var savedSequence: UInt64 = 0
    private var loadGeneration = UUID()
    private var seekGeneration = UUID()
    private var playbackGeneration = UUID()
    private var isSeeking = false
    private var typingWordID: UUID?
    private var stylingControl: IOSCaptionStyleControl?
    private var past: [History] = []
    private var future: [History] = []
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var writer: Task<Void, Never>?
    @ObservationIgnored private var periodicObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var statusObserver: NSKeyValueObservation?
    @ObservationIgnored private var preparedMedia: MediaKey?

    private struct Selection { let cue: UUID?; let word: UUID? }
    private struct History {
        var change: HistoryChange
        let selectionBefore: Selection
        var selectionAfter: Selection
    }
    private enum HistoryChange {
        case caption(IOSCaptionEditPatch)
        case style(before: IOSCaptionStyle?, after: IOSCaptionStyle?)

        var estimatedBytes: Int {
            switch self {
            case .caption(let patch): patch.estimatedBytes
            case .style: MemoryLayout<IOSCaptionStyle>.stride * 2
            }
        }
        mutating func coalesceText(_ next: IOSCaptionEditPatch) -> Bool {
            guard case .caption(var patch) = self, patch.coalesceText(next) else { return false }
            self = .caption(patch)
            return true
        }
        mutating func coalesceStyle(from previous: IOSCaptionStyle?, to next: IOSCaptionStyle) -> Bool {
            guard case .style(let before, let after) = self, after == previous else { return false }
            self = .style(before: before, after: next)
            return true
        }
    }
    private struct MediaKey: Equatable {
        let clips: [IOSProjectClip]
        let canvas: IOSCanvas
        let urls: [UUID: URL]
    }

    init(projectID: UUID) { self.projectID = projectID }
    var duration: MediaTime { document?.clips.map(\.timelineInterval.end).max() ?? .zero }
    var presentation: IOSCaptionPresentation? { snapshot?.evaluate(at: time) }
    var selectedCue: IOSCaptionCue? { snapshot?.cues.first { $0.id == selectedCueID } }
    var selectedWord: IOSCaptionWord? { selectedWordID.flatMap { snapshot?.wordsByID[$0] } }
    var undoLabel: String { "Undo edit" }
    var redoLabel: String { "Redo edit" }

    func open() async {
        isPresented = true
        observeTimeIfNeeded()
        if document == nil || preparedMedia == nil { await readSaved() }
    }

    /// Call after an external result/relink; never throw away a dirty editor draft.
    func refreshSaved() async {
        await flush()
        guard isPresented, !hasPendingChanges else { return }
        await readSaved()
    }

    func reloadDiscardingDraft() async {
        debounce?.cancel()
        if let writer { await writer.value }
        await readSaved(discardDraft: true)
    }

    private func readSaved(discardDraft: Bool = false) async {
        guard isPresented else { return }
        let generation = UUID()
        loadGeneration = generation
        let sequence = editSequence
        isLoading = true
        loadError = nil
        defer { if loadGeneration == generation { isLoading = false } }
        do {
            let loaded = try await repository.open(projectID)
            guard generation == loadGeneration, sequence == editSequence else { return }
            if discardDraft || document == nil || loaded.contentRevision != committedRevision {
                document = loaded
                committedRevision = loaded.contentRevision
                savedSequence = editSequence
                hasPendingChanges = false
                saveError = nil
                past.removeAll(); future.removeAll(); updateHistoryFlags()
                rebuildSnapshot()
                repairSelection()
            }
            var urls: [UUID: URL] = [:]
            for asset in loaded.assets {
                if let url = try? await repository.sourceURL(projectID: projectID, assetID: asset.id) {
                    urls[asset.id] = url
                }
            }
            guard generation == loadGeneration else { return }
            originalAvailable = Dictionary(uniqueKeysWithValues: loaded.assets.map { ($0.id, urls[$0.id] != nil) })
            await preparePreview(document: loaded, urls: urls, generation: generation)
        } catch {
            guard generation == loadGeneration else { return }
            loadError = error.localizedDescription
        }
    }

    func setTitle(_ value: String) {
        guard var next = document, next.title != value else { return }
        next.title = value
        document = next
        changed()
    }

    func selectCue(_ id: UUID) {
        pause()
        typingWordID = nil
        stylingControl = nil
        selectedCueID = id
        selectedWordID = snapshot?.cues.first { $0.id == id }?.wordIDs.first
        if let cue = selectedCue { seek(to: cue.interval.start) }
    }

    func selectWord(_ id: UUID) {
        pause()
        typingWordID = nil
        stylingControl = nil
        selectedWordID = id
        if let word = snapshot?.wordsByID[id] { seek(to: word.projectInterval.start) }
    }

    func beginTyping() { pause() }
    func endTyping() { typingWordID = nil }
    func endStyleEditing() { stylingControl = nil }

    func setCaptionStyle(_ style: IOSCaptionStyle, coalescing control: IOSCaptionStyleControl? = nil) {
        guard var project = document, style != project.effectiveCaptionStyle else { return }
        let before = project.captionStyle
        do {
            project.schemaVersion = IOSProjectSchema.current
            project.captionStyle = style
            try project.validate()
            let selection = Selection(cue: selectedCueID, word: selectedWordID)
            if let control, control == stylingControl, !past.isEmpty, future.isEmpty,
               past[past.count - 1].change.coalesceStyle(from: before, to: style) {
                past[past.count - 1].selectionAfter = selection
            } else {
                past.append(History(change: .style(before: before, after: style),
                    selectionBefore: selection, selectionAfter: selection))
            }
            document = project
            stylingControl = control
            typingWordID = nil
            finishHistoryEdit()
            rebuildSnapshot()
            commandError = nil
            changed()
        } catch { commandError = error.localizedDescription }
    }

    func editText(wordID: UUID, value: String) {
        perform(coalescing: wordID) { state, _ in
            try IOSCaptionEdits.text(value, wordID: wordID, in: &state)
            return nil
        }
    }

    func retimeCue(_ interval: MediaInterval) {
        guard let id = selectedCueID else { return }
        perform { state, project in
            try IOSCaptionEdits.cueTiming(interval, cueID: id, project: project, in: &state)
            return nil
        }
    }
    func retimeWord(_ interval: MediaInterval) {
        guard let id = selectedWordID else { return }
        perform { state, project in
            try IOSCaptionEdits.wordTiming(interval, wordID: id, project: project, in: &state)
            return nil
        }
    }
    func split() {
        guard let cue = selectedCueID, let word = selectedWordID else { return }
        perform { state, _ in try IOSCaptionEdits.split(cueID: cue, before: word, in: &state) }
    }
    func mergeNext() {
        guard let id = selectedCueID else { return }
        perform { state, _ in try IOSCaptionEdits.mergeNext(cueID: id, in: &state); return nil }
    }

    private func perform(coalescing wordID: UUID? = nil,
                         _ edit: (inout IOSCaptionEditState, IOSProjectDocument) throws -> UUID?) {
        guard var project = document, let result = project.recognition else { return }
        pause()
        stylingControl = nil
        let before = IOSCaptionEditState(result)
        var after = before
        let selection = Selection(cue: selectedCueID, word: selectedWordID)
        do {
            let newCue = try edit(&after, project)
            guard after != before else { return }
            project.schemaVersion = IOSProjectSchema.current
            project.recognition = after.applying(to: result)
            try project.validate()
            document = project
            if let newCue { selectedCueID = newCue }
            rebuildSnapshot()
            repairSelection()
            let finalSelection = Selection(cue: selectedCueID, word: selectedWordID)
            let patch = IOSCaptionEditPatch(before: before, after: after)
            if let wordID, typingWordID == wordID, !past.isEmpty, future.isEmpty,
               past[past.count - 1].change.coalesceText(patch) {
                past[past.count - 1].selectionAfter = finalSelection
            } else {
                past.append(History(change: .caption(patch), selectionBefore: selection, selectionAfter: finalSelection))
            }
            typingWordID = wordID
            finishHistoryEdit()
            commandError = nil
            changed()
        } catch { commandError = error.localizedDescription }
    }

    func undo() {
        guard let history = past.last else { return }
        if restore(history.change, forward: false, selection: history.selectionBefore) {
            past.removeLast(); future.append(history); updateHistoryFlags()
        }
    }
    func redo() {
        guard let history = future.last else { return }
        if restore(history.change, forward: true, selection: history.selectionAfter) {
            future.removeLast(); past.append(history); updateHistoryFlags()
        }
    }
    private func restore(_ change: HistoryChange, forward: Bool, selection: Selection) -> Bool {
        guard var project = document else { return false }
        do {
            switch change {
            case .caption(let patch):
                guard let result = project.recognition else { throw IOSCaptionEditError.missingCaption }
                let state = try patch.applying(to: IOSCaptionEditState(result), forward: forward)
                project.recognition = state.applying(to: result)
            case .style(let before, let after):
                guard project.captionStyle == (forward ? before : after) else { throw IOSCaptionEditError.missingCaption }
                project.captionStyle = forward ? after : before
            }
            project.schemaVersion = IOSProjectSchema.current
            try project.validate()
            pause(); typingWordID = nil; stylingControl = nil
            document = project
            selectedCueID = selection.cue; selectedWordID = selection.word
            rebuildSnapshot(); repairSelection(); changed()
            return true
        } catch { commandError = error.localizedDescription; return false }
    }
    private func finishHistoryEdit() {
        // Keep one oversized command undoable; otherwise bound count and estimated payload.
        while past.count > 1 && (past.count > 50 || past.reduce(0, { $0 + $1.change.estimatedBytes }) > 8 * 1_024 * 1_024) {
            past.removeFirst()
        }
        future.removeAll()
        updateHistoryFlags()
    }
    private func updateHistoryFlags() { canUndo = !past.isEmpty; canRedo = !future.isEmpty }
    private func rebuildSnapshot() { snapshot = document.map(IOSCaptionSnapshot.init) }
    private func repairSelection() {
        if snapshot?.cues.contains(where: { $0.id == selectedCueID }) != true {
            selectedCueID = snapshot?.cues.first?.id
        }
        if selectedCue?.wordIDs.contains(where: { $0 == selectedWordID }) != true {
            selectedWordID = selectedCue?.wordIDs.first
        }
    }

    private func changed() {
        editSequence += 1
        hasPendingChanges = true
        debounce?.cancel()
        debounce = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            await self?.flush()
        }
    }

    /// One writer drains the newest complete draft. Returned metadata never replaces newer text.
    /// Once a write starts, debounce cancellation cannot cancel it.
    func flush() async {
        debounce?.cancel(); debounce = nil
        if let writer { await writer.value; return }
        guard hasPendingChanges else { return }
        isSaving = true
        let task = Task { await drainSaves() }
        writer = task
        await task.value
    }
    /// Later style/export adapters freeze this value only after the latest draft is durable.
    func savedDocument() async throws -> IOSProjectDocument {
        await flush()
        guard !hasPendingChanges else { throw IOSCaptionEditError.unsavedChanges }
        guard let document else { throw IOSProjectStoreError.missingProject(projectID) }
        return document
    }

    private func drainSaves() async {
        defer { isSaving = false; writer = nil }
        while savedSequence != editSequence, let proposed = document {
            let capturedSequence = editSequence
            do {
                let saved = try await repository.commitEdit(proposed, expectedRevision: committedRevision)
                committedRevision = saved.contentRevision
                savedSequence = capturedSequence
                if var latest = document {
                    latest.contentRevision = saved.contentRevision
                    latest.updatedAt = saved.updatedAt
                    latest.schemaVersion = saved.schemaVersion
                    document = latest
                }
                hasPendingChanges = savedSequence != editSequence
                saveError = nil
                rebuildSnapshot()
            } catch {
                saveError = error.localizedDescription
                hasPendingChanges = true
                return // Preserve draft/history; never blindly rebase over someone else's saved revision.
            }
        }
    }

    func retryPreview() async {
        preparedMedia = nil
        await refreshSaved()
    }

    private func preparePreview(document: IOSProjectDocument, urls: [UUID: URL], generation: UUID) async {
        let key = MediaKey(clips: document.clips, canvas: document.canvas, urls: urls)
        guard key != preparedMedia else { return }
        pause()
        isPreparingPreview = true
        previewError = nil
        defer { if loadGeneration == generation { isPreparingPreview = false } }
        do {
            let item = try await IOSPreviewComposition.make(document: document, urls: urls)
            guard loadGeneration == generation else { return }
            statusObserver = nil
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            let playbackID = UUID()
            playbackGeneration = playbackID
            player.replaceCurrentItem(with: item)
            preparedMedia = key
            statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                let message = item.status == .failed ? item.error?.localizedDescription ?? "This media could not be played." : nil
                Task { @MainActor [weak self] in
                    guard self?.playbackGeneration == playbackID else { return }
                    if let message { self?.previewError = message; self?.pause() }
                }
            }
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                object: item, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.playbackGeneration == playbackID, !self.isSeeking else { return }
                    let remaining = IOSEditorTime.seconds(self.duration) - CMTimeGetSeconds(self.player.currentTime())
                    guard remaining.isFinite, remaining <= 0.001 else { return }
                    self.pause()
                    self.time = self.duration
                }
            }
            seek(to: min(time, duration))
        } catch {
            guard loadGeneration == generation else { return }
            player.replaceCurrentItem(with: nil)
            preparedMedia = nil
            previewError = error.localizedDescription
        }
    }

    private func observeTimeIfNeeded() {
        guard periodicObserver == nil else { return }
        periodicObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.periodicObserver != nil, !self.isSeeking, let time = try? MediaTime(validating: self.player.currentTime()) else { return }
                self.time = min(time, self.duration)
            }
        }
    }
    func seek(to value: MediaTime) {
        let value = min(value, duration)
        let generation = UUID()
        seekGeneration = generation
        isSeeking = true
        time = value
        player.seek(to: value.cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.seekGeneration == generation else { return }
                self.isSeeking = false
                if finished, let actual = try? MediaTime(validating: self.player.currentTime()) {
                    self.time = min(actual, self.duration)
                }
            }
        }
    }
    func scrub(seconds: Double) {
        pause()
        if let value = try? IOSEditorTime.stamp(seconds) { seek(to: value) }
    }
    func togglePlayback() {
        if isPlaying { pause(); return }
        guard player.currentItem != nil, previewError == nil else { return }
        endTyping()
        if time >= duration { seek(to: .zero) }
        isPlaying = true
        player.play()
    }
    func pause() { player.pause(); isPlaying = false }

    /// Explicit lifecycle teardown, before this session releases its AVPlayer.
    func stop() {
        isPresented = false
        pause()
        loadGeneration = UUID()
        seekGeneration = UUID()
        isSeeking = false
        isPreparingPreview = false
        isLoading = false
        if let periodicObserver { player.removeTimeObserver(periodicObserver); self.periodicObserver = nil }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        statusObserver = nil
        playbackGeneration = UUID()
        preparedMedia = nil
        player.replaceCurrentItem(with: nil)
    }
}
