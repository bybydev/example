@preconcurrency import AVFoundation
import Foundation
import InkribeCore
import Observation

/// A single owner for the working document, save revision, undo, selection and playback.
@MainActor
@Observable
final class EditorSession {
    static let previewPlaybackSpeeds: [Float] = [0.5, 1, 1.25, 1.5, 2]
    let access: ProAccess
    var proUpsell: ProFeature?
    let projectID: UUID
    let player = AVPlayer()
    let previewFrames = PreviewFrameBuffer()
    var workspace = EditorWorkspace()
    private(set) var previewGeneration = UUID()
    private(set) var document: ProjectDocument?
    private(set) var snapshot: CaptionSnapshot?
    private(set) var timelineSnapshot: ProjectTimelineSnapshot?
    private(set) var originalAvailable: [UUID: Bool] = [:]
    private(set) var clipEditGeneration = 0
    private(set) var isChangingClips = false
    private(set) var isSavingCaptionStyle = false
    private(set) var isSavingMusic = false
    private(set) var isSavingMedia = false
    private(set) var isSavingClipTrim = false
    private(set) var clipTrimPreview: TimelineClipTrimPreview?
    var isEditingClipTrim: Bool { clipTrimPreview != nil || isSavingClipTrim }
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var isPreparingPreview = false
    private(set) var isPlaying = false
    private(set) var previewPlaybackSpeed: Float = 1
    private(set) var time = MediaTime.zero
    private(set) var selectedCueID: UUID?
    private(set) var selectedWordID: UUID?
    private(set) var saveError: String?
    private(set) var loadError: String?
    private(set) var previewError: String?
    var commandError: String?
    private(set) var hasPendingChanges = false
    private var hasUndo = false
    private var hasRedo = false
    var canUndo: Bool { hasUndo && historyAdmitted(editHistory.past.last) }
    var canRedo: Bool { hasRedo && historyAdmitted(editHistory.future.last) }
    private let transcription: TranscriptionController
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
    @ObservationIgnored private var playbackStateObserver: NSKeyValueObservation?
    @ObservationIgnored private var playbackRateObserver: NSKeyValueObservation?
    @ObservationIgnored private var defaultPlaybackRateObserver: NSKeyValueObservation?
    @ObservationIgnored private var preparedMedia: MediaKey?
    @ObservationIgnored private var mediaRefresh: Task<Void, Never>?

    private struct MediaKey: Equatable {
        let clips: [ProjectClip]
        let canvas: ProjectCanvas
        let urls: [UUID: URL]
        let edits: MediaEdits
        let clipMedia: [UUID: ClipMediaOverrides]
        let clipTrims: [UUID: ClipSourceTrim]
        let music: ProjectMusic?
        let originalAudioMuted: Bool
    }

    init(projectID: UUID, access: ProAccess, transcription: TranscriptionController) {
        self.projectID = projectID; self.access = access; self.transcription = transcription
    }
    var isReadyToEdit: Bool { document != nil && !isChangingClips && !isSavingCaptionStyle && !isSavingMusic && !isSavingMedia && !isEditingClipTrim }
    var canChangeClips: Bool { document != nil && !isChangingClips && !isSavingCaptionStyle && !isSavingMusic && !isSavingMedia && !isEditingClipTrim && !transcription.isActive(projectID) && !transcription.isAuthorizing }
    var timelineSourceURLs: [UUID: URL] { mediaURLs }
    var duration: MediaTime { document?.outputDuration ?? .zero }
    var presentation: CaptionPresentation? { snapshot?.evaluate(at: time) }
    var selectedCue: CaptionCue? { snapshot?.cues.first { $0.id == selectedCueID } }
    var selectedWord: CaptionUnit? { selectedWordID.flatMap { snapshot?.wordsByID[$0] } }
    /// Timing corrections retain the original project clock, even for a clipped
    /// boundary unit. Transport/list/export use the retained, zero-based clock.
    var timingCue: CaptionCue? {
        if let manual = selectedManualCaption { return CaptionCue(id: manual.id, wordIDs: [manual.id], interval: manual.interval) }
        return document?.recognition?.cues.first { $0.id == selectedCueID }
    }
    var timingWord: CaptionWord? { document?.recognition?.words.first { $0.id == selectedWordID } }
    var selectedManualCaption: ManualCaption? { document?.manualCaptions?.first { $0.id == selectedCueID } }
    var currentClip: ProjectClip? {
        guard let document else { return nil }
        let timeline = OutputTimeline(document)
        guard let original = try? timeline.originalTime(forOutput: min(time, duration)) else { return nil }
        let visible = document.orderedClips.filter { timeline.outputInterval($0.timelineInterval) != nil }
        if time == duration { return visible.last }
        return visible.first { $0.timelineInterval.contains(original) }
    }
    var editingClipID: UUID? {
        if case .clip(let id) = workspace.settingsScope { return id }
        return nil
    }
    var editingCaptionStyle: CaptionStyle { document?.effectiveCaptionStyle ?? .standard }
    var editingMediaEdits: MediaEdits {
        guard let document else { return .standard }
        return editingClipID.map { document.mediaEdits(for: $0) } ?? document.effectiveMediaEdits
    }
    /// Timeline selection reveals trim handles without moving the playhead.
    func selectTimelineClip(_ id: UUID) {
        guard !isEditingClipTrim, let document, document.clips.contains(where: { $0.id == id }) else { return }
        pause(); endTyping(); endStyleEditing(); endMediaEditing()
        workspace.timelineClipID = id
        workspace.timelineCueID = nil
        if editingClipID != nil { workspace.settingsScope = .clip(id) }
    }
    func seekToClip(_ id: UUID) {
        guard !isEditingClipTrim, let document, let clip = document.clips.first(where: { $0.id == id }) else { return }
        let timeline = OutputTimeline(document)
        let point = timeline.outputInterval(clip.timelineInterval)?.start ??
            (try? timeline.outputTime(clampingOriginal: clip.timelineInterval.start)) ?? .zero
        selectTimelineClip(id)
        seek(to: point)
    }
    func selectSettingsScope(_ scope: EditorSettingsScope) {
        pause(); endTyping(); endStyleEditing(); endMediaEditing()
        workspace.settingsScope = scope
        if case .clip(let id) = scope { seekToClip(id) }
    }

    var undoLabel: String { "Undo " + (editHistory.past.last?.change.actionName ?? "edit") }
    var redoLabel: String { "Redo " + (editHistory.future.last?.change.actionName ?? "edit") }
    var canMergeNext: Bool {
        guard selectedManualCaption == nil, let result = document?.recognition,
              let index = result.cues.firstIndex(where: { $0.id == selectedCueID }), index + 1 < result.cues.count,
              snapshot?.cues.contains(where: { $0.id == result.cues[index + 1].id }) == true,
              let a = result.cues[index].wordIDs.first, let b = result.cues[index + 1].wordIDs.first else { return false }
        guard let first = result.words.first(where: { $0.id == a }),
              let second = result.words.first(where: { $0.id == b }) else { return false }
        return first.clipID == second.clipID
    }

    func open(rebuildPreview: Bool = false) async {
        guard !Task.isCancelled else { return }
        if rebuildPreview { preparedMedia = nil }
        isPresented = true
        observeTimeIfNeeded()
        if document == nil || preparedMedia == nil { await readSaved() }
    }

    /// Call after an external result/relink; never throw away unsaved changes.
    func refreshSaved() async {
        guard !isChangingClips, !isSavingCaptionStyle, !isSavingMusic, !isSavingMedia, !isEditingClipTrim else { return }
        await flush()
        guard !Task.isCancelled, isPresented, !hasPendingChanges else { return }
        await readSaved()
    }

    /// Media adoption already schedules its graph refresh. Reconcile excluded
    /// speech notifications afterward so an unchanged graph reuses that result.
    func refreshAfterMediaEditing() async {
        await mediaRefresh?.value
        await refreshSaved()
    }

    private func readSaved() async {
        guard isPresented, !isChangingClips, !isSavingCaptionStyle, !isSavingMusic, !isSavingMedia, !isEditingClipTrim else { return }
        let generation = UUID()
        loadGeneration = generation
        let sequence = editSequence
        isLoading = true
        loadError = nil
        defer { if loadGeneration == generation { isLoading = false } }
        do {
            try Task.checkCancellation()
            var loaded = try await repository.open(projectID)
            try Task.checkCancellation()
            guard generation == loadGeneration else { return }
            if loaded.recognition == nil {
                do { loaded = try await repository.restoreRetainedCaptions(projectID: projectID) }
                catch is CancellationError { return }
                catch {
                    // Transcription controls report unavailable saved progress.
                    // It must not turn opening an otherwise valid project into
                    // a second, duplicate editor warning.
                }
            }
            try Task.checkCancellation()
            guard generation == loadGeneration, sequence == editSequence else { return }
            if !hasPendingChanges && (document == nil || loaded.contentRevision != committedRevision) {
                let appendOnly = savedBase.map { loaded.isSpeechPublication(since: $0) } ?? false
                let hadWords = document?.hasCaptionUnits == true
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
            for asset in loaded.ownedMediaAssets {
                try Task.checkCancellation()
                guard generation == loadGeneration else { return }
                if let url = try? await repository.sourceURL(projectID: projectID, assetID: asset.id) {
                    urls[asset.id] = url
                }
            }
            try Task.checkCancellation()
            guard generation == loadGeneration else { return }
            originalAvailable = Dictionary(uniqueKeysWithValues: loaded.ownedMediaAssets.map { ($0.id, urls[$0.id] != nil) })
            mediaURLs = urls
            await preparePreview(document: document ?? loaded, urls: urls, generation: generation)
            if !Task.isCancelled, generation == loadGeneration, !isPlaying { seek(to: time) }
        } catch is CancellationError {
            // Back/Cancel is navigation, not a project failure.
        } catch {
            guard !Task.isCancelled, generation == loadGeneration else { return }
            loadError = error.localizedDescription
        }
    }

    func setTitle(_ value: String) {
        guard !isChangingClips, !isSavingCaptionStyle, !isSavingMusic, !isSavingMedia, !isEditingClipTrim else { return }
        guard var next = document, next.title != value else { return }
        next.title = value
        stylingControl = nil; mediaControl = nil
        document = next
        changed()
    }

    /// Nil restores the imported name. Labels share atomic saves and bounded undo,
    /// without changing media identity, recognition checkpoints or the preview graph.
    @discardableResult
    func renameClip(_ id: UUID, to value: String?) -> Bool {
        guard !isChangingClips, !isSavingCaptionStyle, !isSavingMusic, !isSavingMedia, !isEditingClipTrim else { return false }
        guard var project = document, project.clips.contains(where: { $0.id == id }) else {
            commandError = "This clip is no longer available."
            return false
        }
        let name = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name, name.isEmpty || name.count > 256 {
            commandError = "Enter a clip name with 1–256 characters."
            return false
        }
        var settings = project.settings(for: id)
        guard settings.displayName != name else { commandError = nil; return true }
        let before = ProjectSettingsState(project)
        settings.displayName = name
        project.setSettings(settings)
        endTyping(); endStyleEditing(); endMediaEditing()
        commitSettings(project, before: before, coalescing: false)
        return commandError == nil
    }

    func appendClips(_ imported: PreparedClipImport) async throws -> [UUID] {
        guard canChangeClips else { throw ClipGraphError.busy }
        isChangingClips = true
        defer { isChangingClips = false }
        let base = try await prepareClipChange()
        let saved = try await transcription.withClipMutation(projectID: projectID) {
            try await self.repository.appendClips(imported, basedOn: base)
        }
        adoptClipEdit(saved, replacing: base, recordHistory: true)
        return imported.clips.map(\.id)
    }

    func removeClip(_ id: UUID) async throws {
        guard canChangeClips else { throw ClipGraphError.busy }
        isChangingClips = true
        defer { isChangingClips = false }
        let base = try await prepareClipChange()
        let saved = try await transcription.withClipMutation(projectID: projectID) {
            try await self.repository.removeClip(id, basedOn: base)
        }
        adoptClipEdit(saved, replacing: base, recordHistory: true)
    }

    func reorderClips(_ ids: [UUID], replacing graph: ClipGraphState) async throws {
        guard canChangeClips else { throw ClipGraphError.busy }
        isChangingClips = true
        defer { isChangingClips = false }
        let base = try await prepareClipChange()
        guard ClipGraphState(base) == graph else { throw ClipGraphError.stale }
        guard ids != base.orderedClips.map(\.id) else { return }
        let saved = try await transcription.withClipMutation(projectID: projectID) {
            try await self.repository.reorderClips(ids, replacing: graph, basedOn: base)
        }
        if saved.contentRevision != base.contentRevision {
            adoptClipEdit(saved, replacing: base, recordHistory: true)
        }
    }

    private func prepareClipChange() async throws -> ProjectDocument {
        pause(); endTyping(); endStyleEditing(); endMediaEditing()
        await flush()
        guard !hasPendingChanges, let document else { throw CaptionEditError.unsavedChanges }
        try Task.checkCancellation()
        return document
    }

    private func adoptClipEdit(_ saved: ProjectDocument, replacing base: ProjectDocument, recordHistory: Bool) {
        let selection = Selection(cue: selectedCueID, word: selectedWordID)
        let projected = ClipGraphEdit.playhead(time, from: base, to: saved)
        document = saved; savedBase = saved; committedRevision = saved.contentRevision
        editSequence += 1; savedSequence = editSequence
        hasPendingChanges = false; saveError = nil; commandError = nil
        time = projected
        workspace.clearFieldDrafts()
        if case .clip(let id) = workspace.settingsScope, !saved.clips.contains(where: { $0.id == id }) {
            workspace.settingsScope = .project
        }
        rebuildSnapshot(); repairSelection()
        if recordHistory {
            editHistory.past.append(History(change: .clips(before: ClipGraphState(base), after: ClipGraphState(saved)),
                selectionBefore: selection, selectionAfter: Selection(cue: selectedCueID, word: selectedWordID)))
            finishHistoryEdit()
        }
        refreshMediaPreview()
        clipEditGeneration += 1
    }

    private func restoreClipHistory(_ history: History, forward: Bool) async {
        guard canChangeClips, case .clips(let before, let after) = history.change else {
            commandError = ClipGraphError.busy.localizedDescription; return
        }
        isChangingClips = true
        defer { isChangingClips = false }
        do {
            let base = try await prepareClipChange()
            let saved = try await transcription.withClipMutation(projectID: projectID) {
                try await self.repository.restoreClipGraph(forward ? after : before,
                    replacing: forward ? before : after, basedOn: base)
            }
            adoptClipEdit(saved, replacing: base, recordHistory: false)
            let selection = forward ? history.selectionAfter : history.selectionBefore
            selectedCueID = selection.cue; selectedWordID = selection.word; repairSelection()
            if forward { editHistory.future.removeLast(); editHistory.past.append(history) }
            else { editHistory.past.removeLast(); editHistory.future.append(history) }
            updateHistoryFlags()
        } catch { commandError = error.localizedDescription }
    }

    func selectCue(_ id: UUID) {
        pause()
        typingWordID = nil
        stylingControl = nil
        mediaControl = nil
        selectedCueID = id
        workspace.timelineCueID = id
        workspace.timelineClipID = snapshot?.cues.first(where: { $0.id == id })?.wordIDs.first
            .flatMap { snapshot?.wordsByID[$0]?.clipID }
        selectedWordID = snapshot?.cues.first { $0.id == id }?.wordIDs.first
        if let cue = selectedCue { reveal(cue.interval) }
    }

    /// Returning from the contextual editor only adjusts presentation state.
    /// Cue intervals in the snapshot already use the retained playback clock.
    func prepareCaptionPlayback(_ id: UUID) {
        pause(); endTyping(); endStyleEditing(); endMediaEditing()
        guard let cue = snapshot?.cues.first(where: { $0.id == id }) else { return }
        selectedCueID = id
        workspace.timelineCueID = id
        workspace.timelineClipID = cue.wordIDs.first.flatMap { snapshot?.wordsByID[$0]?.clipID }
        let start = CMTimeMaximum(.zero, CMTimeSubtract(cue.interval.start.cmTime, CMTime(value: 1, timescale: 4)))
        if let target = try? MediaTime(validating: start) { seek(to: target) }
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

    /// Controls remain local until Done. A failed save preserves the working
    /// project/history and lets the caller retain its draft for Retry or Cancel.
    func saveMusicDraft(_ music: ProjectMusic?, replacing expected: ProjectMusic?,
                        imported: PreparedMusicImport? = nil) async throws {
        guard isReadyToEdit, !isLoading, !isPreparingPreview else { throw MusicEditError.busy }
        isSavingMusic = true
        defer { isSavingMusic = false }
        pause(); endTyping(); endStyleEditing(); endMediaEditing()
        loadGeneration = UUID()
        await flush()
        guard !hasPendingChanges, let base = document, let savedBase else { throw CaptionEditError.unsavedChanges }
        guard base.music == expected else { throw MusicEditError.stale }
        if let imported {
            guard music?.asset == imported.asset else { throw MusicEditError.invalidImport }
        } else {
            guard music == nil || music?.asset == expected?.asset else { throw MusicEditError.stale }
        }
        guard music != base.music else { return }
        try Task.checkCancellation()
        var proposed = base
        proposed.music = music
        proposed.schemaVersion = ProjectSchema.current
        try proposed.validate()
        let saved: ProjectDocument
        if let imported {
            guard let music else { throw MusicEditError.invalidImport }
            saved = try await repository.installMusic(imported, basedOn: savedBase, settings: music)
        }
        else { saved = try await repository.commitEditorEdit(proposed, basedOn: savedBase) }
        adoptMusicEdit(saved, replacing: base)
    }

    private func adoptMusicEdit(_ saved: ProjectDocument, replacing base: ProjectDocument) {
        let selection = Selection(cue: selectedCueID, word: selectedWordID)
        document = saved; savedBase = saved; committedRevision = saved.contentRevision
        editSequence += 1; savedSequence = editSequence
        hasPendingChanges = false; saveError = nil; commandError = nil
        editHistory.past.append(History(change: .music(before: base.music, after: saved.music),
            selectionBefore: selection, selectionAfter: selection))
        finishHistoryEdit(); rebuildSnapshot(); repairSelection()
        refreshMediaPreview()
    }

    /// An independent master switch respects explicit per-clip overrides and
    /// restores the exact prior mix when switched off again.
    func setOriginalAudioMuted(_ muted: Bool) {
        guard isReadyToEdit, var project = document, project.isOriginalAudioMuted != muted else { return }
        let before = ProjectSettingsState(project)
        project.originalAudioMuted = muted ? true : nil
        endTyping(); endStyleEditing(); endMediaEditing()
        commitSettings(project, before: before, coalescing: false)
    }

    func setMediaPresentation(_ edits: MediaEdits, canvas: ProjectCanvas? = nil,
                              preset: CanvasPreset? = nil, coalescing control: MediaControl? = nil) {
        guard !isChangingClips, !isSavingCaptionStyle, !isSavingMusic, !isSavingMedia, !isEditingClipTrim else { return }
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
        guard !isChangingClips, !isSavingCaptionStyle, !isSavingMusic, !isSavingMedia, !isEditingClipTrim else { return }
        guard var project = document, let id = editingClipID else { return }
        let before = ProjectSettingsState(project)
        var settings = project.settings(for: id)
        if all { settings.captions = .init(); settings.media = .init() }
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
            guard let self, self.isPresented, self.loadGeneration == generation else { return }
            // Music history may restore an older owned song. Publish that source
            // reference before resolving it through the saved repository graph.
            if self.document?.music?.asset != self.savedBase?.music?.asset {
                await self.flush()
                guard !self.hasPendingChanges else {
                    if self.loadGeneration == generation { self.isPreparingPreview = false }
                    return
                }
            }
            guard self.loadGeneration == generation, let document = self.document else { return }
            let activeAssets = Set(document.ownedMediaAssets.map(\.id))
            var urls = self.mediaURLs.filter { activeAssets.contains($0.key) }
            for asset in document.ownedMediaAssets where urls[asset.id] == nil {
                if let url = try? await self.repository.sourceURL(projectID: self.projectID, assetID: asset.id) { urls[asset.id] = url }
            }
            guard self.loadGeneration == generation else { return }
            self.mediaURLs = urls
            self.originalAvailable = Dictionary(uniqueKeysWithValues: document.ownedMediaAssets.map { ($0.id, urls[$0.id] != nil) })
            await self.preparePreview(document: self.document ?? document, urls: urls, generation: generation)
        }
    }

    /// Save before adopting the draft: a failed Done leaves the live document and
    /// history untouched, so Cancel still discards every local style adjustment.
    func saveCaptionStyleDraft(_ draft: CaptionStyleDraft) async throws {
        guard !isChangingClips, !isSavingCaptionStyle, !isSavingMusic, !isSavingMedia, !isEditingClipTrim, !isLoading, !isPreparingPreview else { throw ClipGraphError.busy }
        isSavingCaptionStyle = true
        defer { isSavingCaptionStyle = false }
        pause(); endTyping(); endStyleEditing(); endMediaEditing()
        // Supersede an in-flight refresh before it can replace the document.
        loadGeneration = UUID()
        isLoading = false
        await flush()
        guard !hasPendingChanges, let base = document, let savedBase else { throw CaptionEditError.unsavedChanges }
        try Task.checkCancellation()
        let proposed = try draft.applying(to: base, access: access)
        let before = ProjectSettingsState(base)
        guard ProjectSettingsState(proposed) != before else { return }
        let saved = try await repository.commitEditorEdit(proposed, basedOn: savedBase)
        // No cancellable work after publication. All other session mutations are
        // excluded until the saved result and its one history entry are adopted.
        let selection = Selection(cue: selectedCueID, word: selectedWordID)
        document = saved
        self.savedBase = saved
        committedRevision = saved.contentRevision
        editSequence += 1; savedSequence = editSequence
        hasPendingChanges = false; saveError = nil; commandError = nil
        editHistory.past.append(History(change: .settings(before: before, after: ProjectSettingsState(saved)),
            selectionBefore: selection, selectionAfter: selection))
        finishHistoryEdit(); rebuildSnapshot(); repairSelection()
    }

    /// Commit all Media scopes together. Save failure leaves the draft local;
    /// publication adopts one durable settings history entry and one preview refresh.
    func saveMediaDraft(_ draft: MediaDraft) async throws {
        try Task.checkCancellation()
        guard !draft.isClosed else { throw CancellationError() }
        guard isReadyToEdit else { throw ClipGraphError.busy }
        isSavingMedia = true
        var restorePreview = isLoading || isPreparingPreview
        defer {
            isSavingMedia = false
            // If saving failed or was a no-op, restart any interrupted work
            // against the unchanged document instead of leaving a busy preview.
            if restorePreview, isPresented { refreshMediaPreview() }
        }
        pause(); endTyping(); endStyleEditing(); endMediaEditing()
        mediaRefresh?.cancel(); mediaRefresh = nil
        loadGeneration = UUID()
        isLoading = false; isPreparingPreview = false
        await flush()
        guard !hasPendingChanges, let base = document, let savedBase else { throw CaptionEditError.unsavedChanges }
        try Task.checkCancellation()
        let proposed = try draft.applying(to: base)
        let before = ProjectSettingsState(base)
        guard ProjectSettingsState(proposed) != before else { return }
        let originalTime = try OutputTimeline(base).originalTime(forOutput: min(time, base.outputDuration))
        let nextTime = try OutputTimeline(proposed).outputTime(clampingOriginal: originalTime)
        try Task.checkCancellation()
        let saved = try await repository.commitEditorEdit(proposed, basedOn: savedBase)
        // Do not cancel between durable publication and local adoption.
        let selection = Selection(cue: selectedCueID, word: selectedWordID)
        document = saved; self.savedBase = saved; committedRevision = saved.contentRevision
        editSequence += 1; savedSequence = editSequence
        hasPendingChanges = false; saveError = nil; commandError = nil
        time = nextTime
        editHistory.past.append(History(change: .settings(before: before, after: ProjectSettingsState(saved)),
            selectionBefore: selection, selectionAfter: selection))
        finishHistoryEdit(); rebuildSnapshot(); repairSelection()
        restorePreview = false
        refreshMediaPreview()
    }

    func beginClipTrim(_ id: UUID, edge: ClipTrimEdge) -> TimelineClipTrim? {
        guard isReadyToEdit, let document,
              let plan = try? TimelineClipTrim(clipID: id, edge: edge, document: document),
              mediaURLs[plan.clip.sourceAssetID] != nil else { return nil }
        pause(); endTyping(); endStyleEditing(); endMediaEditing()
        workspace.timelineClipID = id
        commandError = nil
        let preview = TimelineClipTrimPreview(plan: plan, document: document, urls: mediaURLs) { [weak self] error in
            self?.commandError = error
        }
        clipTrimPreview = preview
        preview.update(plan.original)
        return plan
    }
    func clipTrimIsCurrent(_ plan: TimelineClipTrim) -> Bool {
        clipTrimPreview?.plan.id == plan.id && (document.map { plan.matches($0) } ?? false)
    }
    func previewClipTrim(_ plan: TimelineClipTrim, range: ClipSourceTrim) {
        guard clipTrimIsCurrent(plan), !isSavingClipTrim else { return }
        clipTrimPreview?.update(range)
    }
    func cancelClipTrim(_ plan: TimelineClipTrim) {
        guard clipTrimPreview?.plan.id == plan.id, !isSavingClipTrim else { return }
        clipTrimPreview?.close(); clipTrimPreview = nil
        Task { await refreshSaved() }
    }
    func commitClipTrim(_ plan: TimelineClipTrim, range: ClipSourceTrim) {
        guard clipTrimIsCurrent(plan), !isSavingClipTrim else { return }
        isSavingClipTrim = true
        Task {
            var didSave = false
            defer {
                isSavingClipTrim = false
                if didSave {
                    // Keep the boundary frame until the real trimmed graph has
                    // replaced the old player item, preventing an old-frame flash.
                    Task {
                        await mediaRefresh?.value
                        if clipTrimPreview?.plan.id == plan.id { clipTrimPreview?.close(); clipTrimPreview = nil }
                        await refreshSaved()
                    }
                } else {
                    if clipTrimPreview?.plan.id == plan.id { clipTrimPreview?.close(); clipTrimPreview = nil }
                    Task { await refreshAfterMediaEditing() }
                }
            }
            do {
                await flush()
                guard clipTrimPreview?.plan.id == plan.id else { throw CancellationError() }
                guard !hasPendingChanges, let base = document, let savedBase else { throw CaptionEditError.unsavedChanges }
                let proposed = try plan.applying(range, to: base)
                let before = ClipTrimState(base), after = ClipTrimState(proposed)
                guard before != after else { return }
                let point = try plan.projectPoint(range)
                var nextTime = try OutputTimeline(proposed).outputTime(clampingOriginal: point)
                if plan.edge == .end, let interval = range.interval {
                    let step = CMTimeMinimum(CMTime(value: 1, timescale: 60_000), CMTimeMultiplyByFloat64(interval.duration, multiplier: 0.5))
                    nextTime = try MediaTime(validating: CMTimeMaximum(.zero, CMTimeSubtract(nextTime.cmTime, step)))
                }
                try Task.checkCancellation()
                let saved = try await repository.commitEditorEdit(proposed, basedOn: savedBase)
                let selection = Selection(cue: selectedCueID, word: selectedWordID)
                document = saved; self.savedBase = saved; committedRevision = saved.contentRevision
                editSequence += 1; savedSequence = editSequence
                hasPendingChanges = false; saveError = nil; commandError = nil
                time = nextTime
                editHistory.past.append(History(change: .clipTrim(before: before, after: ClipTrimState(saved)),
                    selectionBefore: selection, selectionAfter: selection))
                finishHistoryEdit(); rebuildSnapshot(); repairSelection()
                didSave = true
                refreshMediaPreview()
            } catch is CancellationError {
                // Teardown before admission does not publish the gesture.
            } catch { commandError = error.localizedDescription }
        }
    }

    /// Project-wide appearance/placement; media scope never selects caption scope.
    func setCaptionStyle(_ value: CaptionStyle, coalescing control: CaptionStyleControl? = nil) {
        guard !isChangingClips, !isSavingCaptionStyle, !isSavingMusic, !isSavingMedia, !isEditingClipTrim else { return }
        var style = value
        if style.formatVersion == 1 && (style.hasExtendedValues || [.condensed, .rounded].contains(style.font) ||
            [.emphasis, .underline, .rise].contains(style.effect)) { style.formatVersion = 2 }
        guard var project = document else { return }
        let previous = editingCaptionStyle
        guard access.canChangeStyle(from: previous, to: style) else { proUpsell = .styles; return }
        let before = ProjectSettingsState(project)
        project = project.usingProjectCaptionStyle()
        project.captionStyle = style
        commitSettings(project, before: before, coalescing: control != nil && control == stylingControl)
        stylingControl = control; mediaControl = nil
    }

    @discardableResult
    func editText(wordID: UUID, value: String) -> Bool {
        guard !isChangingClips, !isSavingCaptionStyle, !isSavingMusic, !isSavingMedia, !isEditingClipTrim else { return false }
        if let caption = document?.manualCaptions?.first(where: { $0.id == wordID }) {
            return editManualText(caption, value: value)
        }
        return perform(coalescing: wordID) { state, _ in
            try CaptionEdits.text(value, wordID: wordID, in: &state)
            return nil
        }
    }

    @discardableResult
    func editCueText(cueID: UUID, value: String) -> Bool {
        guard !isChangingClips, !isSavingCaptionStyle, !isSavingMusic, !isSavingMedia, !isEditingClipTrim else { return false }
        if let caption = document?.manualCaptions?.first(where: { $0.id == cueID }) {
            return editManualText(caption, value: value)
        }
        return perform(coalescing: cueID) { state, _ in
            try CaptionEdits.cueText(value, cueID: cueID, in: &state)
            return nil
        }
    }

    func beginTimelineTiming(cueID: UUID, operation: TimelineTimingOperation) -> TimelineCaptionTiming? {
        guard !isChangingClips, !isSavingCaptionStyle, !isSavingMusic, !isSavingMedia, !isEditingClipTrim else { return nil }
        guard let project = document else { return nil }
        do {
            let edit = try TimelineCaptionTiming(cueID: cueID, operation: operation, project: project)
            pause(); endTyping(); endStyleEditing(); endMediaEditing()
            selectedCueID = cueID
            selectedWordID = snapshot?.cues.first(where: { $0.id == cueID })?.wordIDs.first
            workspace.timelineCueID = cueID; workspace.timelineClipID = edit.clip.id
            commandError = nil
            return edit
        } catch { commandError = error.localizedDescription; return nil }
    }
    func timelineTimingIsCurrent(_ edit: TimelineCaptionTiming) -> Bool {
        document.map(edit.matches) ?? false
    }
    @discardableResult
    func commitTimelineTiming(_ edit: TimelineCaptionTiming, interval: MediaInterval) -> Bool {
        guard !isChangingClips, !isSavingCaptionStyle, !isSavingMusic, !isSavingMedia, !isEditingClipTrim else { return false }
        guard let project = document else { return false }
        do {
            guard edit.matches(project), selectedCueID == edit.cueID,
                  workspace.timelineCueID == edit.cueID else { throw TimelineTimingError.changed }
            if interval == edit.original { commandError = nil; return true }
            try edit.validate(interval, in: project)
            if var manual = edit.manual {
                manual.interval = interval
                return performManual(ManualCaptionPatch(id: manual.id, before: edit.manual, after: manual))
            }
            return perform { state, project in
                if edit.operation == .move { try CaptionEdits.moveCue(interval, cueID: edit.cueID, project: project, in: &state) }
                else { try CaptionEdits.cueTiming(interval, cueID: edit.cueID, project: project, in: &state) }
                return nil
            }
        } catch { commandError = error.localizedDescription; return false }
    }

    func retimeCue(_ interval: MediaInterval) {
        guard !isChangingClips, !isSavingCaptionStyle, !isSavingMusic, !isSavingMedia, !isEditingClipTrim else { return }
        if let manual = selectedManualCaption { retimeManual(manual, to: interval); return }
        guard let id = selectedCueID else { return }
        perform { state, project in
            try CaptionEdits.cueTiming(interval, cueID: id, project: project, in: &state)
            return nil
        }
    }
    func retimeWord(_ interval: MediaInterval) {
        guard !isChangingClips, !isSavingCaptionStyle, !isSavingMusic, !isSavingMedia, !isEditingClipTrim else { return }
        if let manual = selectedManualCaption { retimeManual(manual, to: interval); return }
        guard let id = selectedWordID else { return }
        perform { state, project in
            try CaptionEdits.wordTiming(interval, wordID: id, project: project, in: &state)
            return nil
        }
    }
    func split() {
        guard !isChangingClips, !isSavingCaptionStyle, !isSavingMusic, !isSavingMedia, !isEditingClipTrim else { return }
        guard let cue = selectedCueID, let word = selectedWordID else { return }
        perform { state, _ in try CaptionEdits.split(cueID: cue, before: word, in: &state) }
    }
    func mergeNext() {
        guard !isChangingClips, !isSavingCaptionStyle, !isSavingMusic, !isSavingMedia, !isEditingClipTrim else { return }
        guard let id = selectedCueID else { return }
        guard canMergeNext else { commandError = CaptionEditError.mergeBoundary.localizedDescription; return }
        perform { state, _ in try CaptionEdits.mergeNext(cueID: id, in: &state); return nil }
    }

    @discardableResult
    func addManualCaption(text: String, clipID: UUID, interval: MediaInterval) -> Bool {
        guard !isChangingClips, !isSavingCaptionStyle, !isSavingMusic, !isSavingMedia, !isEditingClipTrim else { return false }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { commandError = ManualCaptionError.emptyText.localizedDescription; return false }
        guard (document?.manualCaptions?.count ?? 0) < 10_000 else {
            commandError = ManualCaptionError.limit.localizedDescription; return false
        }
        let value = ManualCaption(id: UUID(), clipID: clipID, text: text, interval: interval)
        return performManual(ManualCaptionPatch(id: value.id, before: nil, after: value))
    }

    func deleteManualCaption(_ id: UUID) {
        guard !isChangingClips, !isSavingCaptionStyle, !isSavingMusic, !isSavingMedia, !isEditingClipTrim else { return }
        guard let caption = document?.manualCaptions?.first(where: { $0.id == id }) else { return }
        _ = performManual(ManualCaptionPatch(id: id, before: caption, after: nil))
    }

    private func editManualText(_ caption: ManualCaption, value: String) -> Bool {
        var next = caption; next.text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return performManual(ManualCaptionPatch(id: caption.id, before: caption, after: next), coalescingText: true)
    }
    private func retimeManual(_ caption: ManualCaption, to interval: MediaInterval) {
        var next = caption; next.interval = interval
        _ = performManual(ManualCaptionPatch(id: caption.id, before: caption, after: next))
    }

    @discardableResult
    private func performManual(_ patch: ManualCaptionPatch, coalescingText: Bool = false) -> Bool {
        guard !isChangingClips, !isSavingCaptionStyle, !isSavingMusic, !isSavingMedia, !isEditingClipTrim else { return false }
        guard let project = document else { return false }
        guard patch.before != patch.after else { commandError = nil; return true }
        do {
            var next = try patch.applying(to: project, forward: true)
            next.schemaVersion = ProjectSchema.current
            try next.validate()
            pause(); endStyleEditing(); endMediaEditing()
            let selection = Selection(cue: selectedCueID, word: selectedWordID)
            document = next
            if patch.after != nil { selectedCueID = patch.id; selectedWordID = patch.id }
            rebuildSnapshot(); repairSelection()
            let finalSelection = Selection(cue: selectedCueID, word: selectedWordID)
            if coalescingText, typingWordID == patch.id, !editHistory.past.isEmpty, editHistory.future.isEmpty,
               editHistory.past[editHistory.past.count - 1].change.coalesceManualText(patch) {
                editHistory.past[editHistory.past.count - 1].selectionAfter = finalSelection
            } else {
                editHistory.past.append(History(change: .manual(patch), selectionBefore: selection, selectionAfter: finalSelection))
            }
            typingWordID = coalescingText ? patch.id : nil
            finishHistoryEdit(); commandError = nil; changed()
            return true
        } catch { commandError = error.localizedDescription; return false }
    }

    @discardableResult
    private func perform(coalescing wordID: UUID? = nil,
                         _ edit: (inout CaptionEditState, ProjectDocument) throws -> UUID?) -> Bool {
        guard !isChangingClips, !isSavingCaptionStyle, !isSavingMusic, !isSavingMedia, !isEditingClipTrim else { return false }
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
        guard canUndo, let history = editHistory.past.last else { return }
        if case .clips = history.change {
            Task { await restoreClipHistory(history, forward: false) }
            return
        }
        if restore(history.change, forward: false, selection: history.selectionBefore) {
            editHistory.past.removeLast(); editHistory.future.append(history); updateHistoryFlags()
        }
    }
    func redo() {
        guard canRedo, let history = editHistory.future.last else { return }
        if case .clips = history.change {
            Task { await restoreClipHistory(history, forward: true) }
            return
        }
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
    private func historyAdmitted(_ entry: History?) -> Bool {
        guard !isChangingClips, !isSavingCaptionStyle, !isSavingMusic, !isSavingMedia, !isEditingClipTrim, let entry else { return false }
        if case .clips = entry.change { return canChangeClips }
        return true
    }
    private func updateHistoryFlags() {
        func available(_ entry: History?, forward: Bool) -> Bool {
            guard let entry else { return false }
            if case .clips(let before, let after) = entry.change {
                guard let document else { return false }
                return ClipGraphState(document) == (forward ? before : after)
            }
            return true
        }
        hasUndo = available(editHistory.past.last, forward: false)
        hasRedo = available(editHistory.future.last, forward: true)
    }
    private func rebuildSnapshot() {
        snapshot = document.map { CaptionSnapshot($0) }
        if let document, let snapshot { timelineSnapshot = ProjectTimelineSnapshot(document: document, captions: snapshot) }
        else { timelineSnapshot = nil }
        updateHistoryFlags()
    }
    private func repairSelection() {
        if timelineSnapshot?.captions.contains(where: { $0.id == workspace.timelineCueID }) != true {
            workspace.timelineCueID = nil
        }
        if timelineSnapshot?.clips.contains(where: { $0.id == workspace.timelineClipID }) != true {
            workspace.timelineClipID = nil
        }
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
        guard !isChangingClips, !isSavingCaptionStyle, !isSavingMusic, !isSavingMedia, !isEditingClipTrim else { throw ClipGraphError.busy }
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
                // Source-changing Undo may previously have failed its save.
                // A successful Retry must also rebuild with the restored song.
                if base.music?.asset != saved.music?.asset { refreshMediaPreview() }
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
            edits: document.effectiveMediaEdits, clipMedia: Dictionary(uniqueKeysWithValues: (document.clipSettings ?? []).filter { !$0.media.isEmpty }.map { ($0.id, $0.media) }),
            clipTrims: Dictionary(uniqueKeysWithValues: (document.clipSettings ?? []).compactMap { value in value.sourceTrim.map { (value.id, $0) } }),
            music: document.music, originalAudioMuted: document.isOriginalAudioMuted)
        guard key != preparedMedia else {
            if loadGeneration == generation { isPreparingPreview = false }
            return
        }
        pause()
        isPreparingPreview = true
        previewError = nil
        defer { if loadGeneration == generation { isPreparingPreview = false } }
        do {
            try Task.checkCancellation()
            let item = try await PreviewComposition.make(document: document, urls: urls)
            try Task.checkCancellation()
            guard loadGeneration == generation else { return }
            statusObserver = nil
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            let playbackID = UUID()
            playbackGeneration = playbackID
            previewFrames.attach(to: item)
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
        } catch is CancellationError {
            // Never attach a cancelled composition or present a spurious error.
        } catch {
            guard !Task.isCancelled, loadGeneration == generation else { return }
            previewFrames.reset()
            player.replaceCurrentItem(with: nil)
            previewGeneration = UUID()
            preparedMedia = nil
            previewError = error.localizedDescription
        }
    }

    private func observeTimeIfNeeded() {
        if defaultPlaybackRateObserver == nil {
            defaultPlaybackRateObserver = player.observe(\.defaultRate, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.defaultPlaybackRateObserver != nil else { return }
                    let rate = self.player.defaultRate
                    guard rate.isFinite, rate > 0 else { return }
                    self.previewPlaybackSpeed = rate
                }
            }
        }
        if playbackRateObserver == nil {
            playbackRateObserver = player.observe(\.rate, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.playbackRateObserver != nil else { return }
                    let rate = self.player.rate
                    guard rate.isFinite, rate > 0 else { return }
                    // Also retain speed chosen through AVKit's native controls.
                    self.previewPlaybackSpeed = rate
                    self.player.defaultRate = rate
                }
            }
        }
        if playbackStateObserver == nil {
            playbackStateObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.playbackStateObserver != nil else { return }
                    // AVKit's native controls operate on the player directly.
                    self.isPlaying = self.player.timeControlStatus != .paused
                }
            }
        }
        guard periodicObserver == nil else { return }
        periodicObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.periodicObserver != nil, !self.isSeeking, !self.isPreparingPreview,
                      let time = try? MediaTime(validating: self.player.currentTime()) else { return }
                self.previewFrames.sample(at: time.cmTime)
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
                    self.previewFrames.sample(at: actual.cmTime)
                    self.time = min(actual, self.duration)
                }
            }
        }
    }
    func scrub(seconds: Double) {
        pause()
        if let value = try? EditorTime.stamp(seconds) { seek(to: value) }
    }

    /// Preview and export compositions use a 30 fps output clock. Seek inside
    /// the last frame rather than to duration, which has no displayable frame.
    private var previewEndTime: MediaTime {
        let frames = CMTimeConvertScale(duration.cmTime, timescale: 30, method: .roundAwayFromZero)
        guard frames.isNumeric, frames.value > 0 else { return .zero }
        return (try? MediaTime(validating: CMTime(value: frames.value - 1, timescale: 30))) ?? .zero
    }

    func jumpToStart() {
        guard !isEditingClipTrim, !isPreparingPreview, previewError == nil, player.currentItem != nil else { return }
        pause()
        seek(to: .zero)
    }

    func jumpToEnd() {
        guard !isEditingClipTrim, !isPreparingPreview, previewError == nil, player.currentItem != nil else { return }
        pause()
        seek(to: previewEndTime)
    }

    func setPreviewPlaybackSpeed(_ speed: Float) {
        guard Self.previewPlaybackSpeeds.contains(speed), !isEditingClipTrim, !isPreparingPreview,
              previewError == nil, player.currentItem != nil else { return }
        previewPlaybackSpeed = speed
        // play() uses defaultRate on resume; changing speed while paused must
        // not start playback. This state never enters saved/export documents.
        player.defaultRate = speed
        if player.timeControlStatus != .paused { player.rate = speed }
    }

    func togglePlayback() {
        if isPlaying { pause(); return }
        guard player.currentItem != nil, previewError == nil, !isPreparingPreview else { return }
        endTyping()
        if time >= previewEndTime { seek(to: .zero) }
        isPlaying = true
        player.play()
    }
    func pause() {
        previewFrames.sample(at: player.currentTime())
        player.pause(); isPlaying = false
    }

    /// Preserve native seeks and the matching caption clock before a live handoff.
    func holdPreviewFrame() {
        guard player.currentItem != nil, let actual = try? MediaTime(validating: player.currentTime()) else { return }
        time = min(actual, duration)
        _ = previewFrames.capture(at: actual.cmTime, snapshot: snapshot, presentationTime: time)
    }

    /// Invalidate editor-owned work immediately. Never touches the processing
    /// coordinator, transcription engine, export jobs, saves or project storage.
    func cancelPreparation() {
        clipTrimPreview?.close(); clipTrimPreview = nil
        mediaRefresh?.cancel(); mediaRefresh = nil
        loadGeneration = UUID()
        isPreparingPreview = false
        isLoading = false
        pause()
    }

    /// Explicit lifecycle teardown, before this session releases its AVPlayer.
    func stop() {
        isPresented = false
        cancelPreparation()
        seekGeneration = UUID()
        isSeeking = false
        if let periodicObserver { player.removeTimeObserver(periodicObserver); self.periodicObserver = nil }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        statusObserver = nil
        playbackStateObserver = nil
        playbackRateObserver = nil
        defaultPlaybackRateObserver = nil
        playbackGeneration = UUID()
        preparedMedia = nil
        previewFrames.reset()
        player.replaceCurrentItem(with: nil)
        previewGeneration = UUID()
    }
}
