import Foundation
import Observation
import PDFKitAudio

nonisolated struct ProjectRuntimeItemState: Identifiable, Equatable, Sendable {
    let item: ProjectContentItem
    let resolved: ResolvedNarrationSettings
    let generationKey: String
    let pronunciationMode: PronunciationFallbackMode
    let generationStatus: ProjectItemGenerationStatus

    var id: UUID { item.id }
}

nonisolated enum ProjectRuntimePlaybackState: Equatable, Sendable {
    case idle
    case loading
    case warmingUp
    case synthesizing(current: Int, total: Int)
    case buffering
    case playing
    case paused
    case finished
    case failed(String)
}

nonisolated struct ProjectRuntimeActivity: Equatable, Sendable {
    var playbackState: ProjectRuntimePlaybackState
    var activeItemID: UUID?
    var queuedAudioBuffers: Int
    var queuedAudioDurationSeconds: Double
    var currentParagraphRange: AudioSourceRange?
    var currentParagraphIndex: Int?
    var currentChunkRange: AudioSourceRange?
    var currentChunkIndex: Int?
    var paragraphCount: Int
    var itemProgress: Double
    var projectProgress: Double
    var waitingGenerationJobs: Int
    var generatingJobs: Int
    var failedGenerationJobs: Int

    init(
        playbackState: ProjectRuntimePlaybackState = .idle,
        activeItemID: UUID? = nil,
        queuedAudioBuffers: Int = 0,
        queuedAudioDurationSeconds: Double = 0,
        currentParagraphRange: AudioSourceRange? = nil,
        currentParagraphIndex: Int? = nil,
        currentChunkRange: AudioSourceRange? = nil,
        currentChunkIndex: Int? = nil,
        paragraphCount: Int = 0,
        itemProgress: Double = 0,
        projectProgress: Double = 0,
        waitingGenerationJobs: Int = 0,
        generatingJobs: Int = 0,
        failedGenerationJobs: Int = 0
    ) {
        self.playbackState = playbackState
        self.activeItemID = activeItemID
        self.queuedAudioBuffers = queuedAudioBuffers
        self.queuedAudioDurationSeconds = queuedAudioDurationSeconds
        self.currentParagraphRange = currentParagraphRange
        self.currentParagraphIndex = currentParagraphIndex
        self.currentChunkRange = currentChunkRange
        self.currentChunkIndex = currentChunkIndex
        self.paragraphCount = paragraphCount
        self.itemProgress = itemProgress
        self.projectProgress = projectProgress
        self.waitingGenerationJobs = waitingGenerationJobs
        self.generatingJobs = generatingJobs
        self.failedGenerationJobs = failedGenerationJobs
    }

    var hasActivePlaybackWork: Bool {
        switch playbackState {
        case .loading, .warmingUp, .synthesizing, .buffering, .playing, .paused:
            return true
        case .idle, .finished, .failed:
            return false
        }
    }

    var hasAudiblePlayback: Bool {
        guard queuedAudioBuffers > 0 else { return false }
        switch playbackState {
        case .playing, .synthesizing: return true
        default: return false
        }
    }
}

@Observable
@MainActor
final class ProjectRuntime {
    let id: UUID
    let packageURL: URL
    let persistence: ProjectRuntimePersistenceBridge
    let queueController: ProjectQueueController
    let cacheCoordinator: ProjectCacheCoordinator
    let chunkCache: SharedChunkAudioCache

    var project: ProjectDocument?
    private(set) var manifest: ProjectContentManifest?
    private(set) var itemStates: [ProjectRuntimeItemState] = []
    private(set) var artworkURL: URL?
    var activity = ProjectRuntimeActivity()
    // Keeps retry/replay available after the audio queue has stopped.
    var playerItemID: UUID?
    // Presentation state is session-only; closing never clears the bookmark.
    var isPlayerDismissed = false
    var sleepTimerDeadline: Date?
    var stopsAtChapterEnd = false
    @ObservationIgnored var sleepTimerTask: Task<Void, Never>?
    private(set) var isLoading = false
    private(set) var didLoad = false
    private(set) var isInvalidatingAudio = false
    private var audioRecoveryRequired = false
    private var isShutdown = false
    var revision: UInt64 = 0
    var lastErrorMessage: String?
    private(set) var pdfReadingPolicy: PdfReadingPolicy = .listening
    private(set) var pdfReadingProjection: PDFReadingProjection?
    private(set) var isApplyingPDFReadingPolicy = false
    private(set) var isPreparingParsedOutput = false
    @ObservationIgnored private var parsedPreparationTask: Task<ParsedImportCache, Error>?

    /// Saved default text remains usable on a cache miss. Custom policies need
    /// a restored projection, never an implicit parse to make them ready.
    var isPDFReadingReady: Bool {
        project?.source.type != .pdf || pdfReadingProjection != nil || pdfReadingPolicy == .listening
    }

    @ObservationIgnored let pipeline: ReadAloudPipeline
    @ObservationIgnored weak var playbackCoordinator: ProjectRuntimeManager?
    @ObservationIgnored let hasProAccess:
        @MainActor () -> Bool
    @ObservationIgnored var synthesisSuspendedForMemoryPressure = false
    @ObservationIgnored var isReleasingSpeechMemory = false
    @ObservationIgnored var readingProgressIndex = ProjectReadingProgressIndex()
    @ObservationIgnored private var readerLayoutCache:
        (itemID: UUID, contentRevision: String, paragraphs: [ReaderParagraph])?
    @ObservationIgnored private var playerTextLengthCache:
        (itemID: UUID, contentRevision: String, length: Int)?
    @ObservationIgnored private var parsedOutputCache: ParsedImportCache?
    @ObservationIgnored var playbackTask: Task<Void, Never>?
    @ObservationIgnored private var retiringPlaybackTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var chunkBookmarkTask: Task<Void, Never>?
    @ObservationIgnored var playbackOperationID: UUID?
    @ObservationIgnored var readerPauseRequested = false
    @ObservationIgnored var finalAudioAsset:
        ProjectFinalAudioAsset?
    @ObservationIgnored var finalAudioPositionSeconds = 0.0
    @ObservationIgnored var finalAudioPlaybackOriginSeconds = 0.0
    @ObservationIgnored var interruptedPlaybackOperationID: UUID?
    @ObservationIgnored var prefetchScheduledItemIDs = Set<UUID>()
    @ObservationIgnored var prefetchTask: Task<Void, Never>?
    @ObservationIgnored var prefetchTaskID: UUID?
    @ObservationIgnored private var generationStateRefreshID: UUID?
    @ObservationIgnored private var didRecoverGenerationQueue = false
    @ObservationIgnored private var refreshGeneration: UInt64 = 0

    init(
        id: UUID,
        packageURL: URL,
        persistence: ProjectRuntimePersistenceBridge,
        hasPro:
            @escaping @MainActor () -> Bool
            = { false },
        pipeline: ReadAloudPipeline = ReadAloudPipeline()
    ) {
        self.id = id
        self.packageURL = packageURL.standardizedFileURL
        self.persistence = persistence
        self.hasProAccess = hasPro
        self.pipeline = pipeline
        self.queueController = ProjectQueueController()
        self.cacheCoordinator = ProjectCacheCoordinator(
            packageURL: packageURL.standardizedFileURL
        )
        self.chunkCache = SharedChunkAudioCache(
            packageURL: packageURL.standardizedFileURL
        )

        pipeline.onEvent = { [weak self] event in
            self?.handlePipelineEvent(event)
        }
        pipeline.onAudioSessionEvent = {
            [weak self] event in
            self?.handleAudioSessionEvent(event)
        }
    }

    var hasPro: Bool {
        hasProAccess()
    }

    var hasListeningIntent: Bool {
        activity.hasActivePlaybackWork && !isPlaybackPaused
    }

    var requiresGlobalPlaybackPriority: Bool {
        activity.hasActivePlaybackWork
            && (finalAudioAsset == nil || !ReadAloudPreferences.generateWhileListening)
    }

    var blocksQueuedGeneration: Bool {
        if isInvalidatingAudio || isApplyingPDFReadingPolicy || isPreparingParsedOutput || isShutdown || audioRecoveryRequired
            || !isPDFReadingReady { return true }
        if synthesisSuspendedForMemoryPressure { return true }
        guard activity
            .hasActivePlaybackWork
        else {
            return false
        }

        if finalAudioAsset == nil {
            return true
        }

        return !ReadAloudPreferences
                .generateWhileListening
    }

    var isBackgroundWorkActive: Bool {
        isPreparingParsedOutput || isInvalidatingAudio || !retiringPlaybackTasks.isEmpty
            || activity.hasActivePlaybackWork
            || queueController.hasExecutingWork
    }

    var resolvedProjectSettings: ResolvedNarrationSettings {
        NarrationSettingsResolver.resolveProject(
            project?.settings ?? ProjectNarrationSettings(),
            hasPro: hasPro
        )
    }

    var currentItemID: UUID? {
        activity.activeItemID
            ?? project?.playback?.currentItemID
    }

    var continueItemID: UUID? {
        if let currentItemID, itemState(currentItemID)?.item.text.isEmpty == false {
            return currentItemID
        }
        return itemStates.first(where: { !$0.item.text.isEmpty })?.id ?? itemStates.first?.id
    }

    func loadIfNeeded() async throws {
        guard !didLoad else { return }

        do {
            try await refresh()
            try await recoverGenerationQueueIfNeeded()
            try queueController.configure(
                runtime: self
            )
            queueController.reconcileScheduling()
        } catch {
            didLoad = false
            throw error
        }
    }

    private func recoverGenerationQueueIfNeeded() async throws {
        guard !didRecoverGenerationQueue, isPDFReadingReady else { return }
        _ = try await persistence.recoverGenerationQueue(
            generationKeys: Dictionary(uniqueKeysWithValues: itemStates.map { ($0.id, $0.generationKey) }),
            readyOfflineItemIDs: Set(itemStates.filter { $0.generationStatus.state == .readyOffline }.map(\.id))
        )
        didRecoverGenerationQueue = true
        try await refreshGenerationState()
    }

    /// Disk/memory lookup only. A miss is handled by an explicit UI preparation
    /// action in pass 3; neither this method nor background work can parse.
    private func cachedParsedOutputIfNeeded() async throws -> ParsedImportCache {
        try await loadIfNeeded()
        guard let project else { throw ParsedOutputPreparationError.unavailable }
        if let cached = parsedOutputCache, cached.matches(project.source) { return cached }
        try ReadAloudSafety.requireMemoryHeadroom()
        guard let cached = try await persistence.loadParsedOutput(),
              cached.matches(project.source) else {
            throw ParsedOutputPreparationError.unavailable
        }
        parsedOutputCache = cached
        return cached
    }

    func preparePDFReadingOptions() async throws {
        try await loadIfNeeded()
        guard project?.source.type == .pdf, pdfReadingProjection == nil else { return }
        _ = try await cachedParsedOutputIfNeeded()
        try await refresh()
        guard pdfReadingProjection != nil else { throw ParsedOutputPreparationError.unavailable }
        try await recoverGenerationQueueIfNeeded()
        queueController.reconcileScheduling()
    }

    /// Called only by the visible preparation sheet's Start button. No loader,
    /// queue, lifecycle or automatic-resume path invokes this method.
    func prepareParsedOutputFromUser(
        progress: @escaping ParsedOutputProgress,
        parse: ParsedOutputParseOperation? = nil
    ) async throws {
        guard !isShutdown, !isPreparingParsedOutput,
              !isApplyingPDFReadingPolicy, !isInvalidatingAudio else {
            throw ProjectStoreError.invalidData("Previous processing is still stopping. Try again shortly.")
        }
        try ReadAloudSafety.requireMemoryHeadroom()
        isPreparingParsedOutput = true
        queueController.reconcileScheduling()
        defer {
            parsedPreparationTask = nil
            isPreparingParsedOutput = false
            queueController.reconcileScheduling()
        }
        progress(ReadAloudImportProgress(stage: .preparing, fractionCompleted: nil))
        let source = try await persistence.parsedOutputSource()
        try Task.checkCancellation()
        guard !isShutdown else { throw CancellationError() }
        let importer = ReadAloudImportCoordinator(projectStore: persistence.store)
        let operation: ParsedOutputParseOperation = parse ?? { source, progress in
            try await importer.parseRetainedOutput(source, progress: progress)
        }
        let worker = Task.detached(priority: .userInitiated) {
            let cache = try await operation(source, progress)
            try Task.checkCancellation()
            if source.project.source.type == .pdf {
                guard try PDFReadingProjection.cached(
                    cache, items: source.items, projectID: source.project.id,
                    policy: source.project.pdfReadingPolicy ?? .listening
                ) != nil else { throw ParsedOutputPreparationError.unavailable }
            }
            return cache
        }
        parsedPreparationTask = worker
        let cache = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        try Task.checkCancellation()
        guard !worker.isCancelled, !isShutdown, !isReleasingSpeechMemory,
              project?.source == source.project.source else { throw CancellationError() }
        // Publish only complete output after old book work has drained. Source,
        // saved text and the manifest are never replaced by this operation.
        try await withAudioInvalidation {
            try Task.checkCancellation()
            guard !worker.isCancelled, !isShutdown else { throw CancellationError() }
            progress(ReadAloudImportProgress(stage: .persisting, fractionCompleted: nil))
            try await persistence.saveParsedOutput(cache)
            try Task.checkCancellation()
            guard !worker.isCancelled, !isShutdown else { throw CancellationError() }
            parsedOutputCache = cache
            try await refresh()
            try await recoverGenerationQueueIfNeeded()
        }
        try Task.checkCancellation()
        progress(ReadAloudImportProgress(stage: .finished, fractionCompleted: 1))
    }

    func cancelParsedOutputPreparation() {
        parsedPreparationTask?.cancel()
    }

    /// Only explicit controls call this. The presenter registry refuses a
    /// request without an active visible host; it never queues one for later.
    @discardableResult
    func offerParsedPreparationForUserAction(
        _ retry: @escaping @MainActor () async throws -> Void
    ) throws -> Bool {
        guard let playbackCoordinator,
              playbackCoordinator.offerParsedPreparation(runtime: self, retry: retry) else {
            throw ParsedOutputPreparationError.unavailable
        }
        return true
    }

    /// Persist the policy per project and publish the fully computed reader
    /// projection only after the durable metadata write succeeds.
    func applyPDFReadingPolicy(_ policy: PdfReadingPolicy) async throws {
        guard project?.source.type == .pdf else {
            throw ProjectStoreError.invalidData("Reading options require a PDF.")
        }
        guard !isApplyingPDFReadingPolicy, !isPreparingParsedOutput else {
            throw ProjectStoreError.invalidData("Book content is being prepared. Try again shortly.")
        }
        if policy == pdfReadingPolicy, pdfReadingProjection != nil { return }
        isApplyingPDFReadingPolicy = true
        defer {
            isApplyingPDFReadingPolicy = false
            queueController.reconcileScheduling()
        }

        let cache: ParsedImportCache
        do {
            cache = try await cachedParsedOutputIfNeeded()
        } catch is ParsedOutputPreparationError {
            try offerParsedPreparationForUserAction { [self] in try await applyPDFReadingPolicy(policy) }
            return
        }
        let sourceRevision = project?.source.sourceRevision
        let items = itemStates.map(\.item)
        let projectID = id
        let task = Task.detached(priority: .userInitiated) {
            try PDFReadingProjection.cached(cache, items: items, projectID: projectID, policy: policy)
        }
        let candidate: PDFReadingProjection?
        do {
            candidate = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Decodable but unusable block/chapter mappings require the same
            // explicit preparation as a missing sidecar.
            parsedOutputCache = nil
            try offerParsedPreparationForUserAction { [self] in try await applyPDFReadingPolicy(policy) }
            return
        }
        guard let projection = candidate else {
            parsedOutputCache = nil
            try offerParsedPreparationForUserAction { [self] in try await applyPDFReadingPolicy(policy) }
            return
        }
        try Task.checkCancellation()
        guard project?.source.sourceRevision == sourceRevision else {
            throw CancellationError()
        }

        let current = itemStates.map(\.item).sorted { $0.order < $1.order }
        let projected = projection.items.sorted { $0.order < $1.order }
        let sameContent = current.count == projected.count
            && zip(current, projected).allSatisfy { old, new in
                old.id == new.id && old.order == new.order
                    && old.contentRevision == new.contentRevision
                    && old.text == new.text
            }
        if sameContent {
            // A policy whose spoken output is identical keeps its playback,
            // exact bookmarks, generated audio and in-progress jobs intact.
            let updated = try await persistence.updatePDFReadingPolicy(policy, parsedCache: cache)
            project = updated
            pdfReadingPolicy = policy
            pdfReadingProjection = projection
            try await recoverGenerationQueueIfNeeded()
            revision &+= 1
            return
        }

        let previousByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0.contentRevision) })
        let projectedByID = Dictionary(uniqueKeysWithValues: projected.map { ($0.id, $0.contentRevision) })
        let changedIDs = Set(previousByID.keys).union(projectedByID.keys).filter {
            previousByID[$0] != projectedByID[$0]
        }
        try await withAudioInvalidation(itemIDs: Set(changedIDs), persistCheckpoint: false) {
            queueController.shutdown()
            do {
                _ = try await persistence.updatePDFReadingPolicy(policy, parsedCache: cache)
                _ = try await persistence.removeGenerationJobs(
                    itemIDs: Set(changedIDs), states: [.queued, .generating, .failed]
                )
                try await refresh()
                let active = itemStates.map(\.item).sorted { $0.order < $1.order }
                guard active.count == projected.count,
                      zip(active, projected).allSatisfy({ actual, expected in
                          actual.id == expected.id
                              && actual.contentRevision == expected.contentRevision
                              && actual.text == expected.text
                      }) else {
                    throw ProjectStoreError.invalidData(
                        "The refreshed PDF reading content did not match its projection."
                    )
                }
                pdfReadingPolicy = policy
                pdfReadingProjection = projection
                try await recoverGenerationQueueIfNeeded()
                try queueController.configure(runtime: self)
                queueController.reconcileScheduling()
                revision &+= 1
            } catch {
                // Reload whichever policy was committed and keep old work
                // drained until the matching effective text is restored.
                pdfReadingProjection = nil
                do {
                    try await refresh()
                    try queueController.configure(runtime: self)
                } catch {
                    lastErrorMessage = Self.message(for: error)
                }
                throw error
            }
        }
    }

    func refresh() async throws {
        refreshGeneration &+= 1
        generationStateRefreshID = nil
        let generation = refreshGeneration
        isLoading = true

        do {
            try Task.checkCancellation()

            let loaded = try await persistence.load()
            guard loaded.project.id == id else {
                throw ProjectStoreError.identityMismatch(
                    expected: id,
                    found: loaded.project.id
                )
            }

            try Task.checkCancellation()

            let readingProgress = try await ProjectReadingProgressIndex.make(in: loaded.items)

            let runtimeRevision =
                try ReadAloudSynthesisContract.runtimeRevision()

            let pronunciationMode = ReadAloudPreferences.pronunciationFallbackMode
            var prepared: [(
                item: ProjectContentItem,
                resolved: ResolvedNarrationSettings,
                generationKey: String
            )] = []
            prepared.reserveCapacity(loaded.items.count)

            var requests: [ProjectGenerationStatusRequest] = []
            requests.reserveCapacity(loaded.items.count)

            for item in loaded.items.sorted(by: { $0.order < $1.order }) {
                try Task.checkCancellation()

                let resolved = try NarrationSettingsResolver.resolve(
                    item: item.settings,
                    project: loaded.project.settings,
                    hasPro: hasPro
                )
                let generationKey =
                    try ReadAloudSynthesisContract.generationKey(
                        item: item,
                        resolved: resolved,
                        runtimeRevision: runtimeRevision,
                        pronunciationMode: pronunciationMode
                    )

                prepared.append(
                    (item, resolved, generationKey)
                )
                requests.append(
                    ProjectGenerationStatusRequest(
                        itemID: item.id,
                        generationKey: generationKey,
                        contentRevision: item.contentRevision,
                        voiceID: resolved.voiceID,
                        speed: resolved.speed
                    )
                )
            }

            let generationState = try await persistence.generationState(
                requests: requests
            )
            try Task.checkCancellation()

            guard generation == refreshGeneration else {
                return
            }

            if project?.source != loaded.project.source { parsedOutputCache = nil }
            pdfReadingPolicy = loaded.project.pdfReadingPolicy ?? .listening
            pdfReadingProjection = loaded.hasParsedPDFOutput ? PDFReadingProjection(
                items: loaded.items,
                textByItemID: Dictionary(uniqueKeysWithValues: loaded.items.map { ($0.id, $0.text) }),
                paragraphsByItemID: [:]
            ) : nil
            project = loaded.project
            manifest = loaded.manifest
            readingProgressIndex = readingProgress
            generationStateRefreshID = nil
            activity.projectProgress =
                loaded.project.playback?.projectProgress ?? 0
            itemStates = prepared.map {
                ProjectRuntimeItemState(
                    item: $0.item,
                    resolved: $0.resolved,
                    generationKey: $0.generationKey,
                    pronunciationMode: pronunciationMode,
                    generationStatus:
                        generationState.statuses[$0.item.id] ?? .notGenerated
                )
            }
            audioRecoveryRequired = false
            queueController.publish(generationState.queue)
            activity.waitingGenerationJobs =
                queueController.waitingCount
            activity.generatingJobs =
                queueController.generatingCount
            activity.failedGenerationJobs =
                queueController.failedCount
            artworkURL = makeArtworkURL(project: loaded.project)
            lastErrorMessage = nil
            didLoad = true
            isLoading = false
            revision &+= 1
            queueController.reconcileScheduling()
            ProjectSystemMediaController
                .shared
                .publish(self)
        } catch {
            guard generation == refreshGeneration else {
                return
            }

            isLoading = false
            didLoad = true
            lastErrorMessage = Self.message(for: error)
            throw error
        }
    }

    // Queue-only changes must not retain a second decoded copy of a long EPUB
    // while models are loading or speech is running. Keep content/settings and
    // the live playback bookmark owned by the existing runtime.
    func refreshGenerationState() async throws {
        guard didLoad else { return }
        let contentGeneration = refreshGeneration
        let requestID = UUID()
        generationStateRefreshID = requestID
        let requests = itemStates.map {
            ProjectGenerationStatusRequest(
                itemID: $0.id, generationKey: $0.generationKey,
                contentRevision: $0.item.contentRevision,
                voiceID: $0.resolved.voiceID, speed: $0.resolved.speed
            )
        }
        let loaded = try await persistence.generationState(requests: requests)
        try Task.checkCancellation()
        guard contentGeneration == refreshGeneration,
              generationStateRefreshID == requestID else { return }
        itemStates = itemStates.map {
            ProjectRuntimeItemState(
                item: $0.item, resolved: $0.resolved, generationKey: $0.generationKey,
                pronunciationMode: $0.pronunciationMode,
                generationStatus: loaded.statuses[$0.id] ?? .notGenerated
            )
        }
        queueController.publish(loaded.queue)
        activity.waitingGenerationJobs = queueController.waitingCount
        activity.generatingJobs = queueController.generatingCount
        activity.failedGenerationJobs = queueController.failedCount
        revision &+= 1
    }

    func refreshForExternalPreferencesChange()
        async
    {
        let selectedEngine = ReadAloudPreferences.speechEngine
        let engineChanged = pipeline.engineKind != selectedEngine

        guard let project else {
            if engineChanged {
                await pipeline.selectEngine(selectedEngine)
            }
            try? await refresh()
            return
        }

        var affectedItemIDs =
            engineChanged ? Set(itemStates.map(\.id)) : Set<UUID>()

        for state in itemStates {
            do {
                let resolved =
                    try NarrationSettingsResolver
                        .resolve(
                            item:
                                state.item
                                    .settings,
                            project:
                                project
                                    .settings,
                            hasPro: hasPro
                        )
                let generationKey = try ReadAloudSynthesisContract.generationKey(
                    item: state.item, resolved: resolved
                )
                if resolved != state.resolved || generationKey != state.generationKey {
                    affectedItemIDs
                        .insert(
                            state.id
                        )
                }
            } catch {
                lastErrorMessage =
                    Self.message(
                        for: error
                    )
                return
            }
        }

        do {
            try await withAudioInvalidation(itemIDs: affectedItemIDs) {
                if engineChanged {
                    queueController.shutdown()
                    await pipeline.selectEngine(selectedEngine)
                }
                if !affectedItemIDs.isEmpty {
                    _ = try await persistence.removeGenerationJobs(
                        itemIDs: affectedItemIDs,
                        states: [.queued, .generating, .failed]
                    )
                }
                try await refresh()
                if engineChanged { try queueController.configure(runtime: self) }
            }
        } catch {
            lastErrorMessage = Self.message(for: error)
        }
    }

    func persistPlayback(
        _ playback: ProjectPlaybackState?
    ) async throws {
        try await persistence.updatePlayback(playback)
        try await refresh()
    }

    func updateProjectVoice(_ voiceID: String?) async throws {
        if let voiceID,
           !ReadAloudAccessPolicy
            .canUseVoice(
                voiceID,
                hasPro: hasPro
            )
        {
            throw ReadAloudAccessError
                .requiresPro(
                    .advancedVoices
                )
        }

        guard let project else {
            throw ProjectStoreError.projectNotFound(id)
        }
        var settings = project.settings
        settings.voiceID = voiceID
        let affectedItemIDs =
            try narrationAffectedItemIDs(
                from: project.settings,
                to: settings
            )
        try await withAudioInvalidation(itemIDs: affectedItemIDs) {
            try await persistence.updateProjectSettings(settings)
            if !affectedItemIDs.isEmpty {
                _ = try await persistence
                    .removeGenerationJobs(
                        itemIDs:
                            affectedItemIDs,
                        states: [
                            .queued,
                            .generating,
                            .failed,
                        ]
                    )
            }
            try await refresh()
        }
    }

    func updateProjectSpeed(_ speed: Double?) async throws {
        if let speed, !ReadAloudNarrationCatalog.isSupportedSpeed(speed) {
            throw ProjectStoreError.invalidData(
                "Synthesis speed must be between 0.5× and 2.0× in steps of 0.1."
            )
        }
        guard let project else {
            throw ProjectStoreError.projectNotFound(id)
        }
        var settings = project.settings
        settings.speed = speed
        let affectedItemIDs =
            try narrationAffectedItemIDs(
                from: project.settings,
                to: settings
            )
        try await withAudioInvalidation(itemIDs: affectedItemIDs) {
            try await persistence.updateProjectSettings(settings)
            if !affectedItemIDs.isEmpty {
                _ = try await persistence
                    .removeGenerationJobs(
                        itemIDs:
                            affectedItemIDs,
                        states: [
                            .queued,
                            .generating,
                            .failed,
                        ]
                    )
            }
            try await refresh()
        }
    }

    func updateItemVoiceMode(
        itemID: UUID,
        mode: ItemSettingMode
    ) async throws {
        guard let entry = itemState(itemID) else {
            throw ProjectStoreError.invalidData(
                "Runtime item is unavailable."
            )
        }
        var settings = entry.item.settings
        settings.voice.mode = mode

        if mode == .custom,
           settings.voice.customValue == nil {
            settings.voice.customValue = entry.resolved.voiceID
        }

        let changed = try itemNarrationChanges(
            from: entry.item.settings, to: settings
        )
        try await withAudioInvalidation(itemIDs: changed ? [itemID] : []) {
            try await persistence.updateItemSettings(
                itemID: itemID,
                settings: settings
            )
            _ = try await persistence
                .removeGenerationJobs(
                    itemIDs: [itemID],
                    states: [
                        .queued,
                        .generating,
                        .failed,
                    ]
                )
            try await refresh()
        }
    }

    func updateItemVoice(
        itemID: UUID,
        voiceID: String
    ) async throws {

        guard let entry = itemState(itemID) else {
            throw ProjectStoreError.invalidData(
                "Runtime item is unavailable."
            )
        }
        guard ReadAloudAccessPolicy
            .canUseVoice(
                voiceID,
                hasPro: hasPro
            )
        else {
            throw ReadAloudAccessError
                .requiresPro(
                    .advancedVoices
                )
        }

        var settings = entry.item.settings
        settings.voice.mode = .custom
        settings.voice.customValue = voiceID

        let changed = try itemNarrationChanges(
            from: entry.item.settings, to: settings
        )
        try await withAudioInvalidation(itemIDs: changed ? [itemID] : []) {
            try await persistence.updateItemSettings(
                itemID: itemID,
                settings: settings
            )
            _ = try await persistence
                .removeGenerationJobs(
                    itemIDs: [itemID],
                    states: [
                        .queued,
                        .generating,
                        .failed,
                    ]
                )
            try await refresh()
        }
    }

    func updateItemSpeedMode(
        itemID: UUID,
        mode: ItemSettingMode
    ) async throws {
        guard let entry = itemState(itemID) else {
            throw ProjectStoreError.invalidData(
                "Runtime item is unavailable."
            )
        }
        var settings = entry.item.settings
        settings.speed.mode = mode

        if mode == .custom,
           settings.speed.customValue == nil {
            settings.speed.customValue = entry.resolved.speed
        }

        let changed = try itemNarrationChanges(
            from: entry.item.settings, to: settings
        )
        try await withAudioInvalidation(itemIDs: changed ? [itemID] : []) {
            try await persistence.updateItemSettings(
                itemID: itemID,
                settings: settings
            )
            _ = try await persistence
                .removeGenerationJobs(
                    itemIDs: [itemID],
                    states: [
                        .queued,
                        .generating,
                        .failed,
                    ]
                )
            try await refresh()
        }
    }

    func updateItemSpeed(
        itemID: UUID,
        speed: Double
    ) async throws {
        guard ReadAloudNarrationCatalog.isSupportedSpeed(speed) else {
            throw ProjectStoreError.invalidData(
                "Synthesis speed must be between 0.5× and 2.0× in steps of 0.1."
            )
        }

        guard let entry = itemState(itemID) else {
            throw ProjectStoreError.invalidData(
                "Runtime item is unavailable."
            )
        }
        var settings = entry.item.settings
        settings.speed.mode = .custom
        settings.speed.customValue = speed

        let changed = try itemNarrationChanges(
            from: entry.item.settings, to: settings
        )
        try await withAudioInvalidation(itemIDs: changed ? [itemID] : []) {
            try await persistence.updateItemSettings(
                itemID: itemID,
                settings: settings
            )
            _ = try await persistence
                .removeGenerationJobs(
                    itemIDs: [itemID],
                    states: [
                        .queued,
                        .generating,
                        .failed,
                    ]
                )
            try await refresh()
        }
    }

    private func narrationAffectedItemIDs(
        from oldSettings:
            ProjectNarrationSettings,
        to newSettings:
            ProjectNarrationSettings
    ) throws -> Set<UUID> {
        var affected = Set<UUID>()

        for state in itemStates {
            let oldResolved =
                try NarrationSettingsResolver
                    .resolve(
                        item:
                            state.item.settings,
                        project:
                            oldSettings,
                        hasPro: hasPro
                    )
            let newResolved =
                try NarrationSettingsResolver
                    .resolve(
                        item:
                            state.item.settings,
                        project:
                            newSettings,
                        hasPro: hasPro
                    )

            if oldResolved != newResolved {
                affected.insert(state.id)
            }
        }

        return affected
    }

    private func itemNarrationChanges(
        from oldSettings: ItemNarrationSettings,
        to newSettings: ItemNarrationSettings
    ) throws -> Bool {
        guard let project else { throw ProjectStoreError.projectNotFound(id) }
        let oldResolved = try NarrationSettingsResolver.resolve(
            item: oldSettings, project: project.settings, hasPro: hasPro
        )
        let newResolved = try NarrationSettingsResolver.resolve(
            item: newSettings, project: project.settings, hasPro: hasPro
        )
        return oldResolved != newResolved
    }

    func enqueueGeneration(
        itemID: UUID,
        regenerate: Bool
    ) async throws {
        if !isPDFReadingReady {
            try offerParsedPreparationForUserAction { [self] in
                try await enqueueGeneration(itemID: itemID, regenerate: regenerate)
            }
            return
        }
        try prepareExplicitWork()
        guard let entry = itemState(itemID) else {
            throw ProjectStoreError.invalidData(
                "Runtime item is unavailable."
            )
        }
        guard !entry.item.text.isEmpty else {
            throw ProjectStoreError.invalidData("This chapter has no text under the selected reading options.")
        }

        try await persistence.enqueueGeneration(
            [
                ProjectGenerationRequest(
                    itemID: itemID,
                    generationKey: entry.generationKey
                )
            ],
            replaceExisting: regenerate
        )
        try await refresh()
    }

    func enqueueRemainingGeneration() async throws {
        if !isPDFReadingReady {
            try offerParsedPreparationForUserAction { [self] in try await enqueueRemainingGeneration() }
            return
        }
        try prepareExplicitWork()
        let requests: [ProjectGenerationRequest] = itemStates.compactMap { entry -> ProjectGenerationRequest? in
            guard !entry.item.text.isEmpty else { return nil }
            switch entry.generationStatus.state {
            case .readyOffline, .generating, .waiting:
                return nil
            case .notGenerated, .needsAttention:
                return ProjectGenerationRequest(
                    itemID: entry.id,
                    generationKey: entry.generationKey
                )
            }
        }

        guard !requests.isEmpty else { return }

        try await persistence.enqueueGeneration(
            requests,
            replaceExisting: false
        )
        try await refresh()
    }

    /// Hold cache admission closed across the complete storage mutation.
    /// Drain complete generation jobs as well as chunk producers so a final
    /// WAV commit cannot recreate audio after Clear or project deletion.
    func withAudioInvalidation<T>(
        itemIDs: Set<UUID>? = nil,
        persistCheckpoint: Bool = true,
        operation: @MainActor () async throws -> T
    ) async throws -> T {
        guard !isInvalidatingAudio, !isShutdown else { throw CancellationError() }
        isInvalidatingAudio = true
        queueController.reconcileScheduling()
        let pendingPrefetch = prefetchTask
        pendingPrefetch?.cancel()
        prefetchTask = nil
        prefetchTaskID = nil
        prefetchScheduledItemIDs.removeAll()

        var pendingPlayback: Task<Void, Never>?
        if let activeItemID = activity.activeItemID,
           itemIDs?.contains(activeItemID) ?? true {
            if persistCheckpoint { await persistPlaybackCheckpoint() }
            pendingPlayback = playbackTask
            stopPlayback(persistCheckpoint: false)
        }

        let token = await chunkCache.suspendAndDrain(itemIDs: itemIDs)
        await queueController.cancelAndDrain()
        await pendingPlayback?.value
        await drainStoppedPlayback()
        await pendingPrefetch?.value
        do {
            try Task.checkCancellation()
            guard !isShutdown else { throw CancellationError() }
            let result = try await operation()
            await chunkCache.resumeAdmission(token)
            isInvalidatingAudio = false
            queueController.reconcileScheduling()
            schedulePlaybackPrefetch()
            return result
        } catch {
            await chunkCache.resumeAdmission(token)
            isInvalidatingAudio = false
            // A partial storage mutation may have changed generation keys.
            // Keep old runtime state inert until a full refresh succeeds.
            audioRecoveryRequired = true
            queueController.reconcileScheduling()
            throw error
        }
    }

    func clearGeneratedAudio(itemIDs: Set<UUID>) async throws {
        guard !itemIDs.isEmpty else { return }
        try await withAudioInvalidation(itemIDs: itemIDs) {
            try await persistence.clearGeneratedAudio(itemIDs: itemIDs)
            try await refresh()
        }
    }

    func storageBreakdown()
        async throws -> ProjectStorageBreakdown
    {
        try await persistence
            .storageBreakdown()
    }

    func clearTemporaryCache() async throws {
        try await withAudioInvalidation {
            try await chunkCache.clearAll()
            try await cacheCoordinator.clearAllParagraphCache()
        }
    }

    func rename(to title: String) async throws {
        try await persistence.rename(to: title)
        try await refresh()
    }

    func deleteProject() async throws {
        try await withAudioInvalidation {
            try await persistence.deleteProject()
            project = nil
            manifest = nil
            itemStates = []
            artworkURL = nil
            revision &+= 1
            isShutdown = true
            queueController.shutdown()
            await chunkCache.shutdown()
        }
    }

    func itemState(_ itemID: UUID) -> ProjectRuntimeItemState? {
        itemStates.first { $0.id == itemID }
    }

    func prepareExplicitWork(requiresPDFProjection: Bool = true) throws {
        guard !isInvalidatingAudio, !isShutdown else {
            throw CancellationError()
        }
        guard !audioRecoveryRequired else {
            throw ProjectStoreError.invalidData("Audio state needs to be refreshed. Reopen this project and try again.")
        }
        guard !isApplyingPDFReadingPolicy, !isPreparingParsedOutput else {
            throw ProjectStoreError.invalidData(
                "Book content is being prepared. Try again shortly."
            )
        }
        guard isPDFReadingReady
                || (!requiresPDFProjection && pdfReadingProjection == nil) else {
            throw ParsedOutputPreparationError.unavailable
        }
        guard !isReleasingSpeechMemory else {
            throw ProjectStoreError.invalidData("Speech resources are being released. Try listening again in a moment.")
        }
        try ReadAloudSafety.requireMemoryHeadroom()
        synthesisSuspendedForMemoryPressure = false
        queueController.reconcileScheduling()
    }

    func suspendForMemoryPressure() {
        synthesisSuspendedForMemoryPressure = true
        cancelParsedOutputPreparation()
        isReleasingSpeechMemory = true
        let hadWork = isBackgroundWorkActive
        let playbackItemID = playerControlItemID()
        stopPlayback()
        readerLayoutCache = nil
        parsedOutputCache = nil
        queueController.reconcileScheduling()
        if hadWork {
            playerItemID = playbackItemID
            let message = "Listening stopped because the device is low on memory. Your progress is saved. Try again after memory is available."
            activity.playbackState = .failed(message)
            lastErrorMessage = message
        }
    }

    func cachedReaderParagraphs(for item: ProjectContentItem) -> [ReaderParagraph] {
        if let cached = readerLayoutCache, cached.itemID == item.id,
           cached.contentRevision == item.contentRevision {
            return cached.paragraphs
        }
        let paragraphs = ReaderTextLayout.paragraphs(in: item.text)
        readerLayoutCache = (item.id, item.contentRevision, paragraphs)
        return paragraphs
    }

    func playerTextLength(for item: ProjectContentItem) -> Int {
        if let length = readingProgressIndex.lengths[item.id] { return length }
        if let cached = playerTextLengthCache, cached.itemID == item.id,
           cached.contentRevision == item.contentRevision { return cached.length }
        let length = item.text.utf16.count
        playerTextLengthCache = (item.id, item.contentRevision, length)
        return length
    }

    func stopPlayback(persistCheckpoint: Bool = true) {
        let pendingBookmarkWrite = chunkBookmarkTask
        let audibleCheckpoint = project?.playback
        let hadPlayback = playbackTask != nil
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchTaskID = nil
        clearSleepTimer()
        playerItemID = nil
        playbackOperationID = nil
        readerPauseRequested = false
        chunkBookmarkTask?.cancel()
        chunkBookmarkTask = nil
        retirePlayback(playbackTask)
        playbackTask = nil
        pipeline.stop()
        finalAudioAsset = nil
        finalAudioPositionSeconds = 0
        finalAudioPlaybackOriginSeconds = 0
        interruptedPlaybackOperationID = nil
        activity.activeItemID = nil
        activity.currentParagraphRange = nil
        activity.currentParagraphIndex = nil
        activity.currentChunkRange = nil
        activity.currentChunkIndex = nil
        activity.paragraphCount = 0
        activity.itemProgress = 0

        // Stop is synchronous, but a chunk-start write may still be in flight.
        // Commit the last audible in-memory bookmark only if this session was
        // not replaced by a new playback operation.
        if persistCheckpoint, hadPlayback, let audibleCheckpoint {
            Task { @MainActor [weak self] in
                await pendingBookmarkWrite?.value
                guard let self, self.playbackOperationID == nil,
                      self.project?.playback?.currentItemID
                        == audibleCheckpoint.currentItemID,
                      self.project?.playback?.contentBookmark?.textOffsetUTF16
                        == audibleCheckpoint.contentBookmark?.textOffsetUTF16
                else { return }
                try? await self.persistence.updatePlayback(audibleCheckpoint)
            }
        }
    }

    func retirePlayback(_ task: Task<Void, Never>?) {
        guard let task else { return }
        let id = UUID()
        retiringPlaybackTasks[id] = task
        task.cancel()
        Task { @MainActor in
            await task.value
            self.retiringPlaybackTasks.removeValue(forKey: id)
        }
    }

    func drainStoppedPlayback() async {
        let pending = Array(retiringPlaybackTasks.values)
        for task in pending { await task.value }
    }

    func shutdown() {
        cancelParsedOutputPreparation()
        isShutdown = true
        playbackCoordinator?.releasePlayback(self)
        pdfReadingProjection = nil
        parsedOutputCache = nil
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchTaskID = nil
        generationStateRefreshID = nil
        clearSleepTimer()
        playerItemID = nil
        refreshGeneration &+= 1
        isLoading = false
        playbackOperationID = nil
        readerPauseRequested = false
        retirePlayback(playbackTask)
        playbackTask = nil
        pipeline.shutdown()
        queueController.shutdown()
        let cache = chunkCache
        let controller = queueController
        Task {
            await cache.shutdown()
            await controller.cancelAndDrain()
        }
        finalAudioAsset = nil
        finalAudioPositionSeconds = 0
        finalAudioPlaybackOriginSeconds = 0
        interruptedPlaybackOperationID = nil
        activity = ProjectRuntimeActivity()
        ProjectSystemMediaController
            .shared
            .detach(self)
    }

    func shutdownAndDrain() async {
        let pendingPlayback = playbackTask
        let pendingPrefetch = prefetchTask
        let pendingBookmark = chunkBookmarkTask
        let pendingPreparation = parsedPreparationTask
        shutdown()
        await chunkCache.shutdown()
        await queueController.cancelAndDrain()
        await pendingPlayback?.value
        await drainStoppedPlayback()
        await pendingPrefetch?.value
        await pendingBookmark?.value
        _ = await pendingPreparation?.result
    }

    private func handlePipelineEvent(
        _ event: ReadAloudPipeline.Event
    ) {
        switch event {
        case .state(let state):
            // Preparation/playing events are meaningful only for a live request.
            // A retired pipeline must not resurrect activity after stop/close.
            switch state {
            case .loading, .warmingUp, .synthesizing, .buffering, .playing, .paused:
                guard playbackOperationID != nil else { return }
            case .idle, .finished, .failed:
                break
            }
            if readerPauseRequested {
                switch state {
                case .idle, .finished, .failed:
                    activity.playbackState =
                        Self.playbackState(state)
                case .loading, .warmingUp, .synthesizing, .buffering,
                     .playing, .paused:
                    activity.playbackState = .paused
                }
            } else {
                activity.playbackState =
                    Self.playbackState(state)
            }
            queueController.reconcileScheduling()

            if activity.hasActivePlaybackWork {
                // Explicit playback claims ownership before preparation starts.
                // Pipeline updates must never reclaim a superseded session.
                ProjectSystemMediaController
                    .shared
                    .publish(self)
            } else {
                ProjectSystemMediaController
                    .shared
                    .clear(self)
            }

        case .queueChanged(
            let queuedBuffers,
            let queuedDurationSeconds
        ):
            activity.queuedAudioBuffers = queuedBuffers
            activity.queuedAudioDurationSeconds =
                queuedDurationSeconds
            ProjectSystemMediaController
                .shared
                .publish(self)
            if queuedBuffers > 0 { schedulePlaybackPrefetch() }
        case .stopped:
            activity.playbackState = .idle
            activity.activeItemID = nil
            activity.queuedAudioBuffers = 0
            activity.queuedAudioDurationSeconds = 0
            queueController.reconcileScheduling()
            ProjectSystemMediaController
                .shared
                .clear(self)
        case .modelLoaded,
             .chunkStarted,
             .chunkReady,
             .warmUpFinished:
            break
        }
    }

    private func handleAudioSessionEvent(
        _ event:
            SpeechPlaybackQueue.SessionEvent
    ) {
        switch event {
        case .interruptionBegan:
            let interruptedOperation = isPlaybackActive && !isPlaybackPaused
                ? playbackOperationID : nil

            guard isPlaybackActive else {
                return
            }

            scheduleAudioSessionCheckpoint()
            pausePlayback()
            interruptedPlaybackOperationID = interruptedOperation

        case .interruptionEnded(
            let shouldResume
        ):
            let resume = shouldResume && interruptedPlaybackOperationID != nil
                && interruptedPlaybackOperationID == playbackOperationID
            interruptedPlaybackOperationID = nil

            if resume {
                resumePlayback()
            }

        case .routeBecameUnavailable:
            interruptedPlaybackOperationID = nil

            guard isPlaybackActive,
                  !isPlaybackPaused
            else {
                return
            }

            scheduleAudioSessionCheckpoint()
            pausePlayback()

        case .mediaServicesWereReset:
            interruptedPlaybackOperationID = nil

            guard isPlaybackActive else {
                return
            }

            stopPlayback()
            lastErrorMessage =
                "Audio services restarted. Resume playback to continue."
        }
    }

    private func scheduleAudioSessionCheckpoint() {
        guard let operationID = playbackOperationID else { return }
        Task { [weak self] in
            guard let self, self.playbackOperationID == operationID else { return }
            await self.persistPlaybackCheckpoint()
        }
    }

    private static func playbackState(
        _ state: ReadAloudPipeline.State
    ) -> ProjectRuntimePlaybackState {
        switch state {
        case .idle:
            return .idle
        case .loading:
            return .loading
        case .warmingUp:
            return .warmingUp
        case .synthesizing(let current, let total):
            return .synthesizing(
                current: current,
                total: total
            )
        case .buffering:
            return .buffering
        case .playing:
            return .playing
        case .paused:
            return .paused
        case .finished:
            return .finished
        case .failed(let message):
            return .failed(message)
        }
    }

    private func makeArtworkURL(
        project: ProjectDocument
    ) -> URL? {
        guard let relativePath = project.artwork?.relativePath else {
            return nil
        }

        var url = packageURL
        for component in relativePath.split(separator: "/") {
            url.append(
                path: String(component),
                directoryHint: .inferFromPath
            )
        }
        return url
    }

    nonisolated static func message(
        for error: Error
    ) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}



