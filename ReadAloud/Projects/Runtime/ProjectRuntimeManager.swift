import Foundation
import Observation

nonisolated struct PlayerReaderTarget: Hashable, Sendable {
    let projectID: UUID
    let itemID: UUID?
    let title: String
}

@Observable
@MainActor
final class ProjectRuntimeManager {
    private struct PreparationPresenter {
        let id: UUID
        let priority: Int
        let present: @MainActor (ProjectRuntime, @escaping ParsedOutputRetry) -> Bool
    }
    @ObservationIgnored private var preparationPresenters: [PreparationPresenter] = []

    func registerPreparationPresenter(
        id: UUID, priority: Int,
        present: @escaping @MainActor (ProjectRuntime, @escaping ParsedOutputRetry) -> Bool
    ) {
        preparationPresenters.removeAll { $0.id == id }
        preparationPresenters.append(PreparationPresenter(id: id, priority: priority, present: present))
    }

    func unregisterPreparationPresenter(id: UUID) {
        preparationPresenters.removeAll { $0.id == id }
    }

    /// Synchronous handoff to a currently visible screen. There is no pending
    /// request on the manager and nothing to replay when the app foregrounds.
    func offerParsedPreparation(runtime: ProjectRuntime, retry: @escaping ParsedOutputRetry) -> Bool {
        guard !isShutdown, ProjectGenerationExecutionRegistry.shared.isApplicationActive,
              runtimes[runtime.id] === runtime,
              let presenter = preparationPresenters.enumerated().max(by: {
                  $0.element.priority == $1.element.priority
                      ? $0.offset < $1.offset : $0.element.priority < $1.element.priority
              })?.element else { return false }
        return presenter.present(runtime, retry)
    }

    let voicePreviews = VoicePreviewController()
    private(set) var activeRuntime: ProjectRuntime?
    // Browsing selection is independent from the one explicit playback owner.
    private(set) var playerRuntime: ProjectRuntime?
    var isPlayerExpanded = false
    let listeningAllowance = ReadAloudListeningAllowance()
    var isListeningLimitPresented = false
    @ObservationIgnored private var meteringHasPro: Bool
    var playerReaderTarget: PlayerReaderTarget?
    private(set) var readerFollowRevision: UInt64 = 0
    private(set) var loadedRuntimeIDs: Set<UUID> = []
    private(set) var initializationError: String?
    private(set) var readerProjectID: UUID?
    private(set) var generationRecoveryError: String?
    private(set) var isBackgroundPrefetchPaused = ReadAloudPreferences.backgroundPrefetchPaused
    private(set) var offlineQueueIssues: [String] = []
    private(set) var isLoadingOfflineQueue = false
    private(set) var cancellingOfflineJobIDs: Set<UUID> = []
    private var persistedOfflineQueueBooks: [OfflineGenerationQueueBook] = []
    @ObservationIgnored private var offlineQueueRefreshRevision: UInt64 = 0

    /// Durable snapshots cover unopened books. A loaded runtime always replaces
    /// its entire snapshot, including when it has no remaining active jobs.
    var offlineGenerationQueueBooks: [OfflineGenerationQueueBook] {
        _ = loadedRuntimeIDs
        var books = Dictionary(uniqueKeysWithValues: persistedOfflineQueueBooks.map { ($0.id, $0) })
        for runtime in runtimes.values where runtime.didLoad && loadingTasks[runtime.id] == nil {
            books.removeValue(forKey: runtime.id)
            if let book = offlineQueueBook(for: runtime) { books[runtime.id] = book }
        }
        return books.values.filter { !deletingProjectIDs.contains($0.id) && !$0.rows.isEmpty }
            .map { book in
                var book = book
                if runtimeIfLoaded(projectID: book.id) == nil {
                    for index in book.rows.indices {
                        book.rows[index].isProcessing = false
                        book.rows[index].progress = nil
                        book.rows[index].waitingReason = dormantGenerationWaitingReason
                    }
                }
                return book
            }
            .sorted { lhs, rhs in
                let leftRunning = lhs.rows.contains(where: \.isProcessing)
                let rightRunning = rhs.rows.contains(where: \.isProcessing)
                if leftRunning != rightRunning { return leftRunning }
                let left = lhs.rows.map { $0.job.createdAt }.min() ?? .distantFuture
                let right = rhs.rows.map { $0.job.createdAt }.min() ?? .distantFuture
                return left == right ? lhs.id.uuidString < rhs.id.uuidString : left < right
            }
    }

    var offlineGenerationQueueIssues: [String] {
        var issues = offlineQueueIssues
        if generationRecoveryError != nil {
            issues.append("Some queued audio could not be restored. Open the book to review its offline audio.")
        }
        for runtime in runtimes.values where runtime.queueController.queueError != nil {
            issues.append("Queue storage for \(runtime.project?.title ?? "a book") could not be updated. Open the book or refresh to try again.")
        }
        return issues
    }

    /// Metadata-only refresh. Viewing the queue never restores a runtime,
    /// starts synthesis, changes playback ownership, or offers source parsing.
    func refreshOfflineGenerationQueue() async {
        guard let projectStore, !isShutdown else {
            offlineQueueIssues = [initializationError ?? "Queue storage is unavailable."]
            return
        }
        offlineQueueRefreshRevision &+= 1
        let revision = offlineQueueRefreshRevision
        isLoadingOfflineQueue = true
        defer {
            if revision == offlineQueueRefreshRevision { isLoadingOfflineQueue = false }
        }
        do {
            let titles = Dictionary(uniqueKeysWithValues: runtimes.values.filter(\.didLoad).map { runtime in
                (runtime.id, Dictionary(uniqueKeysWithValues: runtime.itemStates.map { ($0.id, $0.item.title) }))
            })
            let snapshot = try await projectStore.offlineGenerationQueueSnapshot(knownTitles: titles)
            guard !Task.isCancelled, revision == offlineQueueRefreshRevision, !isShutdown else { return }
            persistedOfflineQueueBooks = snapshot.books
            offlineQueueIssues = snapshot.issues
        } catch is CancellationError { }
        catch {
            guard revision == offlineQueueRefreshRevision, !isShutdown else { return }
            offlineQueueIssues = ["The generation queue could not be refreshed. Your saved requests are preserved. Try refreshing again."]
        }
    }

    func cancelOfflineGeneration(_ row: OfflineGenerationQueueRow) async throws {
        let projectID = row.job.projectID
        guard let projectStore, !isShutdown, !deletingProjectIDs.contains(projectID),
              !deletedProjectIDs.contains(projectID), !cancellingOfflineJobIDs.contains(row.id) else { return }
        cancellingOfflineJobIDs.insert(row.id)
        defer { cancellingOfflineJobIDs.remove(row.id) }
        do {
            // Storage rechecks the exact job ID/key and its current active state.
            // No chapter-wide remove, audio invalidation, or new runtime load.
            let queue = try await projectStore.cancelGenerationJob(
                projectID: projectID, jobID: row.id, generationKey: row.job.generationKey
            )
            // Recovery may already be loading this book. Let that existing load
            // finish, then reconcile it; never create a runtime just to cancel.
            if let loading = loadingTasks[projectID] { _ = await loading.result }
            if let runtime = runtimeIfLoaded(projectID: projectID) {
                var executionError: Error?
                if !queue.jobs.contains(where: { $0.id == row.id }) {
                    do { try runtime.queueController.removeCancelledExecution(jobID: row.id) }
                    catch {
                        runtime.queueController.publishQueueError(Self.message(for: error))
                        executionError = error
                    }
                }
                try await runtime.refreshGenerationState()
                if let executionError { throw executionError }
            }
            await refreshOfflineGenerationQueue()
        } catch {
            await refreshOfflineGenerationQueue()
            throw error
        }
    }

    private var dormantGenerationWaitingReason: String {
        if isBackgroundPrefetchPaused { return "Generation paused" }
        if recoverySuspendedForMemoryPressure { return "Waiting for speech resources. Open the book to continue." }
        if !ProjectGenerationExecutionRegistry.shared.canPerformGeneration {
            return "Paused while not listening in background"
        }
        return "Waiting to restore queued work"
    }

    private func offlineQueueBook(for runtime: ProjectRuntime) -> OfflineGenerationQueueBook? {
        guard let project = runtime.project else { return nil }
        let controller = runtime.queueController
        let rows = controller.queue.jobs.filter { $0.state == .queued || $0.state == .generating }
            .map { job in
                var row = OfflineGenerationQueueRow(
                    job: job, title: runtime.itemState(job.itemID)?.item.title ?? "Chapter"
                )
                row.isProcessing = controller.hasGlobalAdmission && controller.executingJobIDs.contains(job.id)
                row.progress = row.isProcessing ? controller.progressByJobID[job.id] : nil
                if isBackgroundPrefetchPaused { row.waitingReason = "Generation paused" }
                else if !runtime.isPDFReadingReady {
                    row.waitingReason = "Open the book to prepare its reading content."
                } else if runtime.synthesisSuspendedForMemoryPressure || runtime.isReleasingSpeechMemory {
                    row.waitingReason = "Waiting for speech resources. Open the book to continue."
                } else if controller.hasGlobalAdmission {
                    row.waitingReason = controller.executingJobIDs.isEmpty
                        ? "Preparing offline audio…" : "Waiting for another chapter"
                } else { row.waitingReason = controller.schedulingStatus }
                return row
            }
            .sorted { lhs, rhs in
                if lhs.isProcessing != rhs.isProcessing { return lhs.isProcessing }
                return lhs.job.createdAt == rhs.job.createdAt
                    ? lhs.id.uuidString < rhs.id.uuidString : lhs.job.createdAt < rhs.job.createdAt
            }
        guard !rows.isEmpty else { return nil }
        return OfflineGenerationQueueBook(
            project: ProjectSnapshot(project: project), artworkURL: runtime.artworkURL, rows: rows
        )
    }

    private func rememberOfflineQueue(_ runtime: ProjectRuntime) {
        // Retain the latest projection when a runtime leaves memory, so an old
        // disk snapshot cannot briefly resurrect its completed/cancelled rows.
        offlineQueueRefreshRevision &+= 1
        isLoadingOfflineQueue = false
        persistedOfflineQueueBooks.removeAll { $0.id == runtime.id }
        if !deletingProjectIDs.contains(runtime.id), let book = offlineQueueBook(for: runtime) {
            persistedOfflineQueueBooks.append(book)
        }
    }

    func backgroundGenerationStatus(
        persisted: [UUID: ProjectGenerationQueueCounts]
    ) -> ProjectGenerationQueueCounts {
        // Live TTS runtimes supersede disk snapshots for the same project.
        // Dormant projects still contribute their durable queued/failed jobs.
        _ = loadedRuntimeIDs
        var byProject = persisted
        for runtime in runtimes.values where runtime.didLoad {
            byProject[runtime.id] = ProjectGenerationQueueCounts(
                queue: runtime.queueController.queue,
                runtimeIsActive: true
            )
        }
        return byProject.values.reduce(into: ProjectGenerationQueueCounts()) {
            $0.add($1)
        }
    }

    /// Scene activity is a temporary admission rule, never a preference write.
    func setApplicationActive(_ active: Bool) {
        if !active { voicePreviews.stop() }
        playerRuntime?.pipeline.flushListeningUsage()
        listeningAllowance.refresh()
        listeningAllowance.persist()
        if hasPro() || !listeningAllowance.isExhausted() {
            isListeningLimitPresented = false
        }
        let registry = ProjectGenerationExecutionRegistry.shared
        registry.setApplicationActive(active)
        if !registry.canPerformGeneration {
            recoveryTask?.cancel()
        } else {
            for runtime in runtimes.values { runtime.schedulePlaybackPrefetch() }
        }
    }

    /// Retain queued work while suspending background generation.
    /// Audible playback remains independent of this control.
    func setBackgroundPrefetchPaused(_ paused: Bool) {
        guard isBackgroundPrefetchPaused != paused else { return }
        isBackgroundPrefetchPaused = paused
        UserDefaults.standard.set(paused, forKey: ReadAloudPreferences.Key.backgroundPrefetchPaused)
        for runtime in runtimes.values {
            if paused {
                runtime.prefetchTask?.cancel()
                runtime.prefetchTask = nil
                runtime.prefetchTaskID = nil
            }
            runtime.queueController.reconcileScheduling()
            if !paused {
                runtime.prefetchScheduledItemIDs.removeAll()
                runtime.schedulePlaybackPrefetch()
            }
        }
        if !paused { Task { await recoverPendingGeneration() } }
    }

    @ObservationIgnored private let projectStore: ProjectStore?
    @ObservationIgnored private let makePipeline: @MainActor () -> ReadAloudPipeline
    @ObservationIgnored private let hasPro:
        @MainActor () -> Bool
    @ObservationIgnored private var runtimes: [UUID: ProjectRuntime] = [:]
    @ObservationIgnored private var loadingTasks:
        [UUID: Task<ProjectRuntime, Error>] = [:]
    @ObservationIgnored private var memoryReleaseTask: Task<Void, Never>?
    @ObservationIgnored private var deletingProjectIDs: Set<UUID> = []
    @ObservationIgnored private var deletedProjectIDs: Set<UUID> = []
    @ObservationIgnored private var recoveryTask: Task<Bool, Never>?
    @ObservationIgnored private var recoveryTaskID: UUID?
    @ObservationIgnored private var recoverySuspendedForMemoryPressure = false
    @ObservationIgnored private var isShutdown = false

    init(
        store: ProjectStore? = nil,
        makePipeline: @escaping @MainActor () -> ReadAloudPipeline = { ReadAloudPipeline() },
        hasPro:
            @escaping @MainActor () -> Bool
            = { false }
    ) {
        self.makePipeline = makePipeline
        self.hasPro = hasPro
        self.meteringHasPro = hasPro()
        do {
            projectStore = try store ?? ProjectStore.shared()
            initializationError = nil
        } catch {
            projectStore = nil
            initializationError = Self.message(for: error)
        }
    }

    func activate(
        projectID: UUID
    ) async throws -> ProjectRuntime {
        if memoryReleaseTask == nil { recoverySuspendedForMemoryPressure = false }
        closeIdleRuntimes(keeping: projectID)
        let runtime = try await loadRuntime(projectID: projectID)
        activeRuntime = runtime
        return runtime
    }

    func prepareRuntime(projectID: UUID) async throws -> ProjectRuntime {
        if let runtime = runtimeIfLoaded(projectID: projectID) { return runtime }
        return try await loadRuntime(projectID: projectID)
    }

    /// Navigation and recovery share the single-flight loader. Loaded runtimes
    /// already own validated content and live playback state; opening a Reader
    /// must not reload every chapter or rehash all saved audio. Content changes
    /// use the explicit refresh paths instead.
    private func loadRuntime(projectID: UUID) async throws -> ProjectRuntime {
        try Task.checkCancellation()
        guard !isShutdown, !deletedProjectIDs.contains(projectID),
              !deletingProjectIDs.contains(projectID) else { throw CancellationError() }
        if let loading = loadingTasks[projectID] {
            let runtime = try await loading.value
            try Task.checkCancellation()
            guard runtimes[projectID] === runtime,
                  !deletingProjectIDs.contains(projectID) else { throw CancellationError() }
            return runtime
        }

        if let existing = runtimes[projectID],
           existing.didLoad {
            return existing
        }

        guard let projectStore else {
            throw ProjectStoreError.io(
                initializationError
                    ?? "Project storage is unavailable."
            )
        }

        let runtime: ProjectRuntime
        if let existing = runtimes[projectID] {
            runtime = existing
        } else {
            // The immutable root is nonisolated: reserve the runtime/loading
            // task before the first suspension so competing loaders coalesce.
            let rootURL = projectStore.rootURL
            let packageURL = ProjectPackagePaths.packageURL(
                projectID: projectID,
                rootURL: rootURL
            )
            runtime = ProjectRuntime(
                id: projectID,
                packageURL: packageURL,
                persistence: ProjectRuntimePersistenceBridge(
                    projectID: projectID,
                    store: projectStore
                ),
                hasPro: hasPro,
                pipeline: makePipeline()
            )
            runtime.playbackCoordinator = self
            runtime.pipeline.configureListeningMeter(
                onPlayed: { [weak self] seconds in
                    self?.recordListening(seconds: seconds)
                },
                onCheckpoint: { [weak self] in
                    self?.listeningAllowance.persist()
                }
            )
            runtimes[projectID] = runtime
            if memoryReleaseTask != nil || recoverySuspendedForMemoryPressure {
                runtime.suspendForMemoryPressure()
                if memoryReleaseTask == nil { runtime.isReleasingSpeechMemory = false }
            }
        }

        let loading = Task { @MainActor in
            try await runtime.loadIfNeeded()
            return runtime
        }
        loadingTasks[projectID] = loading

        do {
            let loaded = try await loading.value
            guard runtimes[projectID] === loaded,
                  !deletingProjectIDs.contains(projectID) else { throw CancellationError() }
            loadingTasks.removeValue(forKey: projectID)
            publishLoadedRuntimeIDs()
            return loaded
        } catch {
            if runtimes[projectID] === runtime {
                loadingTasks.removeValue(forKey: projectID)
                runtimes.removeValue(forKey: projectID)
            }
            publishLoadedRuntimeIDs()
            if activeRuntime === runtime {
                activeRuntime = nil
            }
            runtime.shutdown()
            throw error
        }
    }

    /// Safe to call on launch and foreground entry. Loaded runtimes are never
    /// recovered again: normalizing a live `.generating` record would race it.
    func recoverPendingGeneration() async {
        while let pending = recoveryTask {
            let pendingID = recoveryTaskID
            let completedScan = await pending.value
            if recoveryTaskID == pendingID {
                recoveryTask = nil
                recoveryTaskID = nil
            }
            // Foreground entry can overlap the tail of a cancelled background
            // scan. Wait for it, then restore work rather than losing this entry.
            guard !completedScan else { return }
        }
        guard let projectStore, !isShutdown, !recoverySuspendedForMemoryPressure,
              ProjectGenerationExecutionRegistry.shared.canPerformGeneration else { return }
        let taskID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return true }
            self.generationRecoveryError = nil
            do {
                let catalog = try await projectStore.catalog()
                for project in catalog.projects {
                    guard !Task.isCancelled, !self.recoverySuspendedForMemoryPressure,
                          ProjectGenerationExecutionRegistry.shared.canPerformGeneration else { return false }
                    guard self.runtimes[project.id] == nil,
                          !self.deletedProjectIDs.contains(project.id),
                          !self.deletingProjectIDs.contains(project.id) else { continue }
                    do {
                        let queue = try await projectStore.loadQueue(projectID: project.id)
                        guard queue.jobs.contains(where: { $0.state == .queued || $0.state == .generating }) else { continue }
                        guard !Task.isCancelled,
                              ProjectGenerationExecutionRegistry.shared.canPerformGeneration else { return false }
                        _ = try await self.loadRuntime(projectID: project.id)
                    } catch is CancellationError {
                        continue
                    } catch {
                        // Keep corrupt/inaccessible packages intact and continue
                        // restoring work from the rest of the library.
                        self.generationRecoveryError = Self.message(for: error)
                    }
                }
            } catch {
                self.generationRecoveryError = Self.message(for: error)
            }
            return !Task.isCancelled && !self.recoverySuspendedForMemoryPressure
                && ProjectGenerationExecutionRegistry.shared.canPerformGeneration
        }
        recoveryTaskID = taskID
        recoveryTask = task
        _ = await task.value
        if recoveryTaskID == taskID {
            recoveryTask = nil
            recoveryTaskID = nil
        }
    }

    var hasActiveAudioWork: Bool {
        runtimes.values.contains {
            $0.isPlaybackActive || $0.isBackgroundWorkActive
        }
    }

    var playbackRuntime: ProjectRuntime? {
        guard let playerRuntime, playerRuntime.isPlaybackActive else { return nil }
        return playerRuntime
    }

    /// Called by every start/seek/replay and resume path before changing the
    /// existing session. The reader and offline generation never use this gate.
    func authorizeListening() -> Bool {
        playerRuntime?.pipeline.flushListeningUsage()
        listeningAllowance.refresh()
        guard !hasPro(), listeningAllowance.isExhausted() else { return true }
        presentListeningLimit()
        return false
    }

    private func recordListening(seconds: TimeInterval) {
        listeningAllowance.record(seconds: seconds, isPro: meteringHasPro)
        if !hasPro(), listeningAllowance.isExhausted() {
            presentListeningLimit()
        }
    }

    private func presentListeningLimit() {
        guard !isShutdown else { return }
        playerRuntime?.pausePlayback()
        isListeningLimitPresented = true
    }

    func listeningEntitlementDidChange() {
        // Flush the old entitlement's rendered tail before changing which
        // plan future samples belong to. Pro time never erases Free usage.
        playerRuntime?.pipeline.flushListeningUsage()
        meteringHasPro = hasPro()
        listeningAllowance.refresh()
        if hasPro() || !listeningAllowance.isExhausted() {
            isListeningLimitPresented = false
        } else if playerRuntime?.isPlaybackActive == true {
            presentListeningLimit()
        }
    }

    /// Called synchronously by every playback path, including seeks and replay.
    /// Runtime state remains authoritative for progress, pause, and preparation.
    func claimPlayback(_ runtime: ProjectRuntime) {
        guard runtimes[runtime.id] === runtime else { return }
        voicePreviews.stop()
        if playerRuntime !== runtime {
            playerRuntime?.stopPlayback()
            isPlayerExpanded = false
        }
        playerRuntime = runtime
        ProjectSystemMediaController.shared.attach(runtime)
    }

    /// Preview audio has no book ownership, bookmark, Now Playing item or meter.
    /// Pause only once the sample is ready; a failed cache load/synthesis leaves
    /// the book alone. Explicit book starts/resumes invalidate the pending sample.
    func previewVoice(_ voice: SpeechVoice) {
        guard !isShutdown, memoryReleaseTask == nil else { return }
        voicePreviews.preview(voice, text: ReadAloudPreferences.voicePreviewText) { [weak self] in
            self?.playerRuntime?.pausePlayback()
        }
    }

    func releasePlayback(_ runtime: ProjectRuntime) {
        guard playerRuntime === runtime else { return }
        ProjectSystemMediaController.shared.detach(runtime)
        playerRuntime = nil
        isPlayerExpanded = false
    }

    func openPlayerReader() {
        guard let runtime = playerRuntime else { return }
        isPlayerExpanded = false
        if readerProjectID == runtime.id {
            requestReaderFollow()
            return
        }
        playerReaderTarget = PlayerReaderTarget(
            projectID: runtime.id,
            itemID: runtime.playerControlItemID() ?? runtime.continueItemID,
            title: runtime.project?.title ?? "Reader"
        )
    }

    func requestReaderFollow() {
        readerFollowRevision &+= 1
    }

    func runtimeIfLoaded(
        projectID: UUID
    ) -> ProjectRuntime? {
        _ = loadedRuntimeIDs
        guard let runtime = runtimes[projectID],
              loadingTasks[projectID] == nil,
              runtime.didLoad else {
            return nil
        }
        return runtime
    }

    func refreshIfLoaded(
        projectID: UUID
    ) async throws {
        guard let runtime = runtimeIfLoaded(
            projectID: projectID
        ) else {
            return
        }
        try await runtime.refresh()
    }

    func refreshAllLoaded()
        async
    {
        for runtime in runtimes.values
            where runtime.didLoad
        {
            await runtime
                .refreshForExternalPreferencesChange()
        }
    }

    func beginReader(_ runtime: ProjectRuntime) {
        guard runtimes[runtime.id] === runtime else { return }
        activeRuntime = runtime
        readerProjectID = runtime.id
    }

    func endReader(_ runtime: ProjectRuntime) {
        guard readerProjectID == runtime.id else { return }
        readerProjectID = nil
    }

    func makeActive(_ runtime: ProjectRuntime) {
        guard runtimes[runtime.id] === runtime else { return }
        activeRuntime = runtime
    }

    func closePlayer(_ runtime: ProjectRuntime) {
        guard playerRuntime === runtime else { return }
        runtime.closePlayer()
    }

    func forget(projectID: UUID) {
        if playerReaderTarget?.projectID == projectID { playerReaderTarget = nil }
        loadingTasks[projectID]?.cancel()
        loadingTasks.removeValue(forKey: projectID)

        guard let runtime = runtimes.removeValue(
            forKey: projectID
        ) else {
            return
        }

        rememberOfflineQueue(runtime)

        if activeRuntime === runtime {
            activeRuntime = nil
        }
        if readerProjectID == runtime.id {
            readerProjectID = nil
        }
        runtime.shutdown()
        publishLoadedRuntimeIDs()
    }

    /// Library deletion must stop/drain a loaded runtime before removing its
    /// package. Forgetting it only after the disk delete permits late writes.
    func deleteProject(projectID: UUID) async throws {
        guard !deletingProjectIDs.contains(projectID), let projectStore else {
            throw CancellationError()
        }
        deletingProjectIDs.insert(projectID)
        let runtime = runtimes[projectID]
        let loading = loadingTasks[projectID]
        loading?.cancel()
        _ = await loading?.result
        defer {
            forget(projectID: projectID)
            deletingProjectIDs.remove(projectID)
        }
        if let runtime { await runtime.shutdownAndDrain() }
        try Task.checkCancellation()
        try await projectStore.deleteProject(projectID: projectID)
        // A recovery scan may still hold an older catalog snapshot.
        deletedProjectIDs.insert(projectID)
    }

    func closeIdleRuntimes(
        keeping projectID: UUID? = nil
    ) {
        let removable = runtimes.values.filter { runtime in
            runtime.id != projectID
                && runtime !== playerRuntime
                && runtime.id != readerProjectID
                && !runtime.isBackgroundWorkActive
                && runtime.queueController.waitingCount == 0
                && loadingTasks[runtime.id] == nil
        }

        for runtime in removable {
            rememberOfflineQueue(runtime)
            runtimes.removeValue(forKey: runtime.id)
            if activeRuntime === runtime {
                activeRuntime = nil
            }
            runtime.shutdown()
        }

        publishLoadedRuntimeIDs()
    }

    func persistPlaybackCheckpoints()
        async
    {
        let playing =
            runtimes.values.filter {
                $0.isPlaybackActive
            }

        for runtime in playing {
            await runtime
                .persistPlaybackCheckpoint()
        }
    }

    func handleMemoryPressure() {
        guard memoryReleaseTask == nil else { return }
        voicePreviews.stop()
        recoverySuspendedForMemoryPressure = true
        recoveryTask?.cancel()
        let loaded = Array(runtimes.values)
        for runtime in loaded { runtime.suspendForMemoryPressure() }
        closeIdleRuntimes(keeping: activeRuntime?.id)
        memoryReleaseTask = Task { @MainActor in
            let engine = KokoroONNXEngine.shared
            let engineToken = await engine.suspendAndDrain()
            var cacheTokens: [(ProjectRuntime, UUID)] = []
            for runtime in loaded {
                let token = await runtime.chunkCache.suspendAndDrain()
                cacheTokens.append((runtime, token))
                await runtime.queueController.cancelAndDrain()
                await runtime.drainStoppedPlayback()
            }
            await engine.unload()
            for (runtime, token) in cacheTokens {
                await runtime.chunkCache.resumeAdmission(token)
            }
            await engine.resumeAdmission(engineToken)
            for runtime in loaded { runtime.isReleasingSpeechMemory = false }
            for runtime in self.runtimes.values { runtime.isReleasingSpeechMemory = false }
            self.memoryReleaseTask = nil
        }
    }

    func shutdownAll() {
        voicePreviews.shutdown()
        isShutdown = true
        offlineQueueRefreshRevision &+= 1
        persistedOfflineQueueBooks.removeAll()
        isLoadingOfflineQueue = false
        preparationPresenters.removeAll()
        recoveryTask?.cancel()
        recoverySuspendedForMemoryPressure = true
        let values = Array(runtimes.values)
        for task in loadingTasks.values {
            task.cancel()
        }
        loadingTasks.removeAll()
        runtimes.removeAll()
        loadedRuntimeIDs = []
        activeRuntime = nil
        playerRuntime = nil
        isPlayerExpanded = false
        playerReaderTarget = nil
        readerProjectID = nil
        for runtime in values {
            runtime.shutdown()
        }
    }

    private func publishLoadedRuntimeIDs() {
        loadedRuntimeIDs = Set(
            runtimes.values
                .filter(\.didLoad)
                .map(\.id)
        )
    }

    nonisolated private static func message(
        for error: Error
    ) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}






