import Foundation
import InkribeModelAssets
import Observation

@MainActor
@Observable
final class SpeechModels {
    var activeID: String { SpeechEngine.shared.activeModelID }
    private(set) var inventory = SpeechModelInventory(bundled: [], cached: [], downloaded: [], cachedBytes: 0)
    private(set) var downloadingID: String?
    private(set) var fraction = 0.0
    private(set) var isRemoving = false
    private(set) var isLoading = false
    var errorMessage: String?
    private var started = false
    private var downloadTask: Task<Void, Never>?
    private var downloadToken: UUID?
    private var inventoryGeneration = 0

    var activeName: String { (try? SpeechModelCatalog.descriptor(activeID).displayName) ?? "Speech model" }
    var available: Bool { !isRemoving && isAvailable(activeID) }

    func isAvailable(_ id: String) -> Bool {
        inventory.bundled.contains(id) || (SpeechModelCatalog.downloadsEnabled && inventory.downloaded.contains(id))
    }

    func start() {
        guard !started else { return }
        started = true
        Task { await refresh() }
    }

    func refresh() async {
        inventoryGeneration += 1
        let generation = inventoryGeneration
        isLoading = true
        defer { if generation == inventoryGeneration { isLoading = false } }
        do {
            let value = try await SpeechModelStore.shared.inventory()
            if generation == inventoryGeneration { inventory = value }
        } catch {
            if generation == inventoryGeneration { errorMessage = error.localizedDescription }
        }
    }

    func download(_ id: String) {
        guard downloadTask == nil, !isRemoving else { return }
        errorMessage = nil
        downloadingID = id
        fraction = 0
        let token = UUID()
        downloadToken = token
        downloadTask = Task {
            do {
                try await SpeechModelStore.shared.download(id) { [weak self] value in
                    Task { @MainActor in
                        guard let self, self.downloadToken == token else { return }
                        self.fraction = max(self.fraction, value)
                    }
                }
            } catch is CancellationError {
                // Explicit cancel leaves the previous installed models untouched.
            } catch {
                errorMessage = error.localizedDescription
            }
            downloadToken = nil
            downloadingID = nil
            downloadTask = nil
            await refresh()
        }
    }

    func cancelDownload() { downloadTask?.cancel() }

    func cancelDownloadAndWait() async {
        let task = downloadTask
        task?.cancel()
        await task?.value
    }

    func remove(_ id: String, protectedIDs: Set<String>, jobStorageError: String?) async {
        guard jobStorageError == nil else {
            errorMessage = "Resolve the transcription storage problem before removing speech models."
            return
        }
        guard !protectedIDs.contains(id) else { errorMessage = ModelError.inUse.localizedDescription; return }
        guard !isRemoving, downloadingID != id else { errorMessage = ModelError.busy.localizedDescription; return }
        isRemoving = true
        errorMessage = nil
        defer { isRemoving = false }
        do {
            try await SpeechModelStore.shared.remove(id)
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }
}
