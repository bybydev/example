import Foundation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - One Photos video acquisition path
//
// New Project and Add clips both import videos through the same native
// PHPicker + NSItemProvider request. PhotosPickerItem.loadTransferable with
// preferredItemEncoding .current stalls waiting for the absolute original and
// can simply never call back; provider file requests with .automatic
// substitution are bounded, staged per video and retryable instead.

/// An app-owned copy of one Photos-picked video, independent of the provider's
/// short-lived security scope. Publication copies it into project storage.
struct PickedMovie: Sendable {
    let localURL: URL
    let displayName: String
}

/// One Photos selection between receiving the provider and its resolved
/// loading, copying or failure stage. Success removes the entry and publishes
/// an ImportInput carrying the same identity.
struct PhotoMovieSelection: Identifiable {
    let id = UUID()
    let provider: NSItemProvider
    let name: String
    var stage = Stage.loading

    enum Stage {
        case loading
        case retrying
        case copying
        case failed(String)
    }

    var isFailed: Bool {
        if case .failed = stage { return true }
        return false
    }
}

/// A selection's cross-task payload. NSItemProvider is not Sendable, but Inkribe
/// serializes every access: probing and loading happen only inside this one
/// selection's own file request, and the box exists purely to move the
/// reference into that request's MainActor start.
struct PhotoLoad: @unchecked Sendable {
    let provider: NSItemProvider
    let id: UUID
    let name: String
}

/// One native picker presentation request in either model's selection session.
struct PhotoPickerRequest: Identifiable {
    let id = UUID()
    let selectionID: UUID
}

/// Native video picker with ordered selection. No full photo-library permission
/// or PHAsset lookup is needed. `.automatic` lets the system substitute a
/// complete, compatible representation when the absolute original cannot be
/// delivered; `.current` can stall on exactly that wait.
@MainActor
struct PhotosVideoPicker: UIViewControllerRepresentable {
    let onSelection: ([NSItemProvider]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelection: onSelection) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .videos
        configuration.selectionLimit = 0
        configuration.selection = .ordered
        configuration.preferredAssetRepresentationMode = .automatic
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: PHPickerViewController, context: Context) { }

    @MainActor
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let onSelection: ([NSItemProvider]) -> Void
        private var completed = false

        init(onSelection: @escaping ([NSItemProvider]) -> Void) { self.onSelection = onSelection }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !completed else { return }
            completed = true
            onSelection(results.map(\.itemProvider))
        }
    }
}

/// Retains the provider and its cancellation handle independently of the picker.
/// Copy inside the provider callback: its temporary URL expires when it returns.
/// A stalled representation is abandoned by generation and retried with the next
/// registered movie type instead of waiting for a callback that may never arrive.
@MainActor
final class PhotoMovieRequest {
    private enum Method {
        case fileRepresentation
        case item
    }

    private struct Attempt {
        let type: String
        let method: Method
    }

    /// A local representation should arrive quickly. A silent provider is
    /// abandoned per attempt so another representation can be tried, while the
    /// overall limit still leaves slow iCloud materialization some room.
    private static let firstAttemptLimit: Duration = .seconds(30)
    private static let nextAttemptLimit: Duration = .seconds(15)
    private static let overallLimit: Duration = .seconds(120)
    private static let typePollCount = 16

    private var provider: NSItemProvider?
    private var continuation: CheckedContinuation<PickedMovie, Error>?
    private var progress: Progress?
    private var overallDeadline: Task<Void, Never>?
    private var attemptWatchdog: Task<Void, Never>?
    private var resolutionTask: Task<Void, Never>?
    private var attempts: [Attempt] = []
    private var attemptIndex = 0
    private var attemptGeneration = 0
    private var lastError: Error?
    private var suggestedName: String?
    private var onStage: (@MainActor (PhotoMovieSelection.Stage) -> Void)?
    private var result: Result<PickedMovie, Error>?
    private var deliveredURL: URL?

    static func load(_ provider: NSItemProvider,
                     onStage: @escaping @MainActor (PhotoMovieSelection.Stage) -> Void) async throws -> PickedMovie {
        let request = PhotoMovieRequest()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                request.start(provider, onStage: onStage, continuation: continuation)
            }
        } onCancel: {
            Task { @MainActor in request.finish(.failure(CancellationError()), cancelProvider: true) }
        }
    }

    private func start(_ provider: NSItemProvider,
                       onStage: @escaping @MainActor (PhotoMovieSelection.Stage) -> Void,
                       continuation: CheckedContinuation<PickedMovie, Error>) {
        if let result { continuation.resume(with: result); return }
        self.continuation = continuation
        self.provider = provider
        self.suggestedName = provider.suggestedName
        self.onStage = onStage
        // Bound the whole request before any provider work starts, including the
        // lazy type probe, so a provider that never calls back cannot leave the
        // row loading indefinitely.
        armOverallDeadline()
        resolutionTask = Task { @MainActor in
            guard let provider = self.provider else { return }
            let types = await Self.resolveMovieTypes(provider)
            guard self.result == nil else { return }
            guard !types.isEmpty else {
                self.finish(.failure(PhotoMovieRequestError.missingFile))
                return
            }
            self.attempts = Self.attemptList(for: types)
            self.beginAttempt(0)
        }
    }

    private static func resolveMovieTypes(_ provider: NSItemProvider) async -> [String] {
        // Picker-backed providers register their types lazily. Poll briefly
        // instead of rejecting a valid video on an immediately empty list.
        for _ in 0..<typePollCount {
            let types = movieTypeCandidates(provider)
            if !types.isEmpty { return types }
            if Task.isCancelled { return [] }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            return [UTType.movie.identifier]
        }
        return []
    }

    private static func movieTypeCandidates(_ provider: NSItemProvider) -> [String] {
        var seen = Set<String>()
        var concrete: [String] = []
        var abstract: [String] = []
        for identifier in provider.registeredTypeIdentifiers {
            guard let type = UTType(identifier), type.conforms(to: .movie),
                  seen.insert(identifier).inserted else { continue }
            if type == .movie { abstract.append(identifier) } else { concrete.append(identifier) }
        }
        // Concrete movie types avoid an unnecessary compatibility substitution.
        // Names are sorted only to keep the attempt order deterministic.
        return Array((concrete.sorted() + abstract).prefix(3))
    }

    private static func attemptList(for types: [String]) -> [Attempt] {
        // Every file representation is requested before raw item acquisition: a
        // file URL is the only video payload copied without loading the whole
        // asset into memory.
        types.map { Attempt(type: $0, method: .fileRepresentation) }
            + types.map { Attempt(type: $0, method: .item) }
    }

    private func beginAttempt(_ index: Int) {
        guard result == nil else { return }
        guard index < attempts.count else {
            finish(.failure(lastError ?? PhotoMovieRequestError.noResponse))
            return
        }
        attemptIndex = index
        attemptGeneration += 1
        let generation = attemptGeneration
        progress?.cancel()
        progress = nil
        if index > 0 { onStage?(.retrying) }
        armAttemptWatchdog(
            generation: generation,
            limit: index == 0 ? Self.firstAttemptLimit : Self.nextAttemptLimit
        )
        let attempt = attempts[index]
        let type = attempt.type
        let suggestedName = self.suggestedName
        switch attempt.method {
        // Provider callbacks capture self strongly. Weak captures across these
        // two unordered MainActor hops fail Swift 6 strict concurrency, and the
        // only retain chain through the block is broken by finish() cancelling
        // and clearing progress.
        case .fileRepresentation:
            progress = provider?.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                if let url, error == nil {
                    Task { @MainActor in self.reportCopying(generation: generation) }
                    // Stay inside the callback for this synchronous owned copy.
                    let copied = Self.copyFile(url, error: nil, suggestedName: suggestedName, type: type)
                    Task { @MainActor in self.deliver(copied, generation: generation) }
                } else {
                    let message = error?.localizedDescription
                    Task { @MainActor in self.attemptFailed(generation: generation, message: message) }
                }
            }
        case .item:
            // loadItem returns no progress handle and cannot be cancelled; its
            // late completion is rejected by the attempt generation and any
            // copied file is removed.
            provider?.loadItem(forTypeIdentifier: type, options: nil) { item, error in
                if item is URL {
                    Task { @MainActor in self.reportCopying(generation: generation) }
                }
                // Copy synchronously before returning; the acquired item expires too.
                let copied = Self.copyItem(item, error: error, suggestedName: suggestedName, type: type)
                Task { @MainActor in self.deliver(copied, generation: generation) }
            }
        }
    }

    private func armAttemptWatchdog(generation: Int, limit: Duration) {
        attemptWatchdog?.cancel()
        attemptWatchdog = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: limit) } catch { return }
            self?.attemptStalled(generation: generation)
        }
    }

    private func armOverallDeadline() {
        overallDeadline?.cancel()
        overallDeadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: Self.overallLimit) } catch { return }
            self?.finish(.failure(PhotoMovieRequestError.timedOut), cancelProvider: true)
        }
    }

    private func reportCopying(generation: Int) {
        guard result == nil, attemptGeneration == generation else { return }
        onStage?(.copying)
    }

    private func attemptStalled(generation: Int) {
        guard result == nil, attemptGeneration == generation else { return }
        // Cancelling the progress handle is the only way to release a provider
        // request that never calls back. A later completion is rejected by the
        // generation check and its copied file is removed by deliver.
        progress?.cancel()
        advanceAttempt(from: generation)
    }

    private func attemptFailed(generation: Int, message: String?) {
        guard result == nil, attemptGeneration == generation else { return }
        lastError = message.map(PhotoMovieRequestError.loading) ?? PhotoMovieRequestError.noResponse
        advanceAttempt(from: generation)
    }

    private func deliver(_ result: Result<PickedMovie, Error>, generation: Int) {
        guard self.result == nil, attemptGeneration == generation else {
            if case .success(let file) = result { try? FileManager.default.removeItem(at: file.localURL) }
            return
        }
        switch result {
        case .success:
            finish(result)
        case .failure(let error):
            lastError = error
            advanceAttempt(from: generation)
        }
    }

    private func advanceAttempt(from generation: Int) {
        guard result == nil, attemptGeneration == generation else { return }
        attemptWatchdog?.cancel(); attemptWatchdog = nil
        progress?.cancel(); progress = nil
        beginAttempt(attemptIndex + 1)
    }

    private func finish(_ result: Result<PickedMovie, Error>, cancelProvider: Bool = false) {
        guard self.result == nil else {
            if case .success(let file) = result, file.localURL != deliveredURL {
                try? FileManager.default.removeItem(at: file.localURL)
            }
            return
        }
        self.result = result
        if case .success(let file) = result { deliveredURL = file.localURL }
        // Reject every outstanding callback as stale while still removing any
        // owned file it managed to copy before this finish was observed.
        attemptGeneration += 1
        let continuation = self.continuation; self.continuation = nil
        overallDeadline?.cancel(); overallDeadline = nil
        attemptWatchdog?.cancel(); attemptWatchdog = nil
        resolutionTask?.cancel(); resolutionTask = nil
        let progress = self.progress; self.progress = nil
        provider = nil
        onStage = nil
        suggestedName = nil
        if cancelProvider { progress?.cancel() }
        continuation?.resume(with: result)
    }

    nonisolated private static func copyFile(_ url: URL?, error: Error?, suggestedName: String?,
                                             type: String) -> Result<PickedMovie, Error> {
        if let error { return .failure(PhotoMovieRequestError.loading(error.localizedDescription)) }
        guard let url, url.isFileURL else { return .failure(PhotoMovieRequestError.missingFile) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("InkribePhotoTransfers", isDirectory: true)
        let ext = url.pathExtension.isEmpty ? (UTType(type)?.preferredFilenameExtension ?? "mov") : url.pathExtension
        let copy = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: copy)
            let values = try copy.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
                throw PhotoMovieRequestError.missingFile
            }
            let name: String
            if let suggestedName, !suggestedName.isEmpty { name = suggestedName }
            else { name = url.lastPathComponent }
            return .success(PickedMovie(localURL: copy, displayName: name.isEmpty ? "Imported Video" : name))
        } catch {
            try? FileManager.default.removeItem(at: copy)
            return .failure(PhotoMovieRequestError.copying(error.localizedDescription))
        }
    }

    /// Last-resort acquisition when the file representation itself is rejected.
    /// The acquired item is only usable synchronously inside this callback.
    nonisolated private static func copyItem(_ item: Any?, error: Error?, suggestedName: String?,
                                             type: String) -> Result<PickedMovie, Error> {
        if let error { return .failure(PhotoMovieRequestError.loading(error.localizedDescription)) }
        guard let url = item as? URL, url.isFileURL else { return .failure(PhotoMovieRequestError.missingFile) }
        return copyFile(url, error: nil, suggestedName: suggestedName, type: type)
    }
}

private enum PhotoMovieRequestError: LocalizedError {
    case loading(String), copying(String), missingFile, noResponse, timedOut

    var errorDescription: String? {
        switch self {
        case .loading(let detail): "Couldn’t load this video from Photos. \(detail)"
        case .copying(let detail): "Couldn’t copy this video into Inkribe. \(detail)"
        case .missingFile: "Photos did not provide a readable video file."
        case .noResponse: "Photos stopped responding for this video. Retry, or choose the video again."
        case .timedOut: "Photos did not finish providing this video within two minutes. Retry when the video is available on your iPhone."
        }
    }
}

/// Optional row artwork has its own task and never gates a Create/Add action.
/// Removing a row, leaving the screen or a timeout keeps a plain video icon.
struct SourceThumbnail: View {
    let source: ImportInput
    let duration: MediaTime
    @State private var data: Data?

    var body: some View {
        MediaThumbnail(data: data)
            .task(id: source.id) {
                let image = await ImportMediaReviewer.preview(source, duration: duration)
                guard !Task.isCancelled else { return }
                data = image
            }
    }
}
