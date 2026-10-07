import Foundation
import Observation

@Observable
@MainActor
final class ProjectDetailModel {
    struct ItemEntry: Identifiable, Equatable {
        let item: ProjectContentItem
        let resolved: ResolvedNarrationSettings
        let generationKey: String
        let generationStatus: ProjectItemGenerationStatus

        var id: UUID { item.id }
    }

    private(set) var project: ProjectDocument?
    private(set) var items: [ItemEntry] = []
    private(set) var artworkURL: URL?
    private(set) var isLoading = false
    private(set) var didLoad = false
    var errorMessage: String?

    let projectID: UUID

    private let projectStore: ProjectStore?
    private let initializationError: String?

    init(projectID: UUID) {
        self.projectID = projectID
        do {
            projectStore = try ProjectStore()
            initializationError = nil
        } catch {
            projectStore = nil
            initializationError = Self.message(for: error)
        }
    }

    var resolvedProjectSettings: ResolvedNarrationSettings {
        NarrationSettingsResolver.resolveProject(
            project?.settings ?? ProjectNarrationSettings()
        )
    }

    var currentItemID: UUID? {
        project?.playback?.currentItemID
    }

    var continueItemID: UUID? {
        currentItemID ?? items.first?.id
    }

    var readyOfflineCount: Int {
        items.filter {
            $0.generationStatus.state == .readyOffline
        }.count
    }

    var generatingCount: Int {
        items.filter {
            $0.generationStatus.state == .generating
        }.count
    }

    var waitingCount: Int {
        items.filter {
            $0.generationStatus.state == .waiting
        }.count
    }

    var needsAttentionCount: Int {
        items.filter {
            $0.generationStatus.state == .needsAttention
        }.count
    }

    var generatedAudioBytes: Int64 {
        items.reduce(0) {
            $0 + ($1.generationStatus.audioBytes ?? 0)
        }
    }

    func loadIfNeeded() async {
        guard !didLoad else { return }
        await refresh()
    }

    func refresh() async {
        guard let projectStore else {
            errorMessage = initializationError
                ?? "Unable to open this project."
            didLoad = true
            return
        }

        isLoading = true
        defer {
            isLoading = false
            didLoad = true
        }

        do {
            let loaded = try await projectStore.loadProject(
                projectID: projectID
            )
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

            let statuses = try await projectStore.generationStatuses(
                projectID: projectID,
                requests: requests
            )
            let rootURL = await projectStore.rootURL

            project = loaded.project
            items = prepared.map {
                ItemEntry(
                    item: $0.item,
                    resolved: $0.resolved,
                    generationKey: $0.generationKey,
                    generationStatus:
                        statuses[$0.item.id] ?? .notGenerated
                )
            }
            artworkURL = makeArtworkURL(
                project: loaded.project,
                rootURL: rootURL
            )
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    func setProjectVoice(_ voiceID: String?) async -> Bool {
        guard let projectStore, let project else { return false }
        var settings = project.settings
        settings.voiceID = voiceID

        do {
            _ = try await projectStore.updateSettings(
                projectID: projectID,
                settings: settings
            )
            await refresh()
            return true
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
    }

    func setProjectSpeed(_ speed: Double?) async -> Bool {
        guard let projectStore, let project else { return false }
        var settings = project.settings
        settings.speed = speed

        do {
            _ = try await projectStore.updateSettings(
                projectID: projectID,
                settings: settings
            )
            await refresh()
            return true
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
    }

    func setItemVoiceMode(
        itemID: UUID,
        mode: ItemSettingMode
    ) async -> Bool {
        guard let entry = itemEntry(itemID) else { return false }
        var settings = entry.item.settings
        settings.voice.mode = mode

        if mode == .custom,
           settings.voice.customValue == nil {
            settings.voice.customValue = entry.resolved.voiceID
        }

        return await saveItemSettings(
            itemID: itemID,
            settings: settings
        )
    }

    func setItemVoice(
        itemID: UUID,
        voiceID: String
    ) async -> Bool {
        guard let entry = itemEntry(itemID) else { return false }
        var settings = entry.item.settings
        settings.voice.mode = .custom
        settings.voice.customValue = voiceID
        return await saveItemSettings(
            itemID: itemID,
            settings: settings
        )
    }

    func setItemSpeedMode(
        itemID: UUID,
        mode: ItemSettingMode
    ) async -> Bool {
        guard let entry = itemEntry(itemID) else { return false }
        var settings = entry.item.settings
        settings.speed.mode = mode

        if mode == .custom,
           settings.speed.customValue == nil {
            settings.speed.customValue = entry.resolved.speed
        }

        return await saveItemSettings(
            itemID: itemID,
            settings: settings
        )
    }

    func setItemSpeed(
        itemID: UUID,
        speed: Double
    ) async -> Bool {
        guard let entry = itemEntry(itemID) else { return false }
        var settings = entry.item.settings
        settings.speed.mode = .custom
        settings.speed.customValue = speed
        return await saveItemSettings(
            itemID: itemID,
            settings: settings
        )
    }

    func queueGeneration(
        itemID: UUID,
        regenerate: Bool
    ) async -> Bool {
        guard let projectStore,
              let entry = itemEntry(itemID) else {
            return false
        }

        do {
            try await projectStore.enqueueGeneration(
                projectID: projectID,
                requests: [
                    ProjectGenerationRequest(
                        itemID: itemID,
                        generationKey: entry.generationKey
                    )
                ],
                replaceExisting: regenerate
            )
            await refresh()
            return true
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
    }

    func queueRemaining() async -> Bool {
        guard let projectStore else { return false }

        let requests = items.compactMap { entry in
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

        guard !requests.isEmpty else { return true }

        do {
            try await projectStore.enqueueGeneration(
                projectID: projectID,
                requests: requests,
                replaceExisting: false
            )
            await refresh()
            return true
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
    }

    func clearGeneratedAudio(itemID: UUID) async -> Bool {
        guard let projectStore else { return false }

        do {
            try await projectStore.clearGeneratedAudio(
                projectID: projectID,
                itemIDs: [itemID]
            )
            await refresh()
            return true
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
    }

    func clearAllGeneratedAudio() async -> Bool {
        guard let projectStore else { return false }

        do {
            try await projectStore.clearGeneratedAudio(
                projectID: projectID,
                itemIDs: Set(items.map(\.id))
            )
            await refresh()
            return true
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
    }

    func rename(to title: String) async -> Bool {
        guard let projectStore else { return false }

        do {
            _ = try await projectStore.renameProject(
                projectID: projectID,
                to: title
            )
            await refresh()
            return true
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
    }

    func deleteProject() async -> Bool {
        guard let projectStore else { return false }

        do {
            try await projectStore.deleteProject(
                projectID: projectID
            )
            return true
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
    }

    func itemEntry(_ itemID: UUID) -> ItemEntry? {
        items.first { $0.id == itemID }
    }

    private func saveItemSettings(
        itemID: UUID,
        settings: ItemNarrationSettings
    ) async -> Bool {
        guard let projectStore else { return false }

        do {
            _ = try await projectStore.updateContentItemSettings(
                projectID: projectID,
                itemID: itemID,
                settings: settings
            )
            await refresh()
            return true
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
    }

    private func makeArtworkURL(
        project: ProjectDocument,
        rootURL: URL
    ) -> URL? {
        guard let relativePath = project.artwork?.relativePath else {
            return nil
        }

        var url = ProjectPackagePaths.packageURL(
            projectID: project.id,
            rootURL: rootURL
        )
        for component in relativePath.split(separator: "/") {
            url.append(
                path: String(component),
                directoryHint: .inferFromPath
            )
        }
        return url
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
