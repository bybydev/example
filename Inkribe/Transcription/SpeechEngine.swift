import Foundation
import InkribeModelAssets
import Observation
import WhisperRuntime

/// One app-wide active model and one retained native context. Jobs never select
/// an engine or keep a model alive. ProcessingRuntime serializes native work.
@MainActor
@Observable
final class SpeechEngine {
    static let shared = SpeechEngine()
    private static let selectionKey = "com.hoangbkit.inkribe.ios.speech-model"
    private(set) var activeModelID: String
    private(set) var loadedModelID: String?
    private var inUse = false
    @ObservationIgnored private var runtime: NativeWhisperRuntime?
    @ObservationIgnored private var location: SpeechModelLocation?
    @ObservationIgnored private var lease: UUID?

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.selectionKey)
        let bundled = SpeechModelCatalog.all.filter { SpeechModelCatalog.bundledURL($0) != nil }
        if let saved, SpeechModelCatalog.all.contains(where: { $0.id == saved }),
           SpeechModelCatalog.downloadsEnabled || bundled.contains(where: { $0.id == saved }) {
            activeModelID = saved
        } else {
            activeModelID = bundled.first?.id ?? SpeechModelCatalog.all[0].id
        }
    }

    /// Called only after the confirmed switch has cancelled and drained work.
    func activate(_ id: String) async throws {
        guard !inUse else { throw SpeechError.busy }
        _ = try SpeechModelCatalog.descriptor(id)
        let inventory = try await SpeechModelStore.shared.inventory()
        guard inventory.bundled.contains(id) ||
            (SpeechModelCatalog.downloadsEnabled && inventory.downloaded.contains(id)) else { throw SpeechError.missingModel }
        await unload()
        activeModelID = id
        UserDefaults.standard.set(id, forKey: Self.selectionKey)
    }

    func withModel(_ operation: @escaping @Sendable (NativeWhisperRuntime, ModelAssetDescriptor) async throws -> Void) async throws {
        try Task.checkCancellation()
        guard !inUse else { throw SpeechError.busy }
        inUse = true
        defer { inUse = false }
        if runtime == nil {
            let token = UUID()
            let model = try await SpeechModelStore.shared.acquire(activeModelID, lease: token)
            location = model; lease = token; loadedModelID = model.descriptor.id
            runtime = NativeWhisperRuntime(modelURL: model.url,
                configuration: .init(threadCount: Int32(max(1, min(4, ProcessInfo.processInfo.processorCount - 1))),
                    useGPU: false, flashAttention: false), captureTokenBytes: true, modelDescriptor: model.descriptor)
        }
        guard let runtime, let location else { throw SpeechError.missingModel }
        do {
            try Task.checkCancellation()
            try await runtime.loadModel()
            try Task.checkCancellation()
            try await operation(runtime, location.descriptor)
        } catch {
            // A cancelled/failed native context is released before the next job.
            await unload()
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private func unload() async {
        let previous = runtime
        let token = lease
        runtime = nil; location = nil; lease = nil; loadedModelID = nil
        await previous?.unloadModel()
        if let token { await SpeechModelStore.shared.release(token) }
    }
}
