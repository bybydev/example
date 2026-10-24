@preconcurrency import AVFoundation
import Foundation
import InkribeCore
import Observation

/// A single owner for the working document, save revision, undo, selection and playback.
@MainActor
@Observable
final class EditorSession {
    let access: ProAccess
    var proUpsell: ProFeature?
    let projectID: UUID
    let player = AVPlayer()
    var workspace = EditorWorkspace()
    private(set) var previewGeneration = UUID()
    private(set) var document: ProjectDocument?
    private(set) var snapshot: CaptionSnapshot?
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
    private let repository = ProjectRepository.shared
    private var isPresented = false
    private var committedRevision: UInt64 = 0
    private var savedBase: ProjectDocument?
    private var editSequence: UInt64 = 0
    private var savedSequence: UInt64 = 0
    private var loadGeneration = UUID()
    private var seekGeneration = UUID()
    private var playbackGeneration = UUID()
    private var isSeeking = false
    private var typingWordID: UUID?
    private var stylingControl: CaptionStyleControl?
    private var mediaControl: MediaControl?
    private var mediaURLs: [UUID: URL] = [:]
    private var editHistory = EditorHistory()
    private typealias Selection = EditorSelection
    private typealias History = EditorHistoryEntry
    private typealias HistoryChange = EditorHistoryChange
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var writer: Task<Void, Never>?
    @ObservationIgnored private var periodicObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var statusObserver: NSKeyValueObservation?
    @ObservationIgnored private var preparedMedia: MediaKey?
    @ObservationIgnored private var mediaRefresh: Task<Void, Never>?

    private struct MediaKey: Equatable {
        let clips: [ProjectClip]
        let canvas: ProjectCanvas
        let urls: [UUID: URL]
        let edits: MediaEdits
        let clipMedia: [UUID: ClipMediaOverrides]
    }

    init(projectID: UUID, access: ProAccess) { self.projectID = projectID; self.access = access }
    var isReadyToEdit: Bool { document != nil }
    var duration: MediaTime { document?.outputDuration ?? .zero }
    var presentation: CaptionPresentation? { snapshot?.evaluate(at: time) }
    var selectedCue: CaptionCue? { snapshot?.cues.first { $0.id == selectedCueID } }
    var selectedWord: CaptionWord? { selectedWordID.flatMap { snapshot?.wordsByID[$0] } }
    /// Timing corrections retain the original project clock, even for a clipped
    /// boundary unit. Transport/list/export use the retained, zero-based clock.
    var timingCue: CaptionCue? { document?.recognition?.cues.first { $0.id == selectedCueID } }
    var timingWord: CaptionWord? { document?.recognition?.words.first { $0.id == selectedWordID } }
    var currentClip: ProjectClip? {
        guard let document else { return nil }
        let original = try? OutputTimeline(document).originalTime(forOutput: min(time, duration))
        guard let original else { return nil }
        return document.orderedClips.first { $0.timelineInterval.contains(original) } ??
            (time == duration ? document.orderedClips.last : nil)
    }
    var editingClipID: UUID? {
        if case .clip(let id) = workspace.settingsScope { return id }
        return nil
    }
    var editingCaptionStyle: CaptionStyle {
        guard let document else { return .standard }
        return editingClipID.map { document.captionStyle(for: $0) } ?? document.effectiveCaptionStyle
    }
    var editingMediaEdits: MediaEdits {
        guard let document else { return .standard }
        return editingClipID.map { document.mediaEdits(for: $0) } ?? document.effectiveMediaEdits
    }
    func seekToClip(_ id: UUID) {
        guard let document, let clip = document.clips.first(where: { $0.id == id }),
              let interval = OutputTimeline(document).outputInterval(clip.timelineInterval) else { return }
        pause(); endTyping(); endStyleEditing(); endMediaEditing()
        if editingClipID != nil { workspace.settingsScope = .clip(id) }
        seek(to: interval.start)
    }
    func selectSettingsScope(_ scope: EditorSettingsScope) {
        pause(); endTyping(); endStyleEditing(); endMediaEditing()
        workspace.settingsScope = scope
        if case .clip(let id) = scope { seekToClip(id) }
    }

    var undoLabel: String { "Undo edit" }
    var redoLabel: String { "Redo edit" }
    var canMergeNext: Bool {
        guard let result = document?.recognition,
              let index = result.cues.firstIndex(where: { $0.id == selectedCueID }), index + 1 < result.cues.count,
              snapshot?.cues.contains(where: { $0.id == result.cues[index + 1].id }) == true,
              let a = result.cues[index].wordIDs.first, let b = result.cues[index + 1].wordIDs.first else { return false }
        guard let first = result.words.first(where: { $0.id == a }),
              let second = result.words.first(where: { $0.id == b }) else { return false }
        return first.clipID == second.clipID
    }

    func open() async {
        isPresented = true
        observeTimeIfNeeded()
        if document == nil || preparedMedia == nil { await readSaved() }
    }

    /// Call after an external result/relink; never throw away unsaved changes.
    func refreshSaved() async {
        await flush()
        guard isPresented, !hasPendingChanges else { return }
        await readSaved()
    }

    private func readSaved() async {
        guard isPresented else { return }
        let generation = UUID()
        loadGeneration = generation
        let sequence = editSequence
        isLoading = true
        loadError = nil
        defer { if loadGeneration == generation { isLoading = false } }
        do {
            var loaded = try await repository.open(projectID)
            if loaded.recognition == nil {
                do { loaded = try await repository.restoreRetainedCaptions(projectID: projectID) }
                catch is CancellationError { return }
                catch {
                    // Transcription controls report unavailable saved progress.
                    // It must not turn opening an otherwise valid project into
                    // a second, duplicate editor warning.
                }
            }
            guard generation == loadGeneration, sequence == editSequence else { return }
            if !hasPendingChanges && (document == nil || loaded.contentRevision != committedRevision) {
                let appendOnly = savedBase.map { loaded.isSpeechPublication(since: $0) } ?? false
                let hadWords = document?.recognition?.words.isEmpty == false
                document = loaded
                committedRevision = loaded.contentRevision
                savedSequence = editSequence
                hasPendingChanges = false
                saveError = nil
                if !appendOnly { editHistory.reset(); workspace.clearFieldDrafts(); updateHistoryFlags() }
                rebuildSnapshot()
                repairSelection()
                // A newly available transcript should be visible on the paused
                // footage, even when the original starts with silence/fade-in.
                if !hadWords, !isPlaying, snapshot?.evaluate(at: time) == nil,
                   let cue = snapshot?.chronologicalCues.first,
                   let reveal = try? EditorTime.stamp(min(EditorTime.seconds(cue.interval.end),
                       EditorTime.seconds(cue.interval.start) + min(0.1, CMTimeGetSeconds(cue.interval.duration) / 2))) {
                    time = reveal
                }
            }
            if !hasPendingChanges { savedBase = loaded }
            var urls: [UUID: URL] = [:]
            for asset in loaded.assets {
                if let url = try? await repository.sourceURL(projectID: projectID, assetID: asset.id) {
                    urls[asset.id] = url
                }
            }
            guard generation == loadGeneration else { return }
            originalAvailable = Dictionary(uniqueKeysWithValues: loaded.assets.map { ($0.id, urls[$0.id] != nil) })
            mediaURLs = urls
            await preparePreview(document: document ?? loaded, urls: urls, generation: generation)
            if generation == loadGeneration, !isPlaying { seek(to: time) }
        } catch {
            guard generation == loadGeneration else { return }
            loadError = error.localizedDescription
        }
    }

    func setTitle(_ value: String) {
        guard var next = document, next.title != value else { return }
        next.title = value
        stylingControl = nil; mediaControl = nil
        document = next
        changed()
    }

    func selectCue(_ id: UUID) {
        pause()
        typingWordID = nil
        stylingControl = nil
        mediaControl = nil
        selectedCueID = id
        selectedWordID = snapshot?.cues.first { $0.id == id }?.wordIDs.first
        if let cue = selectedCue { reveal(cue.interval) }
    }

    func selectWord(_ id: UUID) {
        pause()
        typingWordID = nil
        stylingControl = nil
        mediaControl = nil
        selectedWordID = id
        if let word = snapshot?.wordsByID[id] { reveal(word.projectInterval) }
    }

    private func reveal(_ interval: MediaInterval) {
        let seconds = EditorTime.seconds(interval.start) + min(0.1, CMTimeGetSeconds(interval.duration) / 2)
        if let value = try? EditorTime.stamp(seconds) { seek(to: value) }
    }

    func beginTyping() { pause() }
    func endTyping() { typingWordID = nil }
    func endStyleEditing() { stylingControl = nil }
    func endMediaEditing() { mediaControl = nil }

    func setMediaPresentation(_ edits: MediaEdits, canvas: ProjectCanvas? = nil,
                              preset: CanvasPreset? = nil, coalescing control: MediaControl? = nil) {
        guard var project = document else { return }
        let before = ProjectSettingsState(project)
        if let id = editingClipID {
            var settings = project.settings(for: id)
            settings.media.recordChanges(from: project.mediaEdits(for: id), to: edits)
            project.setSettings(settings)
        } else {
            project.mediaEdits = edits == .standard ? nil : edits
            if let canvas { project.canvas = canvas }
            if let preset { project.preset = preset }
        }
        commitSettings(project, before: before, coalescing: control != nil && control == mediaControl)
        mediaControl = control; stylingControl = nil
    }

    private func commitSettings(_ value: ProjectDocument, before: ProjectSettingsState, coalescing: Bool) {
        var project = value
        project.schemaVersion = ProjectSchema.current
        do {
            try project.validate()
            let after = ProjectSettingsState(project)
            guard after != before else { return }
            let originalTime = try OutputTimeline(document ?? project).originalTime(forOutput: min(time, duration))
            let selection = Selection(cue: selectedCueID, word: selectedWordID)
            if coalescing, !editHistory.past.isEmpty, editHistory.future.isEmpty,
               editHistory.past[editHistory.past.count - 1].change.coalesceSettings(from: before, to: after) {
                editHistory.past[editHistory.past.count - 1].selectionAfter = selection
            } else {
                editHistory.past.append(History(change: .settings(before: before, after: after),
                    selectionBefore: selection, selectionAfter: selection))
            }
            document = project
            time = try OutputTimeline(project).outputTime(clampingOriginal: originalTime)
            typingWordID = nil
            finishHistoryEdit(); rebuildSnapshot(); repairSelection()
            commandError = nil; changed()
            if after.changesMedia(from: before) { pause(); refreshMediaPreview() }
        } catch { commandError = error.localizedDescription }
    }

    /// Reset removes presence fields; it never copies defaults into the clip.
    /// Returning to already saved project defaults is permitted after Pro expires.
    func resetClipSettings(captions section: CaptionStyleReset? = nil, media: Bool = false, framing: Bool = false, volume: Bool = false, all: Bool = false) {
        guard var project = document, let id = editingClipID else { return }
        let before = ProjectSettingsState(project)
        var settings = project.settings(for: id)
        if all { settings = ClipSettings(id: id) }
        else if let section { settings.captions.reset(section) }
        else if media { settings.media = .init() }
        else if framing { settings.media.fit = nil; settings.media.zoom = nil; settings.media.positionX = nil; settings.media.positionY = nil }
        else if volume { settings.media.volume = nil }
        else { settings.captions = .init() }
        project.setSettings(settings)
        endStyleEditing(); endMediaEditing()
        commitSettings(project, before: before, coalescing: false)
    }

    private func refreshMediaPreview() {
        mediaRefresh?.cancel()
        let generation = UUID()
        loadGeneration = generation
        seekGeneration = UUID()
        playbackGeneration = UUID()
        preparedMedia = nil
        isSeeking = false
        isLoading = false
        isPreparingPreview = true
        mediaRefresh = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            guard let self, self.isPresented, self.loadGeneration == generation, let document = self.document else { return }
            var urls = self.mediaURLs
            for asset in document.assets where urls[asset.id] == nil {
                if let url = try? await self.repository.sourceURL(projectID: self.projectID, assetID: asset.id) { urls[asset.id] = url }
            }
            guard self.loadGeneration == generation else { return }
            self.mediaURLs = urls
            self.originalAvailable = Dictionary(uniqueKeysWithValues: document.assets.map { ($0.id, urls[$0.id] != nil) })
            await self.preparePreview(document: self.document ?? document, urls: urls, generation: generation)
        }
    }

    func setCaptionStyle(_ value: CaptionStyle, coalescing control: CaptionStyleControl? = nil,
                         applyingPreset: Bool = false, preservingPlacement: Bool = true) {
        var style = value
        if style.formatVersion == 1 && (style.hasExtendedValues || [.condensed, .rounded].contains(style.font) ||
            [.emphasis, .underline, .rise].contains(style.effect)) { style.formatVersion = 2 }
        guard var project = document else { return }
        let previous = editingCaptionStyle
        guard access.canChangeStyle(from: previous, to: style) else { proUpsell = .styles; return }
        let before = ProjectSettingsState(project)
        if let id = editingClipID {
            var settings = project.settings(for: id)
            if applyingPreset { settings.captions.applyPreset(style, preservingPlacement: preservingPlacement) }
            else { settings.captions.recordChanges(from: previous, to: style) }
            project.setSettings(settings)
        } else { project.captionStyle = style }
        commitSettings(project, before: before, coalescing: control != nil && control == stylingControl)
        stylingControl = control; mediaControl = nil
    }

    @discardableResult
    func editText(wordID: UUID, value: String) -> Bool {
        perform(coalescing: wordID) { state, _ in
            try CaptionEdits.text(value, wordID: wordID, in: &state)
            return nil
        }
    }

    @discardableResult
    func editCueText(cueID: UUID, value: String) -> Bool {
        perform(coalescing: cueID) { state, _ in
            try CaptionEdits.cueText(value, cueID: cueID, in: &state)
            return nil
        }
    }

    func retimeCue(_ interval: MediaInterval) {
        guard let id = selectedCueID else { return }
        perform { state, project in
            try CaptionEdits.cueTiming(interval, cueID: id, project: project, in: &state)
            return nil
        }
    }
    func retimeWord(_ interval: MediaInterval) {
        guard let id = selectedWordID else { return }
        perform { state, project in
            try CaptionEdits.wordTiming(interval, wordID: id, project: project, in: &state)
            return nil
        }
    }
    func split() {
        guard let cue = selectedCueID, let word = selectedWordID else { return }
        perform { state, _ in try CaptionEdits.split(cueID: cue, before: word, in: &state) }
    }
    func mergeNext() {
        guard let id = selectedCueID else { return }
        guard canMergeNext else { commandError = CaptionEditError.mergeBoundary.localizedDescription; return }
        perform { state, _ in try CaptionEdits.mergeNext(cueID: id, in: &state); return nil }
    }

    @discardableResult
    private func perform(coalescing wordID: UUID? = nil,
                         _ edit: (inout CaptionEditState, ProjectDocument) throws -> UUID?) -> Bool {
        guard var project = document, let result = project.recognition else { return false }
        pause()
        stylingControl = nil
        mediaControl = nil
        let before = CaptionEditState(result)
        var after = before
        let selection = Selection(cue: selectedCueID, word: selectedWordID)
        do {
            let newCue = try edit(&after, project)
            guard after != before else { commandError = nil; return true }
            project.schemaVersion = ProjectSchema.current
            project.recognition = after.applying(to: result)
            try project.validate()
            document = project
            if let newCue { selectedCueID = newCue }
            rebuildSnapshot()
            repairSelection()
            let finalSelection = Selection(cue: selectedCueID, word: selectedWordID)
            let patch = CaptionEditPatch(before: before, after: after)
            if let wordID, typingWordID == wordID, !editHistory.past.isEmpty, editHistory.future.isEmpty,
               editHistory.past[editHistory.past.count - 1].change.coalesceText(patch) {
                editHistory.past[editHistory.past.count - 1].selectionAfter = finalSelection
            } else {
                editHistory.past.append(History(change: .caption(patch), selectionBefore: selection, selectionAfter: finalSelection))
            }
            typingWordID = wordID
            finishHistoryEdit()
            commandError = nil
            changed()
            return true
        } catch { commandError = error.localizedDescription; return false }
    }

    func undo() {
        guard let history = editHistory.past.last else { return }
        if restore(history.change, forward: false, selection: history.selectionBefore) {
            editHistory.past.removeLast(); editHistory.future.append(history); updateHistoryFlags()
        }
    }
    func redo() {
        guard let history = editHistory.future.last else { return }
        if restore(history.change, forward: true, selection: history.selectionAfter) {
            editHistory.future.removeLast(); editHistory.past.append(history); updateHistoryFlags()
        }
    }
    private func restore(_ change: HistoryChange, forward: Bool, selection: Selection) -> Bool {
        guard var project = document else { return false }
        do {
            let oldTimeline = OutputTimeline(project)
            let originalTime = try oldTimeline.originalTime(forOutput: min(time, oldTimeline.duration))
            let mediaChanged = change.changesMedia
            project = try change.applying(to: project, forward: forward)
            let restoredTime: MediaTime
            if mediaChanged { restoredTime = try OutputTimeline(project).outputTime(clampingOriginal: originalTime) }
            else { restoredTime = time }
            pause(); typingWordID = nil; stylingControl = nil; mediaControl = nil
            workspace.clearFieldDrafts()
            document = project
            time = restoredTime
            selectedCueID = selection.cue; selectedWordID = selection.word
            rebuildSnapshot(); repairSelection(); changed()
            if mediaChanged { refreshMediaPreview() }
            return true
        } catch { commandError = error.localizedDescription; return false }
    }
    private func finishHistoryEdit() {
        editHistory.finishEdit()
        updateHistoryFlags()
    }
    private func updateHistoryFlags() { canUndo = !editHistory.past.isEmpty; canRedo = !editHistory.future.isEmpty }
    private func rebuildSnapshot() { snapshot = document.map(CaptionSnapshot.init) }
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

    /// One writer drains the newest complete project. Returned metadata never replaces newer text.
    /// Once a write starts, debounce cancellation cannot cancel it.
    func flush() async {
        debounce?.cancel(); debounce = nil
        if let writer {
            await writer.value
            if hasPendingChanges && saveError == nil { await flush() }
            return
        }
        guard hasPendingChanges else { return }
        isSaving = true
        let task = Task { await drainSaves() }
        writer = task
        await task.value
    }
    /// Later style/export adapters freeze this value only after the latest changes are saved.
    func savedDocument() async throws -> ProjectDocument {
        await flush()
        guard !hasPendingChanges else { throw CaptionEditError.unsavedChanges }
        guard let document else { throw ProjectStoreError.missingProject(projectID) }
        return document
    }

    private func drainSaves() async {
        defer { isSaving = false; writer = nil }
        while savedSequence != editSequence, let proposed = document {
            let capturedSequence = editSequence
            do {
                guard let base = savedBase else { throw ProjectStoreError.missingProject(projectID) }
                let saved = try await repository.commitEditorEdit(proposed, basedOn: base)
                if var latest = document {
                    latest.recognition = try saved.recognition?.keepingEdits(from: latest.recognition)
                    latest.contentRevision = saved.contentRevision
                    latest.updatedAt = saved.updatedAt
                    latest.schemaVersion = saved.schemaVersion
                    document = latest
                }
                committedRevision = saved.contentRevision
                savedSequence = capturedSequence
                savedBase = saved
                hasPendingChanges = savedSequence != editSequence
                saveError = nil
                rebuildSnapshot()
                repairSelection()
            } catch {
                hasPendingChanges = true
                // Input may have changed while the failed write awaited the
                // repository (for example an unfinished name became valid).
                // Try that newer value before presenting the older failure.
                if editSequence != capturedSequence { continue }
                saveError = saveMessage(for: error, project: document ?? proposed)
                return // Keep the latest document and undo history in this app-owned session.
            }
        }
    }

    private func saveMessage(for error: Error, project: ProjectDocument) -> String {
        let title = project.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { return "Enter a project name to save your changes." }
        if project.title.count > 256 { return "Keep the project name within 256 characters." }
        let underlying = error as NSError
        if underlying.domain == NSCocoaErrorDomain && underlying.code == NSFileWriteOutOfSpaceError {
            return "Your device is low on storage. Free up some space, then try again."
        }
        if let error = error as? ProjectStoreError {
            switch error {
            case .staleRevision:
                return "The saved project changed while you were editing. Your latest changes are still open in Inkribe."
            case .missingOriginal:
                return "The original media is unavailable. Your latest changes are still open in Inkribe."
            default: break
            }
        }
        return "Your latest changes are still open in Inkribe. Try saving again."
    }

    func retrySave() async { await flush() }

    func retryPreview() async {
        preparedMedia = nil
        await refreshSaved()
    }

    private func preparePreview(document: ProjectDocument, urls: [UUID: URL], generation: UUID) async {
        let key = MediaKey(clips: document.clips, canvas: document.canvas, urls: urls,
            edits: document.effectiveMediaEdits, clipMedia: Dictionary(uniqueKeysWithValues: (document.clipSettings ?? []).filter { !$0.media.isEmpty }.map { ($0.id, $0.media) }))
        guard key != preparedMedia else {
            if loadGeneration == generation { isPreparingPreview = false }
            return
        }
        pause()
        isPreparingPreview = true
        previewError = nil
        defer { if loadGeneration == generation { isPreparingPreview = false } }
        do {
            let item = try await PreviewComposition.make(document: document, urls: urls)
            guard loadGeneration == generation else { return }
            statusObserver = nil
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            let playbackID = UUID()
            playbackGeneration = playbackID
            player.replaceCurrentItem(with: item)
            previewGeneration = UUID()
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
                    let remaining = EditorTime.seconds(self.duration) - CMTimeGetSeconds(self.player.currentTime())
                    guard remaining.isFinite, remaining <= 0.001 else { return }
                    self.pause()
                    self.time = self.duration
                }
            }
            isPreparingPreview = false
            seek(to: min(time, duration))
        } catch {
            guard loadGeneration == generation else { return }
            player.replaceCurrentItem(with: nil)
            previewGeneration = UUID()
            preparedMedia = nil
            previewError = error.localizedDescription
        }
    }

    private func observeTimeIfNeeded() {
        guard periodicObserver == nil else { return }
        periodicObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.periodicObserver != nil, !self.isSeeking, !self.isPreparingPreview,
                      let time = try? MediaTime(validating: self.player.currentTime()) else { return }
                self.time = min(time, self.duration)
            }
        }
    }
    func seek(to value: MediaTime) {
        let value = min(value, duration)
        if isPreparingPreview { time = value; return }
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
        if let value = try? EditorTime.stamp(seconds) { seek(to: value) }
    }
    func togglePlayback() {
        if isPlaying { pause(); return }
        guard player.currentItem != nil, previewError == nil, !isPreparingPreview else { return }
        endTyping()
        if time >= duration { seek(to: .zero) }
        isPlaying = true
        player.play()
    }
    func pause() { player.pause(); isPlaying = false }

    /// Explicit lifecycle teardown, before this session releases its AVPlayer.
    func stop() {
        isPresented = false
        mediaRefresh?.cancel(); mediaRefresh = nil
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
        previewGeneration = UUID()
    }
}

