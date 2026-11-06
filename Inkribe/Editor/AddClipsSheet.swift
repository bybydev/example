import AppFoundation
import Observation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// Pushed inside Clips. Local selection never changes the project before Add.
/// Preparing files never creates a project or touches the saved document.
struct AddClipsSheet: View {
    @Environment(\.appFoundationTheme) private var theme
    let session: EditorSession
    @Bindable var model: AddClipsModel
    let selectionID: UUID
    let onCancel: () -> Void
    let onAdded: ([UUID]) -> Void
    @State private var pickingFiles = false
    private var ready: Bool { model.isReady && session.canChangeClips }

    var body: some View {
        Form {
            Group { sourcePicker; selectedMedia; status }
                .listRowBackground(theme.surfaceColor).listRowSeparatorTint(theme.borderColor)
        }
        .navigationTitle("Add clips").navigationBarTitleDisplayMode(.inline).themedSurface()
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel).disabled(session.isChangingClips)
            }
            ToolbarItem(placement: .confirmationAction) {
                if !model.sourceOrder.isEmpty {
                    Button(model.sourceOrder.count == 1 ? "Add clip" : "Add \(model.sourceOrder.count) clips") {
                        model.addSelected(to: session, selectionID: selectionID, onAdded: onAdded)
                    }.disabled(model.busy || !ready)
                }
            }
        }
        .interactiveDismissDisabled(session.isChangingClips)
        // PHPicker is built for full-screen presentation on iPhone; presenting it
        // inside a nested page sheet proved unreliable on device.
        .fullScreenCover(item: $model.photoPicker) { request in
            ClipPhotosPicker { providers in
                model.receivePhotos(providers, request: request)
            }
        }
        .fileImporter(isPresented: $pickingFiles, allowedContentTypes: [.movie], allowsMultipleSelection: true) { result in
            model.receiveFiles(result, selectionID: selectionID)
        }
    }

    private var sourcePicker: some View {
        Section {
            Button("Photos", systemImage: "photo.on.rectangle") { model.openPhotos() }.disabled(model.busy)
            Button("Files", systemImage: "folder") { pickingFiles = true }.disabled(model.busy)
        } footer: {
            Text(session.document?.mediaEdits?.trim == nil
                ? "Clips are added to the end of this project. Transcribe them when you’re ready."
                : "Clips are added to the end. Your start trim stays; the end trim expands to include the new clips.")
        }
    }

    /// One merged, ordered list for Photos and Files. Every selection gets a row
    /// immediately, like Files; Photos rows carry their own loading/copying
    /// stage, then the shared media review state.
    @ViewBuilder private var selectedMedia: some View {
        if !model.sourceOrder.isEmpty {
            Section {
                ForEach(Array(model.sourceOrder.enumerated()), id: \.element) { index, id in
                    selectionRow(index: index, id: id)
                }
            } header: { Text("Selected clips · \(model.sourceOrder.count)") }
            footer: {
                Text(model.photoFailures.isEmpty
                    ? "Clips will be added in this order. You can reorder them in Clips after adding."
                    : "Retry or remove these selections before adding clips. Clips are added in this order.")
            }
        }
    }

    @ViewBuilder private func selectionRow(index: Int, id: UUID) -> some View {
        if let source = model.sources.first(where: { $0.id == id }) {
            preparedRow(source, number: index + 1)
        } else if let entry = model.photoEntries[id], case .failed(let message) = entry.stage {
            failedPhotoRow(entry, number: index + 1, message: message)
        } else if let entry = model.photoEntries[id] {
            pendingPhotoRow(entry, number: index + 1)
        }
    }

    private func preparedRow(_ source: ImportInput, number: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                if let metadata = model.reviews[source.id]?.metadata {
                    AddClipThumbnail(source: source, duration: metadata.duration)
                } else { MediaThumbnail(data: nil) }
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(number). \(source.displayName)").lineLimit(2).truncationMode(.middle)
                    if let metadata = model.reviews[source.id]?.metadata {
                        Text(EditorTime.display(metadata.duration)).font(.caption).foregroundStyle(.secondary)
                    } else if model.reviewing.contains(source.id) { ProgressView("Checking media…") }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button("Remove selection", systemImage: "xmark") { model.remove(source) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .frame(width: 44, height: 44).disabled(model.busy)
            }
            if let issue = model.reviews[source.id]?.error {
                Text(issue).font(.footnote).foregroundStyle(.orange)
                Button("Retry media check", action: model.reviewSources).disabled(model.busy)
            }
        }
    }

    private func pendingPhotoRow(_ entry: ClipPhotoSelection, number: Int) -> some View {
        HStack(spacing: 12) {
            MediaThumbnail(data: nil)
            VStack(alignment: .leading, spacing: 5) {
                Text("\(number). \(entry.name)").lineLimit(2).truncationMode(.middle)
                HStack(spacing: 6) {
                    ProgressView()
                    Text(photoStageTitle(entry.stage)).font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button("Remove selection", systemImage: "xmark") { model.removeFailure(entry.id) }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .frame(width: 44, height: 44).disabled(model.busy)
        }
    }

    private func failedPhotoRow(_ entry: ClipPhotoSelection, number: Int, message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                MediaThumbnail(data: nil)
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(number). \(entry.name)").lineLimit(2).truncationMode(.middle)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button("Remove selection", systemImage: "xmark") { model.removeFailure(entry.id) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .frame(width: 44, height: 44).disabled(model.busy)
            }
            Text(message).font(.footnote).foregroundStyle(.orange)
            HStack {
                Button("Retry") { model.preparePhotos([entry], selectionID: selectionID) }
                Button("Remove", role: .destructive) { model.removeFailure(entry.id) }
            }.buttonStyle(.borderless).disabled(model.busy)
        }
    }

    private func photoStageTitle(_ stage: ClipPhotoSelection.Stage) -> String {
        switch stage {
        case .loading: "Loading from Photos…"
        case .retrying: "Retrying Photos access…"
        case .copying: "Copying video…"
        case .failed: ""
        }
    }

    @ViewBuilder private var status: some View {
        if model.busy {
            Section {
                ProgressView(model.adding ? "Copying, checking and adding clips…" : "Loading videos from Photos…")
                Button("Cancel preparation", role: .cancel) { model.cancelPreparation() }.disabled(session.isChangingClips)
            }
        }
        if let error = model.error { Section { Text(error).font(.footnote).foregroundStyle(.orange).textSelection(.enabled) } }
        if let notice = model.notice { Section { Text(notice).font(.footnote).foregroundStyle(.secondary) } }
    }

}

/// Optional artwork has its own view task and never gates Add. Removing a row or
/// leaving the screen cancels its request; a timeout keeps a plain video icon.
private struct AddClipThumbnail: View {
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

/// Owned by the editor, independently of the pushed screen and native pickers.
/// Only explicit navigation/dismissal ends a selection; view disappearance does not.
@MainActor @Observable
final class AddClipsModel {
    var photoPicker: ClipPhotosPickerRequest?
    private(set) var selectionID = UUID()
    private(set) var sources: [ImportInput] = []
    /// Registration order of every Photos and Files selection; drives row order.
    private(set) var sourceOrder: [UUID] = []
    /// All Photos selections between receivePhotos and their resolved loading,
    /// copying or failure stage. Success removes the entry.
    private(set) var photoEntries: [UUID: ClipPhotoSelection] = [:]
    private(set) var reviews: [UUID: ImportSourceReview] = [:]
    private(set) var reviewing: Set<UUID> = []
    private(set) var preparingPhotos = false
    private(set) var adding = false
    private(set) var error: String?
    private(set) var notice: String?
    @ObservationIgnored private var active = false
    @ObservationIgnored private var ownedPhotos: Set<URL> = []
    @ObservationIgnored private var photoTask: Task<Void, Never>?
    @ObservationIgnored private var reviewTask: Task<Void, Never>?
    @ObservationIgnored private var addTask: Task<Void, Never>?
    @ObservationIgnored private var photoGeneration = UUID()
    @ObservationIgnored private var reviewGeneration = UUID()
    @ObservationIgnored private let importer = MediaImporter(repository: .shared)
    @ObservationIgnored private let reviewer = ImportMediaReviewer()
    /// Concurrent provider loads are windowed so many multi-GB originals cannot
    /// surge library reads and storage writes at the same time.
    private let loadWindow = 3
    var busy: Bool { preparingPhotos || adding }

    /// Failed selections keep their provider for Retry, in selection order.
    var photoFailures: [ClipPhotoSelection] {
        let positions = Dictionary(uniqueKeysWithValues: sourceOrder.enumerated().map { ($0.element, $0.offset) })
        return photoEntries.values
            .filter { entry in
                if case .failed = entry.stage { return true }
                return false
            }
            .sorted { positions[$0.id, default: Int.max] < positions[$1.id, default: Int.max] }
    }

    var isReady: Bool {
        active && !busy && !sources.isEmpty && photoFailures.isEmpty && reviewing.isEmpty &&
            sources.allSatisfy { reviews[$0.id]?.metadata != nil && reviews[$0.id]?.kind == .video }
    }

    func beginSelection() {
        endSelection()
        active = true
    }

    func endSelection() {
        active = false; selectionID = UUID()
        photoGeneration = UUID(); reviewGeneration = UUID()
        photoTask?.cancel(); photoTask = nil
        reviewTask?.cancel(); reviewTask = nil
        addTask?.cancel(); addTask = nil
        preparingPhotos = false; adding = false
        photoPicker = nil; sources = []; sourceOrder = []; photoEntries = [:]
        reviews = [:]; reviewing = []
        error = nil; notice = nil
        for url in ownedPhotos { try? FileManager.default.removeItem(at: url) }
        ownedPhotos.removeAll()
    }

    func openPhotos() {
        guard active, !busy, photoPicker == nil else { return }
        photoPicker = ClipPhotosPickerRequest(selectionID: selectionID)
    }

    func receivePhotos(_ providers: [NSItemProvider], request: ClipPhotosPickerRequest) {
        guard active, selectionID == request.selectionID, photoPicker?.id == request.id else { return }
        // Retain providers in the model before dismissing the native picker.
        let selections = providers.enumerated().map { index, provider in
            ClipPhotoSelection(provider: provider,
                name: provider.suggestedName ?? "Selected video \(index + 1)")
        }
        photoPicker = nil
        preparePhotos(selections, selectionID: request.selectionID)
    }

    func receiveFiles(_ result: Result<[URL], Error>, selectionID: UUID) {
        guard active, self.selectionID == selectionID, !busy else { return }
        switch result {
        case .success(let urls):
            let additions = urls.map { ImportInput(localURL: $0, origin: .files) }
            sources += additions; sourceOrder += additions.map(\.id)
            reviewSources()
        case .failure(let failure):
            let value = failure as NSError
            if value.domain != NSCocoaErrorDomain || value.code != NSUserCancelledError { error = failure.localizedDescription }
        }
    }

    func reviewSources() {
        guard active, !busy else { return }
        reviewTask?.cancel()
        let token = UUID(); reviewGeneration = token
        let selected = sources.filter { reviews[$0.id]?.metadata == nil }
        reviewing = Set(selected.map(\.id)); error = nil
        reviewTask = Task {
            defer { if reviewGeneration == token { reviewing = []; reviewTask = nil } }
            for source in selected {
                guard !Task.isCancelled, active, reviewGeneration == token else { return }
                let review = await reviewer.review(source, requireVideo: true, includeThumbnail: false)
                guard !Task.isCancelled, active, reviewGeneration == token else { return }
                reviews[source.id] = review; reviewing.remove(source.id)
            }
        }
    }

    func preparePhotos(_ items: [ClipPhotoSelection], selectionID: UUID) {
        guard active, self.selectionID == selectionID, !busy, !items.isEmpty else { return }
        reviewGeneration = UUID(); reviewTask?.cancel(); reviewTask = nil; reviewing = []
        let token = UUID(); photoGeneration = token
        preparingPhotos = true; error = nil; notice = nil
        // Register every selection first so rows appear immediately, like Files,
        // and cancellation leaves unfinished selections retryable.
        for item in items {
            var entry = photoEntries[item.id] ?? item
            entry.stage = .loading
            photoEntries[item.id] = entry
            if !sourceOrder.contains(item.id) { sourceOrder.append(item.id) }
        }
        photoTask = Task {
            defer {
                if photoGeneration == token {
                    preparingPhotos = false; photoTask = nil
                    // A finished batch cannot leave a loading/copying row behind;
                    // finalize any leftover deterministically as retryable.
                    let leftoverIDs = photoEntries.filter { !$0.value.isFailed }.map(\.key)
                    for id in leftoverIDs {
                        photoEntries[id]?.stage = .failed("Loading did not finish. Retry or remove this video.")
                    }
                    reviewSources()
                }
            }
            var index = 0
            while index < items.count {
                guard !Task.isCancelled, active, photoGeneration == token else { return }
                let chunk = Array(items[index..<min(index + loadWindow, items.count)])
                await withTaskGroup(of: Void.self) { group in
                    for item in chunk {
                        // Strict Sendability bounds: only this Sendable box crosses
                        // into the child task; the provider itself stays there.
                        let load = PhotoLoad(provider: item.provider, id: item.id, name: item.name)
                        group.addTask { await self.materialize(load, token: token) }
                    }
                }
                index += chunk.count
            }
        }
    }

    private func materialize(_ load: PhotoLoad, token: UUID) async {
        guard active, !Task.isCancelled, photoGeneration == token else { return }
        do {
            let file = try await ClipPhotoFileRequest.load(load.provider) { [self] stage in
                guard self.active, self.photoGeneration == token else { return }
                self.advancePhotoStage(load.id, stage)
            }
            guard !Task.isCancelled, active, photoGeneration == token else {
                try? FileManager.default.removeItem(at: file.localURL)
                return
            }
            ownedPhotos.insert(file.localURL)
            sources.append(ImportInput(id: load.id, localURL: file.localURL, origin: .photos, displayName: file.displayName))
            photoEntries[load.id] = nil
            let positions = Dictionary(uniqueKeysWithValues: sourceOrder.enumerated().map { ($0.element, $0.offset) })
            sources.sort { positions[$0.id, default: Int.max] < positions[$1.id, default: Int.max] }
        } catch {
            guard active, photoGeneration == token else { return }
            advancePhotoStage(load.id, .failed(error.localizedDescription))
        }
    }

    private func advancePhotoStage(_ id: UUID, _ stage: ClipPhotoSelection.Stage?) {
        guard var entry = photoEntries[id] else { return }
        if let stage { entry.stage = stage; photoEntries[id] = entry } else { photoEntries[id] = nil }
    }

    func cancelPreparation() {
        guard active else { return }
        if adding { addTask?.cancel(); return }
        guard preparingPhotos else { return }
        photoGeneration = UUID()
        photoTask?.cancel(); photoTask = nil
        preparingPhotos = false
        for id in Array(photoEntries.keys) {
            advancePhotoStage(id, .failed("Preparation cancelled. Retry or remove this video."))
        }
        notice = "Preparation cancelled. Your prepared selections are kept."
        reviewSources()
    }

    func removeFailure(_ id: UUID) {
        guard active, !busy else { return }
        photoEntries[id] = nil
        sourceOrder.removeAll { $0 == id }
    }

    func remove(_ source: ImportInput) {
        guard active, !busy else { return }
        sources.removeAll { $0.id == source.id }; reviews[source.id] = nil
        sourceOrder.removeAll { $0 == source.id }
        if ownedPhotos.remove(source.localURL) != nil { try? FileManager.default.removeItem(at: source.localURL) }
        reviewSources()
    }

    func addSelected(to session: EditorSession, selectionID: UUID, onAdded: @escaping ([UUID]) -> Void) {
        guard self.selectionID == selectionID, isReady, session.canChangeClips else { return }
        let selected = sources
        adding = true; error = nil; notice = nil
        addTask = Task {
            defer { if self.selectionID == selectionID { adding = false; addTask = nil } }
            var staged: PreparedClipImport?
            do {
                let prepared = try await importer.prepareClips(selected, requireVideo: true); staged = prepared
                try Task.checkCancellation()
                guard active, self.selectionID == selectionID else { throw CancellationError() }
                let ids = try await session.appendClips(prepared)
                // Publication is complete. A closed selection must not navigate a new one.
                if active, self.selectionID == selectionID { onAdded(ids) }
            } catch is CancellationError {
                if active, self.selectionID == selectionID { notice = "Adding clips cancelled. Your selections are kept." }
            } catch {
                if active, self.selectionID == selectionID { self.error = error.localizedDescription }
            }
            if let staged { try? await ProjectRepository.shared.discardStaging(staged.staging) }
        }
    }
}

struct ClipPhotosPickerRequest: Identifiable {
    let id = UUID()
    let selectionID: UUID
}

struct ClipPhotoSelection: Identifiable {
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
private struct PhotoLoad: @unchecked Sendable {
    let provider: NSItemProvider
    let id: UUID
    let name: String
}

/// Get the native file providers directly, without a PhotosPickerItem/Transferable
/// conversion. No full photo-library permission or PHAsset lookup is needed.
@MainActor
private struct ClipPhotosPicker: UIViewControllerRepresentable {
    let onSelection: ([NSItemProvider]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelection: onSelection) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .videos
        configuration.selectionLimit = 0
        configuration.selection = .ordered
        // .current can stall waiting for the absolute original (downloads,
        // exotic encodings). .automatic lets the system substitute a complete,
        // compatible representation when the current one cannot be delivered.
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
private final class ClipPhotoFileRequest {
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
    private var onStage: (@MainActor (ClipPhotoSelection.Stage) -> Void)?
    private var result: Result<PickedMovie, Error>?
    private var deliveredURL: URL?

    static func load(_ provider: NSItemProvider,
                     onStage: @escaping @MainActor (ClipPhotoSelection.Stage) -> Void) async throws -> PickedMovie {
        let request = ClipPhotoFileRequest()
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
                       onStage: @escaping @MainActor (ClipPhotoSelection.Stage) -> Void,
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
                self.finish(.failure(ClipPhotoFileError.missingFile))
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
            finish(.failure(lastError ?? ClipPhotoFileError.noResponse))
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
        case .fileRepresentation:
            progress = provider?.loadFileRepresentation(forTypeIdentifier: type) { [weak self] url, error in
                if let url, error == nil {
                    Task { @MainActor in self?.reportCopying(generation: generation) }
                    // Stay inside the callback for this synchronous owned copy.
                    let copied = Self.copyFile(url, error: nil, suggestedName: suggestedName, type: type)
                    Task { @MainActor in
                        guard let self else {
                            if case .success(let file) = copied {
                                try? FileManager.default.removeItem(at: file.localURL)
                            }
                            return
                        }
                        self.deliver(copied, generation: generation)
                    }
                } else {
                    let message = error?.localizedDescription
                    Task { @MainActor in self?.attemptFailed(generation: generation, message: message) }
                }
            }
        case .item:
            // loadItem returns no progress handle and cannot be cancelled; its
            // late completion is rejected by the attempt generation and any
            // copied file is removed.
            provider?.loadItem(forTypeIdentifier: type, options: nil) { [weak self] item, error in
                if item is URL {
                    Task { @MainActor in self?.reportCopying(generation: generation) }
                }
                // Copy synchronously before returning; the acquired item expires too.
                let copied = Self.copyItem(item, error: error, suggestedName: suggestedName, type: type)
                Task { @MainActor in
                    guard let self else {
                        if case .success(let file) = copied {
                            try? FileManager.default.removeItem(at: file.localURL)
                        }
                        return
                    }
                    self.deliver(copied, generation: generation)
                }
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
            self?.finish(.failure(ClipPhotoFileError.timedOut), cancelProvider: true)
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
        lastError = message.map(ClipPhotoFileError.loading) ?? ClipPhotoFileError.noResponse
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
        if let error { return .failure(ClipPhotoFileError.loading(error.localizedDescription)) }
        guard let url, url.isFileURL else { return .failure(ClipPhotoFileError.missingFile) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("InkribePhotoTransfers", isDirectory: true)
        let ext = url.pathExtension.isEmpty ? (UTType(type)?.preferredFilenameExtension ?? "mov") : url.pathExtension
        let copy = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: copy)
            let values = try copy.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
                throw ClipPhotoFileError.missingFile
            }
            let name: String
            if let suggestedName, !suggestedName.isEmpty { name = suggestedName }
            else { name = url.lastPathComponent }
            return .success(PickedMovie(localURL: copy, displayName: name.isEmpty ? "Imported Video" : name))
        } catch {
            try? FileManager.default.removeItem(at: copy)
            return .failure(ClipPhotoFileError.copying(error.localizedDescription))
        }
    }

    /// Last-resort acquisition when the file representation itself is rejected.
    /// The acquired item is only usable synchronously inside this callback.
    nonisolated private static func copyItem(_ item: Any?, error: Error?, suggestedName: String?,
                                             type: String) -> Result<PickedMovie, Error> {
        if let error { return .failure(ClipPhotoFileError.loading(error.localizedDescription)) }
        guard let url = item as? URL, url.isFileURL else { return .failure(ClipPhotoFileError.missingFile) }
        return copyFile(url, error: nil, suggestedName: suggestedName, type: type)
    }
}

private enum ClipPhotoFileError: LocalizedError {
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
