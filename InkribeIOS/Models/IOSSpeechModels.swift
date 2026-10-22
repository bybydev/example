import Foundation
import InkribeModelAssets
import Observation

@MainActor
@Observable
final class IOSSpeechModels {
    private static let selectionKey = "com.hoangbkit.inkribe.ios.speech-model"
    private(set) var selectedID: String
    private(set) var inventory = IOSSpeechModelInventory(bundled: [], cached: [], downloaded: [], cachedBytes: 0)
    private(set) var downloadingID: String?
    private(set) var fraction = 0.0
    private(set) var isRemoving = false
    private(set) var isLoading = false
    var errorMessage: String?
    private var started = false
    private var downloadTask: Task<Void, Never>?
    private var downloadToken: UUID?
    private var inventoryGeneration = 0

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.selectionKey)
        let bundled = IOSSpeechModelCatalog.all.filter { IOSSpeechModelCatalog.bundledURL($0) != nil }
        if let saved, IOSSpeechModelCatalog.all.contains(where: { $0.id == saved }),
           IOSSpeechModelCatalog.downloadsEnabled || bundled.contains(where: { $0.id == saved }) {
            selectedID = saved
        } else {
            selectedID = bundled.first?.id ?? IOSSpeechModelCatalog.all[0].id
        }
    }

    var selectedName: String { (try? IOSSpeechModelCatalog.descriptor(selectedID).displayName) ?? "Speech model" }
    var available: Bool { !isRemoving && isAvailable(selectedID) }

    func isAvailable(_ id: String) -> Bool {
        inventory.bundled.contains(id) || (IOSSpeechModelCatalog.downloadsEnabled && inventory.downloaded.contains(id))
    }

    func select(_ id: String) {
        guard !isRemoving, IOSSpeechModelCatalog.all.contains(where: { $0.id == id }),
              IOSSpeechModelCatalog.downloadsEnabled || inventory.bundled.contains(id) else { return }
        selectedID = id
        UserDefaults.standard.set(id, forKey: Self.selectionKey)
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
            let value = try await IOSSpeechModelStore.shared.inventory()
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
                try await IOSSpeechModelStore.shared.download(id) { [weak self] value in
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

    func remove(_ id: String, protectedIDs: Set<String>, jobStorageError: String?) async {
        guard jobStorageError == nil else {
            errorMessage = "Resolve the transcription storage problem before removing speech models."
            return
        }
        guard !protectedIDs.contains(id) else { errorMessage = IOSModelError.inUse.localizedDescription; return }
        guard !isRemoving, downloadingID != id else { errorMessage = IOSModelError.busy.localizedDescription; return }
        isRemoving = true
        errorMessage = nil
        defer { isRemoving = false }
        do {
            try await IOSSpeechModelStore.shared.remove(id)
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }
}
