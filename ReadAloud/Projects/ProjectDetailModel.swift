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

        init(runtimeState: ProjectRuntimeItemState) {
            item = runtimeState.item
            resolved = runtimeState.resolved
            generationKey = runtimeState.generationKey
            generationStatus = runtimeState.generationStatus
        }
    }

    let runtime: ProjectRuntime
    var errorMessage: String?

    init(runtime: ProjectRuntime) {
        self.runtime = runtime
    }

    var projectID: UUID {
        runtime.id
    }

    var project: ProjectDocument? {
        runtime.project
    }

    var items: [ItemEntry] {
        runtime.itemStates.map(ItemEntry.init)
    }

    var artworkURL: URL? {
        runtime.artworkURL
    }

    var isLoading: Bool {
        runtime.isLoading
    }

    var didLoad: Bool {
        runtime.didLoad
    }

    var resolvedProjectSettings: ResolvedNarrationSettings {
        runtime.resolvedProjectSettings
    }

    var currentItemID: UUID? {
        runtime.currentItemID
    }

    var continueItemID: UUID? {
        runtime.continueItemID
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
        do {
            try await runtime.loadIfNeeded()
            errorMessage = nil
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    func refresh() async {
        do {
            try await runtime.refresh()
            errorMessage = nil
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    func setProjectVoice(_ voiceID: String?) async -> Bool {
        do {
            try await runtime.updateProjectVoice(voiceID)
            errorMessage = nil
            return true
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
    }

    func setProjectSpeed(_ speed: Double?) async -> Bool {
        do {
            try await runtime.updateProjectSpeed(speed)
            errorMessage = nil
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
        do {
            try await runtime.updateItemVoiceMode(
                itemID: itemID,
                mode: mode
            )
            errorMessage = nil
            return true
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
    }

    func setItemVoice(
        itemID: UUID,
        voiceID: String
    ) async -> Bool {
        do {
            try await runtime.updateItemVoice(
                itemID: itemID,
                voiceID: voiceID
            )
            errorMessage = nil
            return true
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
    }

    func setItemSpeedMode(
        itemID: UUID,
        mode: ItemSettingMode
    ) async -> Bool {
        do {
            try await runtime.updateItemSpeedMode(
                itemID: itemID,
                mode: mode
            )
            errorMessage = nil
            return true
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
    }

    func setItemSpeed(
        itemID: UUID,
        speed: Double
    ) async -> Bool {
        do {
            try await runtime.updateItemSpeed(
                itemID: itemID,
                speed: speed
            )
            errorMessage = nil
            return true
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
    }

    func queueGeneration(
        itemID: UUID,
        regenerate: Bool
    ) async -> Bool {
        do {
            try await runtime.enqueueGeneration(
                itemID: itemID,
                regenerate: regenerate
            )
            errorMessage = nil
            return true
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
    }

    func queueRemaining() async -> Bool {
        do {
            try await runtime.enqueueRemainingGeneration()
            errorMessage = nil
            return true
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
    }

    func clearGeneratedAudio(itemID: UUID) async -> Bool {
        do {
            try await runtime.clearGeneratedAudio(
                itemIDs: [itemID]
            )
            errorMessage = nil
            return true
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
    }

    func clearAllGeneratedAudio() async -> Bool {
        do {
            try await runtime.clearGeneratedAudio(
                itemIDs: Set(items.map(\.id))
            )
            errorMessage = nil
            return true
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
    }

    func rename(to title: String) async -> Bool {
        do {
            try await runtime.rename(to: title)
            errorMessage = nil
            return true
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
    }

    func deleteProject() async -> Bool {
        do {
            try await runtime.deleteProject()
            errorMessage = nil
            return true
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
    }

    func itemEntry(_ itemID: UUID) -> ItemEntry? {
        runtime.itemState(itemID).map(ItemEntry.init)
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
