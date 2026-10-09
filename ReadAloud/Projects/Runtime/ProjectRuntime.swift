import Foundation
import Observation

nonisolated struct ProjectRuntimeItemState: Identifiable, Equatable, Sendable {
    let item: ProjectContentItem
    let resolved: ResolvedNarrationSettings
    let generationKey: String
    let generationStatus: ProjectItemGenerationStatus

    var id: UUID { item.id }
}

nonisolated enum ProjectRuntimePlaybackState: Equatable, Sendable {
    case idle
    case loading
    case warmingUp
    case synthesizing(current: Int, total: Int)
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
        case .loading, .warmingUp, .synthesizing, .playing, .paused:
            return true
        case .idle, .finished, .failed:
            return false
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
    var sleepTimerDeadline: Date?
    var stopsAtChapterEnd = false
    @ObservationIgnored var sleepTimerTask: Task<Void, Never>?
    private(set) var isLoading = false
    private(set) var didLoad = false
    var revision: UInt64 = 0
    var lastErrorMessage: String?

    @ObservationIgnored let pipeline: ReadAloudPipeline
    @ObservationIgnored let hasProAccess:
        @MainActor () -> Bool
    @ObservationIgnored var synthesisSuspendedForMemoryPressure = false
    @ObservationIgnored var isReleasingSpeechMemory = false
    @ObservationIgnored var readingProgressIndex = ProjectReadingProgressIndex()
    @ObservationIgnored private var readerLayoutCache:
        (itemID: UUID, contentRevision: String, paragraphs: [ReaderParagraph])?
    @ObservationIgnored private var playerTextLengthCache:
        (itemID: UUID, contentRevision: String, length: Int)?
    @ObservationIgnored var playbackTask: Task<Void, Never>?
    @ObservationIgnored var chunkBookmarkTask: Task<Void, Never>?
    @ObservationIgnored var playbackOperationID: UUID?
    @ObservationIgnored var readerPauseRequested = false
    @ObservationIgnored var finalAudioAsset:
        ProjectFinalAudioAsset?
    @ObservationIgnored var finalAudioPositionSeconds = 0.0
    @ObservationIgnored var finalAudioPlaybackOriginSeconds = 0.0
    @ObservationIgnored var shouldResumeAfterInterruption = false
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

    var blocksQueuedGeneration: Bool {
        if synthesisSuspendedForMemoryPressure { return true }
        guard activity
            .hasActivePlaybackWork
        else {
            return false
        }

        if finalAudioAsset == nil {
            return true
        }

        return !hasPro
            || !ReadAloudPreferences
                .generateWhileListening
    }

    var isBackgroundWorkActive: Bool {
        activity.hasActivePlaybackWork
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
        currentItemID ?? itemStates.first?.id
    }

    func loadIfNeeded() async throws {
        guard !didLoad else { return }

        if !didRecoverGenerationQueue {
            _ = try await persistence
                .recoverGenerationQueue()
            didRecoverGenerationQueue = true
        }

        do {
            try await refresh()
            try queueController.configure(
                runtime: self
            )
            queueController.setPlaybackActive(
                blocksQueuedGeneration
            )
        } catch {
            didLoad = false
            throw error
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
                        runtimeRevision: runtimeRevision
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
                    generationStatus:
                        generationState.statuses[$0.item.id] ?? .notGenerated
                )
            }
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
                if resolved
                    != state.resolved
                {
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

        queueController
            .setPlaybackActive(true)

        defer {
            prefetchScheduledItemIDs
                .removeAll()
            queueController
                .setPlaybackActive(
                    blocksQueuedGeneration
                )
        }

        if let activeItemID =
                activity.activeItemID,
           affectedItemIDs
            .contains(activeItemID)
        {
            await persistPlaybackCheckpoint()
            stopPlayback()
            queueController
                .setPlaybackActive(true)
        }

        if engineChanged {
            // Stop running durable generation before unloading the model.
            // Old finalized assets remain on disk; changed generation keys
            // make them incompatible without deleting user data.
            queueController.shutdown()
            await pipeline.selectEngine(selectedEngine)
        }

        do {
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
            if engineChanged {
                try queueController.configure(runtime: self)
            }
        } catch {
            lastErrorMessage =
                Self.message(
                    for: error
                )
            // Do not restart old durable jobs if refresh/invalidation failed.
            // They must never synthesize ONNX audio under a Core ML cache key.
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
        try stopPlaybackIfProjectNarrationChanges(
            from: project.settings,
            to: settings
        )
        let affectedItemIDs =
            try narrationAffectedItemIDs(
                from: project.settings,
                to: settings
            )
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

    func updateProjectSpeed(_ speed: Double?) async throws {
        guard let project else {
            throw ProjectStoreError.projectNotFound(id)
        }
        var settings = project.settings
        settings.speed = speed
        try stopPlaybackIfProjectNarrationChanges(
            from: project.settings,
            to: settings
        )
        let affectedItemIDs =
            try narrationAffectedItemIDs(
                from: project.settings,
                to: settings
            )
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

    func updateItemVoiceMode(
        itemID: UUID,
        mode: ItemSettingMode
    ) async throws {
        if mode == .custom {
            try ReadAloudAccessPolicy
                .requirePro(
                    .itemNarrationOverrides,
                    hasPro: hasPro
                )
        }

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

        try stopPlaybackIfItemNarrationChanges(
            itemID: itemID,
            from: entry.item.settings,
            to: settings
        )
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

    func updateItemVoice(
        itemID: UUID,
        voiceID: String
    ) async throws {
        try ReadAloudAccessPolicy
            .requirePro(
                .itemNarrationOverrides,
                hasPro: hasPro
            )

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

        try stopPlaybackIfItemNarrationChanges(
            itemID: itemID,
            from: entry.item.settings,
            to: settings
        )
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

    func updateItemSpeedMode(
        itemID: UUID,
        mode: ItemSettingMode
    ) async throws {
        if mode == .custom {
            try ReadAloudAccessPolicy
                .requirePro(
                    .itemNarrationOverrides,
                    hasPro: hasPro
                )
        }

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

        try stopPlaybackIfItemNarrationChanges(
            itemID: itemID,
            from: entry.item.settings,
            to: settings
        )
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

    func updateItemSpeed(
        itemID: UUID,
        speed: Double
    ) async throws {
        try ReadAloudAccessPolicy
            .requirePro(
                .itemNarrationOverrides,
                hasPro: hasPro
            )

        guard let entry = itemState(itemID) else {
            throw ProjectStoreError.invalidData(
                "Runtime item is unavailable."
            )
        }
        var settings = entry.item.settings
        settings.speed.mode = .custom
        settings.speed.customValue = speed

        try stopPlaybackIfItemNarrationChanges(
            itemID: itemID,
            from: entry.item.settings,
            to: settings
        )
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

    private func stopPlaybackIfProjectNarrationChanges(
        from oldSettings: ProjectNarrationSettings,
        to newSettings: ProjectNarrationSettings
    ) throws {
        guard activity.hasActivePlaybackWork,
              let activeItemID = activity.activeItemID,
              let active = itemState(activeItemID)
        else {
            return
        }

        let oldResolved = try NarrationSettingsResolver.resolve(
            item: active.item.settings,
            project: oldSettings,
            hasPro: hasPro
        )
        let newResolved = try NarrationSettingsResolver.resolve(
            item: active.item.settings,
            project: newSettings,
            hasPro: hasPro
        )

        if oldResolved != newResolved {
            stopPlayback()
        }
    }

    private func stopPlaybackIfItemNarrationChanges(
        itemID: UUID,
        from oldSettings: ItemNarrationSettings,
        to newSettings: ItemNarrationSettings
    ) throws {
        guard activity.hasActivePlaybackWork,
              activity.activeItemID == itemID,
              let project
        else {
            return
        }

        let oldResolved = try NarrationSettingsResolver.resolve(
            item: oldSettings,
            project: project.settings,
            hasPro: hasPro
        )
        let newResolved = try NarrationSettingsResolver.resolve(
            item: newSettings,
            project: project.settings,
            hasPro: hasPro
        )

        if oldResolved != newResolved {
            stopPlayback()
        }
    }

    func enqueueGeneration(
        itemID: UUID,
        regenerate: Bool
    ) async throws {
        try prepareExplicitWork()
        guard let entry = itemState(itemID) else {
            throw ProjectStoreError.invalidData(
                "Runtime item is unavailable."
            )
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
        try prepareExplicitWork()
        try ReadAloudAccessPolicy
            .requirePro(
                .bulkGeneration,
                hasPro: hasPro
            )

        let requests: [ProjectGenerationRequest] = itemStates.compactMap { entry -> ProjectGenerationRequest? in
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

    func clearGeneratedAudio(
        itemIDs: Set<UUID>
    ) async throws {
        guard !itemIDs.isEmpty else {
            return
        }

        queueController
            .setPlaybackActive(true)

        defer {
            queueController
                .setPlaybackActive(
                    blocksQueuedGeneration
                )
        }

        if let activeItemID =
                activity.activeItemID,
           itemIDs.contains(
                activeItemID
           )
        {
            await persistPlaybackCheckpoint()
            stopPlayback()
            queueController
                .setPlaybackActive(true)
        }

        try await persistence.clearGeneratedAudio(
            itemIDs: itemIDs
        )
        try await refresh()
    }

    func storageBreakdown()
        async throws -> ProjectStorageBreakdown
    {
        try await persistence
            .storageBreakdown()
    }

    func clearTemporaryCache()
        async throws
    {
        // Chunk WAVs are the producer/consumer handoff. Stop the session
        // cleanly before removing the files that queued playback expects.
        if isPlaybackActive {
            await persistPlaybackCheckpoint()
            stopPlayback()
        }
        queueController
            .setPlaybackActive(true)

        defer {
            queueController
                .setPlaybackActive(
                    blocksQueuedGeneration
                )
        }

        // Remove both the current chunk cache and any legacy paragraph cache.
        try await chunkCache.clearAll()
        try await cacheCoordinator.clearAllParagraphCache()
    }

    func rename(to title: String) async throws {
        try await persistence.rename(to: title)
        try await refresh()
    }

    func deleteProject() async throws {
        stopPlayback()
        try await persistence.deleteProject()
        project = nil
        manifest = nil
        itemStates = []
        artworkURL = nil
        revision &+= 1
    }

    func itemState(_ itemID: UUID) -> ProjectRuntimeItemState? {
        itemStates.first { $0.id == itemID }
    }

    func prepareExplicitWork() throws {
        guard !isReleasingSpeechMemory else {
            throw ProjectStoreError.invalidData("Speech resources are being released. Try listening again in a moment.")
        }
        try ReadAloudSafety.requireMemoryHeadroom()
        synthesisSuspendedForMemoryPressure = false
        queueController.setPlaybackActive(blocksQueuedGeneration)
    }

    func suspendForMemoryPressure() {
        synthesisSuspendedForMemoryPressure = true
        isReleasingSpeechMemory = true
        let hadWork = isBackgroundWorkActive
        stopPlayback()
        readerLayoutCache = nil
        queueController.setPlaybackActive(true)
        if hadWork {
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

    func stopPlayback() {
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
        playbackTask?.cancel()
        playbackTask = nil
        pipeline.stop()
        finalAudioAsset = nil
        finalAudioPositionSeconds = 0
        finalAudioPlaybackOriginSeconds = 0
        shouldResumeAfterInterruption = false
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
        if hadPlayback, let audibleCheckpoint {
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

    func shutdown() {
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
        playbackTask?.cancel()
        playbackTask = nil
        pipeline.shutdown()
        queueController.shutdown()
        finalAudioAsset = nil
        finalAudioPositionSeconds = 0
        finalAudioPlaybackOriginSeconds = 0
        shouldResumeAfterInterruption = false
        activity = ProjectRuntimeActivity()
        ProjectSystemMediaController
            .shared
            .detach(self)
    }

    private func handlePipelineEvent(
        _ event: ReadAloudPipeline.Event
    ) {
        switch event {
        case .state(let state):
            if readerPauseRequested {
                switch state {
                case .idle, .finished, .failed:
                    activity.playbackState =
                        Self.playbackState(state)
                case .loading, .warmingUp, .synthesizing,
                     .playing, .paused:
                    activity.playbackState = .paused
                }
            } else {
                activity.playbackState =
                    Self.playbackState(state)
            }
            queueController.setPlaybackActive(
                blocksQueuedGeneration
            )

            if activity.hasActivePlaybackWork {
                ProjectSystemMediaController
                    .shared
                    .activate(self)
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
            queueController.setPlaybackActive(blocksQueuedGeneration)
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
            shouldResumeAfterInterruption =
                isPlaybackActive
                && !isPlaybackPaused

            guard isPlaybackActive else {
                return
            }

            Task { [weak self] in
                await self?
                    .persistPlaybackCheckpoint()
            }
            pausePlayback()

        case .interruptionEnded(
            let shouldResume
        ):
            let resume =
                shouldResume
                && shouldResumeAfterInterruption
            shouldResumeAfterInterruption =
                false

            if resume {
                resumePlayback()
            }

        case .routeBecameUnavailable:
            shouldResumeAfterInterruption =
                false

            guard isPlaybackActive,
                  !isPlaybackPaused
            else {
                return
            }

            Task { [weak self] in
                await self?
                    .persistPlaybackCheckpoint()
            }
            pausePlayback()

        case .mediaServicesWereReset:
            shouldResumeAfterInterruption =
                false

            guard isPlaybackActive else {
                return
            }

            Task { [weak self] in
                await self?
                    .persistPlaybackCheckpoint()
            }
            stopPlayback()
            lastErrorMessage =
                "Audio services restarted. Resume playback to continue."
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

