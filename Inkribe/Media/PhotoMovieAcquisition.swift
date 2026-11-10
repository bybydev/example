import Foundation
import OSLog
import Photos
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - One Photos video acquisition path
//
// New Project and Add clips both import videos through two cooperative paths.
// PhotoKit originals first: the native picker yields an asset identifier and
// PhotoMovieLoader streams the asset's own video resource into app-owned
// staging with real byte progress and explicit errors — the file the library
// actually stores, never a system substitution. The bounded NSItemProvider
// request stays as the fallback: provider file requests against the current
// representation, watched per attempt and retryable, for Limited access,
// denied access or items without a video resource. PhotosPickerItem
// loadTransferable and loadItem coercion are never used.

/// An app-owned copy of one Photos-picked video, independent of the provider's
/// short-lived security scope. Publication copies it into project storage.
struct PickedMovie: Sendable {
    let localURL: URL
    let displayName: String
    /// The representation that actually delivered these bytes — a library
    /// resource UTI or a provider type identifier — for quality diagnostics.
    private let representation: String?

    init(localURL: URL, displayName: String, representation: String? = nil) {
        self.localURL = localURL
        self.displayName = displayName
        self.representation = representation
    }
}

/// One Photos selection between receiving the picker result and its queued,
/// loading, copying or failure stage. Success removes the entry and publishes
/// an ImportInput carrying the same identity.
struct PhotoMovieSelection: Identifiable {
    let id = UUID()
    let provider: NSItemProvider
    /// The library asset behind the pick, when the picker handed one.
    let assetID: String?
    let name: String
    var stage = Stage.loading

    enum Stage {
        case waiting
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
    let assetID: String?
}

/// One native picker presentation request in either model's selection session.
struct PhotoPickerRequest: Identifiable {
    let id = UUID()
    let selectionID: UUID
}

/// One picked item. The provider describes the choice and is the fallback
/// byte source; the library asset identifier only resolves for it when photo
/// access is granted, and is the path that delivers the actual original.
struct PhotoPick {
    let provider: NSItemProvider
    let assetID: String?
}

/// Native video picker with ordered selection. `.shared` makes results carry
/// asset identifiers so PhotoKit can stream the original file; `.current`
/// keeps the provider fallback consistent (a local original completes
/// immediately, an offloaded one waits for its download, watched by the
/// fallback's request watchdogs).
@MainActor
struct PhotosVideoPicker: UIViewControllerRepresentable {
    let onSelection: ([PhotoPick]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelection: onSelection) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .videos
        configuration.selectionLimit = 0
        configuration.selection = .ordered
        // Apple's documented video pattern: deliver the representation that
        // exists on the iPhone now. The .automatic substitution handed back
        // zero-byte copies for ordinary local videos, which the copy gate
        // rejected as "Photos did not provide a readable video file."
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: PHPickerViewController, context: Context) { }

    @MainActor
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let onSelection: ([PhotoPick]) -> Void
        private var completed = false

        init(onSelection: @escaping ([PhotoPick]) -> Void) { self.onSelection = onSelection }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !completed else { return }
            completed = true
            onSelection(results.map { PhotoPick(provider: $0.itemProvider, assetID: $0.assetIdentifier) })
        }
    }
}

/// Retains the provider and its cancellation handle independently of the picker.
/// Copy inside the provider callback: its temporary URL expires when it returns.
/// A stalled representation is abandoned by generation and retried with the next
/// registered movie type instead of waiting for a callback that may never arrive.
@MainActor
final class PhotoMovieRequest {
    private struct Attempt {
        let type: String
    }

    /// Attempt windows are silence windows: the provider earns extensions
    /// whenever its transfer moves, so a slow-but-alive copy or iCloud
    /// download is never killed mid-transfer. The overall limit still bounds
    /// the whole request.
    private static let firstAttemptLimit: Duration = .seconds(45)
    private static let nextAttemptLimit: Duration = .seconds(30)
    // Only attempts that are visibly transferring can reach this cap; silent
    // providers die at their attempt windows far earlier. Five minutes gives
    // a real iCloud download room to finish while still bounding a stuck row.
    private static let overallLimit: Duration = .seconds(300)
    private static let typePollCount = 16

    private var provider: NSItemProvider?
    private var continuation: CheckedContinuation<PickedMovie, Error>?
    private var progress: Progress?
    private var progressObserver: NSKeyValueObservation?
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
        // Registered representations first, then the abstract movie type as the
        // final documented fallback: the provider substitutes a compatible,
        // complete file for it. loadItem is never attempted: Apple's guidance
        // states the coercion interface is unsupported by
        // PHPickerViewController, so its requests simply never complete.
        var list = types.map { Attempt(type: $0) }
        let movie = UTType.movie.identifier
        if !types.contains(movie) { list.append(Attempt(type: movie)) }
        return list
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
        releaseAttemptProgress()
        if index > 0 { onStage?(.retrying) }
        armAttemptWatchdog(
            generation: generation,
            limit: index == 0 ? Self.firstAttemptLimit : Self.nextAttemptLimit
        )
        let type = attempts[index].type
        let suggestedName = self.suggestedName
        // Provider callback captures self strongly. Weak captures across these
        // two unordered MainActor hops fail Swift 6 strict concurrency, and the
        // only retain chain through the block is broken by finish() cancelling
        // and clearing progress.
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
        // The watchdog kills silence, not work: every movement of the
        // provider's transfer progress re-arms this attempt's window, so a
        // slow-but-alive large copy or an iCloud download keeps loading. Only
        // a fully silent window (no motion, no callback) ends it.
        observeProgressMotion(generation: generation)
    }

    private func observeProgressMotion(generation: Int) {
        guard let progress else { return }
        progressObserver = progress.observe(\.fractionCompleted, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.noteProgressMotion(generation: generation) }
        }
    }

    private func noteProgressMotion(generation: Int) {
        guard result == nil, attemptGeneration == generation, progress != nil else { return }
        armAttemptWatchdog(generation: generation, limit: Self.nextAttemptLimit)
    }

    private func releaseAttemptProgress() {
        progress?.cancel()
        progress = nil
        progressObserver?.invalidate()
        progressObserver = nil
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
        // Fires only after a full silent window; transfer motion re-arms the
        // watchdog first. Cancelling the progress handle is the only way to
        // release a provider request that never calls back. A later completion
        // is rejected by the generation check and its copied file is removed
        // by deliver.
        releaseAttemptProgress()
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
        releaseAttemptProgress()
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
        progressObserver?.invalidate(); progressObserver = nil
        provider = nil
        onStage = nil
        suggestedName = nil
        if cancelProvider { progress?.cancel() }
        continuation?.resume(with: result)
    }

    /// The owned copy of a Photos selection must survive the whole selection
    /// session (review, later videos, the Add press), so it stages under
    /// Application Support like the repository's own originals.
    nonisolated static func stagingRoot() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("InkribePhotoStaging", isDirectory: true)
    }

    /// Removes the staging root. Only call it where no selection session can be
    /// staging (a session's beginning): the presenting models delete their own
    /// owned copies; this clears files left behind by a crashed session.
    nonisolated static func sweepStaleStaging() {
        try? FileManager.default.removeItem(at: stagingRoot())
    }

    nonisolated private static func copyFile(_ url: URL?, error: Error?, suggestedName: String?,
                                             type: String) -> Result<PickedMovie, Error> {
        if let error { return .failure(PhotoMovieRequestError.loading(error.localizedDescription)) }
        guard let url, url.isFileURL else { return .failure(PhotoMovieRequestError.missingFile) }
        // Durable, app-owned staging: iOS can purge temporaryDirectory at any
        // backgrounding, which broke the Add step's copy of already-shown rows.
        // The repository also stages originals under Application Support for
        // the same reason.
        let directory = Self.stagingRoot()
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
            return .success(PickedMovie(localURL: copy,
                displayName: name.isEmpty ? "Imported Video" : name, representation: type))
        } catch {
            try? FileManager.default.removeItem(at: copy)
            return .failure(PhotoMovieRequestError.copying(error.localizedDescription))
        }
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
        case .timedOut: "Photos did not finish providing this video within five minutes. Retry when the video is available on your iPhone."
        }
    }
}

// MARK: - PhotoKit original path
//
// The provider pipeline asks "a compatible file for this pick" and the system
// decides which bytes satisfy it: substitutions, no progress protocol and
// silent stalls are structural there. The PhotoKit path names the asset's own
// video resource instead: byte-streamed with real progress, cancellable,
// explicit errors and deterministic bytes — exactly the file the library
// stores. PhotoMovieLoader prefers it whenever the picker handed an asset
// identifier and library access is granted, and falls back to the bounded
// provider request otherwise (Limited access, denied access, or no video
// resource). Shared staging keeps both paths' outputs interchangeable.

struct PhotoKitUnresolvable: Error, LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}

/// Chooses the bytes path for one selection. Both paths publish the same
/// stages and end in an app-owned staged PickedMovie.
@MainActor
enum PhotoMovieLoader {
    private static let logger = Logger(subsystem: "com.hoangbkit.inkribe",
                                       category: "PhotoMovieAcquisition")

    static func load(_ load: PhotoLoad,
                     onStage: @escaping @MainActor (PhotoMovieSelection.Stage) -> Void) async throws -> PickedMovie {
        if let assetID = load.assetID {
            do {
                return try await PhotoAssetMovieRequest.load(assetIdentifier: assetID,
                    suggestedName: load.name, onStage: onStage)
            } catch let failure as PhotoKitUnresolvable {
                logger.notice("PhotoKit original unavailable: \(failure.reason, privacy: .public) — provider request continues")
                return try await PhotoMovieRequest.load(load.provider, onStage: onStage)
            }
        }
        return try await PhotoMovieRequest.load(load.provider, onStage: onStage)
    }
}

enum PhotoAssetMovieRequest {
    /// Copies the library resource into app-owned staging with PhotoKit's own
    /// file writer. Nothing video-sized is held in memory, and the single
    /// completion callback resolves the wait with the system's own error.
    static func load(assetIdentifier: String,
                                 suggestedName: String?,
                                 onStage: @escaping @MainActor (PhotoMovieSelection.Stage) -> Void) async throws -> PickedMovie {
        // The prompt belongs to the picker entry point (openPhotos), never to
        // a row task: a dialog emerging over a dismissing full-screen picker
        // breaks the presentation. Here the cached status decides — a denied
        // or still-unanswered access falls back to the provider request.
        let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard authorization == .authorized || authorization == .limited else {
            throw PhotoKitUnresolvable(reason: "Photo library access is not granted")
        }
        try Task.checkCancellation()
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: nil).firstObject,
              asset.mediaType == .video else {
            throw PhotoKitUnresolvable(reason: "The selected video is not resolvable in the photo library")
        }
        // Prefer the plain video resource; any movie-conforming representation
        // is acceptable when the plain one is absent.
        let candidates = PHAssetResource.assetResources(for: asset)
            .filter { (UTType($0.uniformTypeIdentifier) ?? UTType.movie).conforms(to: .movie) }
        guard let resource = candidates.first(where: { $0.type == .video }) ?? candidates.first else {
            throw PhotoKitUnresolvable(reason: "This library item has no video resource")
        }
        let directory = PhotoMovieRequest.stagingRoot()
        let ext = UTType(resource.uniformTypeIdentifier)?.preferredFilenameExtension ?? "mov"
        let destination = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        let delivery = PhotoAssetDelivery(destination: destination,
            storedName: resource.originalFilename, suggestedName: suggestedName,
            representation: resource.uniformTypeIdentifier, onStage: onStage)
        // PhotoKit performs the copy and reports once with its own error;
        // the row shows copying from the request's start, the completion
        // resolves the wait.
        Task { @MainActor in onStage(.copying) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // The continuation is parked before the copy starts; the
                // completion handler is the one wire this delivery owns.
                delivery.willWrite(continuation)
                PHAssetResourceManager.default().writeData(
                    for: resource, toFile: destination, options: options,
                    completionHandler: { delivery.complete(with: $0) })
                delivery.registeredTransfer()
            }
        } onCancel: {
            delivery.cancelRequest()
        }
    }
}

/// Owns one PhotoKit file copy: the single continuation resume, the delivery
/// deadline and abandonment on cancellation. PhotoKit writes the staged file
/// itself and calls back once from an arbitrary queue; every mutable state
/// touch is lock-guarded and the continuation resumes only once, after
/// the lock is released.
private final class PhotoAssetDelivery: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.hoangbkit.inkribe",
                                       category: "PhotoAssetMovieRequest")
    // PhotoKit keeps moving only while Photos itself moves; this generous
    // deadline still bounds a fully silent request. Transfers with real byte
    // progress never come close to it, and cancellation is deterministic.
    private static let deliveryLimit: Duration = .seconds(300)

    private static func deliveryDetail(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(error.localizedDescription) (\(nsError.domain)-\(nsError.code))"
    }

    private let lock = NSLock()
    private let destination: URL
    private let storedName: String?
    private let suggestedName: String?
    private let representation: String
    private let onStage: @MainActor (PhotoMovieSelection.Stage) -> Void
    private var continuation: CheckedContinuation<PickedMovie, Error>?
    private var completed = false
    private var cancelRequested = false
    private var deadlineTask: Task<Void, Never>?

    init(destination: URL, storedName: String?, suggestedName: String?, representation: String,
         onStage: @escaping @MainActor (PhotoMovieSelection.Stage) -> Void) {
        self.destination = destination
        self.storedName = storedName
        self.suggestedName = suggestedName
        self.representation = representation
        self.onStage = onStage
    }

    func willWrite(_ continuation: CheckedContinuation<PickedMovie, Error>) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    /// Arms the delivery deadline after the copy is handed to PhotoKit.
    /// writeData carries no request identifier to cancel, so an expired or
    /// cancelled transfer is abandoned here: the staged file is removed and
    /// any in-flight write drains harmlessly into the unlinked path.
    func registeredTransfer() {
        lock.lock()
        let cancelled = cancelRequested
        let alreadyCompleted = completed
        lock.unlock()
        if !cancelled, !alreadyCompleted {
            deadlineTask = Task { [weak self] in
                do { try await Task.sleep(for: Self.deliveryLimit) } catch { return }
                self?.expire()
            }
        }
    }

    func complete(with error: Error?) {
        lock.lock()
        let cancelled = cancelRequested
        lock.unlock()
        if let error {
            conclude(.failure(cancelled ? CancellationError()
                : PhotoMovieRequestError.loading(Self.deliveryDetail(error))))
            return
        }
        let values = try? destination.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true, (values?.fileSize ?? 0) > 0 else {
            conclude(.failure(PhotoMovieRequestError.missingFile))
            return
        }
        if let size = values?.fileSize {
            Self.logger.info(
                "Received \(size, privacy: .public) bytes from \(self.representation, privacy: .public)")
        }
        let identity = [storedName, suggestedName]
            .compactMap { $0 }
            .first { !$0.isEmpty }
        conclude(.success(PickedMovie(localURL: destination,
            displayName: identity ?? "Imported Video", representation: representation)))
    }

    func cancelRequest() {
        lock.lock()
        let alreadyDone = completed
        cancelRequested = true
        lock.unlock()
        guard !alreadyDone else { return }
        conclude(.failure(CancellationError()))
    }

    private func expire() {
        lock.lock()
        let finished = completed
        lock.unlock()
        guard !finished else { return }
        conclude(.failure(PhotoMovieRequestError.timedOut))
    }

    /// Transitions to done exactly once: releases the deadline, removes
    /// partial or abandoned output on failure, then resumes the continuation
    /// outside the lock.
    private func conclude(_ outcome: Result<PickedMovie, Error>) {
        var delivered: CheckedContinuation<PickedMovie, Error>?
        lock.lock()
        if !completed {
            completed = true
            deadlineTask?.cancel()
            deadlineTask = nil
            if case .failure = outcome {
                try? FileManager.default.removeItem(at: destination)
            }
            delivered = continuation
            continuation = nil
        }
        lock.unlock()
        delivered?.resume(with: outcome)
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
