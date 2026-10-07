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

    var project: ProjectDocument?
    private(set) var manifest: ProjectContentManifest?
    private(set) var itemStates: [ProjectRuntimeItemState] = []
    private(set) var artworkURL: URL?
    var activity = ProjectRuntimeActivity()
    private(set) var isLoading = false
    private(set) var didLoad = false
    var revision: UInt64 = 0
    var lastErrorMessage: String?

    @ObservationIgnored let pipeline: ReadAloudPipeline
    @ObservationIgnored var playbackTask: Task<Void, Never>?
    @ObservationIgnored var playbackOperationID: UUID?
    @ObservationIgnored var readerPauseRequested = false
    @ObservationIgnored var finalAudioAsset:
        ProjectFinalAudioAsset?
    @ObservationIgnored var finalAudioPositionSeconds = 0.0
    @ObservationIgnored var finalAudioPlaybackOriginSeconds = 0.0
    @ObservationIgnored var shouldResumeAfterInterruption = false
    @ObservationIgnored var prefetchScheduledItemIDs = Set<UUID>()
    @ObservationIgnored private var didRecoverGenerationQueue = false
    @ObservationIgnored private var refreshGeneration: UInt64 = 0

    init(
        id: UUID,
        packageURL: URL,
        persistence: ProjectRuntimePersistenceBridge,
        pipeline: ReadAloudPipeline = ReadAloudPipeline()
    ) {
        self.id = id
        self.packageURL = packageURL.standardizedFileURL
        self.persistence = persistence
        self.pipeline = pipeline
        self.queueController = ProjectQueueController()
        self.cacheCoordinator = ProjectCacheCoordinator(
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

    var blocksQueuedGeneration: Bool {
        activity.hasActivePlaybackWork
            && finalAudioAsset == nil
    }

    var isBackgroundWorkActive: Bool {
        activity.hasActivePlaybackWork
            || queueController.hasExecutingWork
    }

    var resolvedProjectSettings: ResolvedNarrationSettings {
        NarrationSettingsResolver.resolveProject(
            project?.settings ?? ProjectNarrationSettings()
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
                    project: loaded.project.settings
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

            let statuses = try await persistence.generationStatuses(
                requests: requests
            )
            try Task.checkCancellation()

            guard generation == refreshGeneration else {
                return
            }

            project = loaded.project
            manifest = loaded.manifest
            activity.projectProgress =
                loaded.project.playback?.projectProgress ?? 0
            itemStates = prepared.map {
                ProjectRuntimeItemState(
                    item: $0.item,
                    resolved: $0.resolved,
                    generationKey: $0.generationKey,
                    generationStatus:
                        statuses[$0.item.id] ?? .notGenerated
                )
            }
            queueController.publish(loaded.queue)
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

    func persistPlayback(
        _ playback: ProjectPlaybackState?
    ) async throws {
        try await persistence.updatePlayback(playback)
        try await refresh()
    }

    func updateProjectVoice(_ voiceID: String?) async throws {
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
        guard let entry = itemState(itemID) else {
            throw ProjectStoreError.invalidData(
                "Runtime item is unavailable."
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
                            oldSettings
                    )
            let newResolved =
                try NarrationSettingsResolver
                    .resolve(
                        item:
                            state.item.settings,
                        project:
                            newSettings
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
            project: oldSettings
        )
        let newResolved = try NarrationSettingsResolver.resolve(
            item: active.item.settings,
            project: newSettings
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
            project: project.settings
        )
        let newResolved = try NarrationSettingsResolver.resolve(
            item: newSettings,
            project: project.settings
        )

        if oldResolved != newResolved {
            stopPlayback()
        }
    }

    func enqueueGeneration(
        itemID: UUID,
        regenerate: Bool
    ) async throws {
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
        let requests = itemStates.compactMap { entry in
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
        queueController
            .setPlaybackActive(true)

        defer {
            queueController
                .setPlaybackActive(
                    blocksQueuedGeneration
                )
        }

        try await cacheCoordinator
            .clearAllParagraphCache()
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

    func stopPlayback() {
        playbackOperationID = nil
        readerPauseRequested = false
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
        activity.paragraphCount = 0
        activity.itemProgress = 0
    }

    func shutdown() {
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
        case .stopped:
            activity.playbackState = .idle
            activity.activeItemID = nil
            activity.queuedAudioBuffers = 0
            activity.queuedAudioDurationSeconds = 0
            queueController.setPlaybackActive(
                false
            )
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
