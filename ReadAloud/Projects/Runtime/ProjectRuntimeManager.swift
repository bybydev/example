import Foundation
import Observation

@Observable
@MainActor
final class ProjectRuntimeManager {
    private(set) var activeRuntime: ProjectRuntime?
    private(set) var loadedRuntimeIDs: Set<UUID> = []
    private(set) var initializationError: String?
    private(set) var readerProjectID: UUID?

    @ObservationIgnored private let projectStore: ProjectStore?
    @ObservationIgnored private let hasPro:
        @MainActor () -> Bool
    @ObservationIgnored private var runtimes: [UUID: ProjectRuntime] = [:]
    @ObservationIgnored private var loadingTasks:
        [UUID: Task<ProjectRuntime, Error>] = [:]

    init(
        hasPro:
            @escaping @MainActor () -> Bool
            = { false }
    ) {
        self.hasPro = hasPro
        do {
            projectStore = try ProjectStore()
            initializationError = nil
        } catch {
            projectStore = nil
            initializationError = Self.message(for: error)
        }
    }

    func activate(
        projectID: UUID
    ) async throws -> ProjectRuntime {
        if let loading = loadingTasks[projectID] {
            let runtime = try await loading.value
            activeRuntime = runtime
            return runtime
        }

        if let existing = runtimes[projectID],
           existing.didLoad {
            activeRuntime = existing
            do {
                try await existing.refresh()
                return existing
            } catch {
                runtimes.removeValue(forKey: projectID)
                publishLoadedRuntimeIDs()
                if activeRuntime === existing {
                    activeRuntime = nil
                }
                existing.shutdown()
                throw error
            }
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
            let rootURL = await projectStore.rootURL
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
                hasPro: hasPro
            )
            runtimes[projectID] = runtime
        }

        activeRuntime = runtime

        let loading = Task { @MainActor in
            try await runtime.loadIfNeeded()
            return runtime
        }
        loadingTasks[projectID] = loading

        do {
            let loaded = try await loading.value
            loadingTasks.removeValue(forKey: projectID)
            publishLoadedRuntimeIDs()
            activeRuntime = loaded
            return loaded
        } catch {
            loadingTasks.removeValue(forKey: projectID)
            runtimes.removeValue(forKey: projectID)
            publishLoadedRuntimeIDs()
            if activeRuntime === runtime {
                activeRuntime = nil
            }
            runtime.shutdown()
            throw error
        }
    }

    var playbackRuntime: ProjectRuntime? {
        if let activeRuntime,
           activeRuntime.isPlaybackActive
        {
            return activeRuntime
        }

        return runtimes.values.first(
            where: {
                $0.isPlaybackActive
            }
        )
    }

    func runtimeIfLoaded(
        projectID: UUID
    ) -> ProjectRuntime? {
        _ = loadedRuntimeIDs
        guard let runtime = runtimes[projectID],
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

    func forget(projectID: UUID) {
        loadingTasks[projectID]?.cancel()
        loadingTasks.removeValue(forKey: projectID)

        guard let runtime = runtimes.removeValue(
            forKey: projectID
        ) else {
            return
        }

        if activeRuntime === runtime {
            activeRuntime = nil
        }
        if readerProjectID == runtime.id {
            readerProjectID = nil
        }
        runtime.shutdown()
        publishLoadedRuntimeIDs()
    }

    func closeIdleRuntimes(
        keeping projectID: UUID? = nil
    ) {
        let removable = runtimes.values.filter { runtime in
            runtime.id != projectID
                && runtime.id != readerProjectID
                && !runtime.isBackgroundWorkActive
        }

        for runtime in removable {
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

    func shutdownAll() {
        let values = Array(runtimes.values)
        for task in loadingTasks.values {
            task.cancel()
        }
        loadingTasks.removeAll()
        runtimes.removeAll()
        loadedRuntimeIDs = []
        activeRuntime = nil
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
