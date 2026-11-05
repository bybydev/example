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
            Group { sourcePicker; selectedMedia; failures; status }
                .listRowBackground(theme.surfaceColor).listRowSeparatorTint(theme.borderColor)
        }
        .navigationTitle("Add clips").navigationBarTitleDisplayMode(.inline).themedSurface()
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel).disabled(session.isChangingClips)
            }
            ToolbarItem(placement: .confirmationAction) {
                if !model.sources.isEmpty { Button(model.sources.count == 1 ? "Add clip" : "Add \(model.sources.count) clips") { model.addSelected(to: session, selectionID: selectionID, onAdded: onAdded) }.disabled(model.busy || !ready) }
            }
        }
        .interactiveDismissDisabled(session.isChangingClips)
        .sheet(item: $model.photoPicker) { request in
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

    @ViewBuilder private var selectedMedia: some View {
        if !model.sources.isEmpty {
            Section {
                ForEach(Array(model.sources.enumerated()), id: \.element.id) { index, source in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            if let metadata = model.reviews[source.id]?.metadata {
                                AddClipThumbnail(source: source, duration: metadata.duration)
                            } else { MediaThumbnail(data: nil) }
                            VStack(alignment: .leading, spacing: 5) {
                                Text("\(index + 1). \(source.displayName)").lineLimit(2).truncationMode(.middle)
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
            } header: { Text("Selected clips · \(model.sources.count)") }
            footer: { Text("Clips will be added in this order. You can reorder them in Clips after adding.") }
        }
    }

    @ViewBuilder private var failures: some View {
        if !model.photoFailures.isEmpty && !model.preparingPhotos {
            Section("Videos not prepared") {
                ForEach(model.photoFailures) { failure in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(failure.name)
                        Text(failure.message).font(.footnote).foregroundStyle(.secondary)
                        HStack {
                            Button("Retry") { model.preparePhotos([failure], selectionID: selectionID) }
                            Button("Remove", role: .destructive) {
                                model.removeFailure(failure.id)
                            }
                        }.buttonStyle(.borderless).disabled(model.busy)
                    }
                }
                Text("Retry or remove these selections before adding clips.").font(.footnote)
            }
        }
    }

    @ViewBuilder private var status: some View {
        if model.busy {
            Section {
                ProgressView(model.adding ? "Copying, checking and adding clips…" : model.photoPreparationMessage)
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
    private(set) var photoPreparationMessage = "Loading videos from Photos…"
    private(set) var selectionID = UUID()
    private(set) var sources: [ImportInput] = []
    private(set) var photoFailures: [ClipPhotoSelection] = []
    private(set) var reviews: [UUID: ImportSourceReview] = [:]
    private(set) var reviewing: Set<UUID> = []
    private(set) var preparingPhotos = false
    private(set) var adding = false
    private(set) var error: String?
    private(set) var notice: String?
    @ObservationIgnored private var active = false
    @ObservationIgnored private var sourceOrder: [UUID] = []
    @ObservationIgnored private var ownedPhotos: Set<URL> = []
    @ObservationIgnored private var photoTask: Task<Void, Never>?
    @ObservationIgnored private var reviewTask: Task<Void, Never>?
    @ObservationIgnored private var addTask: Task<Void, Never>?
    @ObservationIgnored private var photoGeneration = UUID()
    @ObservationIgnored private var reviewGeneration = UUID()
    @ObservationIgnored private let importer = MediaImporter(repository: .shared)
    @ObservationIgnored private let reviewer = ImportMediaReviewer()
    var busy: Bool { preparingPhotos || adding }
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
        photoPicker = nil; sources = []; photoFailures = []; reviews = [:]; reviewing = []
        sourceOrder = []; error = nil; notice = nil
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
        // Register every item first so cancellation leaves unfinished selections retryable.
        for item in items {
            if !sourceOrder.contains(item.id) { sourceOrder.append(item.id) }
            if !photoFailures.contains(where: { $0.id == item.id }) { photoFailures.append(item) }
        }
        photoTask = Task {
            defer {
                if photoGeneration == token {
                    preparingPhotos = false; photoTask = nil
                    reviewSources()
                }
            }
            for (index, entry) in items.enumerated() {
                guard !Task.isCancelled, active, photoGeneration == token else { return }
                photoPreparationMessage = "Loading video \(index + 1) of \(items.count) from Photos…"
                do {
                    let file = try await ClipPhotoFileRequest.load(entry.provider) {
                        guard self.active, self.photoGeneration == token else { return }
                        self.photoPreparationMessage = "Copying video \(index + 1) of \(items.count)…"
                    }
                    guard !Task.isCancelled, active, photoGeneration == token else {
                        try? FileManager.default.removeItem(at: file.localURL)
                        return
                    }
                    ownedPhotos.insert(file.localURL)
                    sources.append(ImportInput(id: entry.id, localURL: file.localURL, origin: .photos, displayName: file.displayName))
                    photoFailures.removeAll { $0.id == entry.id }
                    let positions = Dictionary(uniqueKeysWithValues: sourceOrder.enumerated().map { ($0.element, $0.offset) })
                    sources.sort { positions[$0.id, default: Int.max] < positions[$1.id, default: Int.max] }
                } catch {
                    guard active, photoGeneration == token else { return }
                    if let index = photoFailures.firstIndex(where: { $0.id == entry.id }) {
                        photoFailures[index].message = error.localizedDescription
                    }
                }
            }
        }
    }

    func cancelPreparation() {
        guard active else { return }
        if adding { addTask?.cancel(); return }
        guard preparingPhotos else { return }
        photoGeneration = UUID()
        photoTask?.cancel(); photoTask = nil
        preparingPhotos = false
        for index in photoFailures.indices {
            photoFailures[index].message = "Preparation cancelled. Retry or remove this video."
        }
        notice = "Preparation cancelled. Your prepared selections are kept."
        reviewSources()
    }

    func removeFailure(_ id: UUID) {
        guard active, !busy else { return }
        photoFailures.removeAll { $0.id == id }; sourceOrder.removeAll { $0 == id }
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
    var message = "Not prepared yet"
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
        configuration.preferredAssetRepresentationMode = .current
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
@MainActor
private final class ClipPhotoFileRequest {
    private var provider: NSItemProvider?
    private var continuation: CheckedContinuation<PickedMovie, Error>?
    private var progress: Progress?
    private var deadline: Task<Void, Never>?
    private var result: Result<PickedMovie, Error>?
    private var deliveredURL: URL?

    static func load(_ provider: NSItemProvider, onCopying: @escaping @MainActor () -> Void) async throws -> PickedMovie {
        let request = ClipPhotoFileRequest()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                request.start(provider, onCopying: onCopying, continuation: continuation)
            }
        } onCancel: {
            Task { @MainActor in request.finish(.failure(CancellationError()), cancelProvider: true) }
        }
    }

    private func start(_ provider: NSItemProvider, onCopying: @escaping @MainActor () -> Void,
                       continuation: CheckedContinuation<PickedMovie, Error>) {
        if let result { continuation.resume(with: result); return }
        self.continuation = continuation
        self.provider = provider
        guard provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) else {
            finish(.failure(ProjectStoreError.unsupportedMedia)); return
        }
        let type = provider.registeredTypeIdentifiers.first {
            UTType($0)?.conforms(to: .movie) == true
        } ?? UTType.movie.identifier
        let name = provider.suggestedName
        progress = provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
            if url != nil, error == nil {
                Task { @MainActor in if self.result == nil { onCopying() } }
            }
            // Do not hop to an actor/task before this synchronous owned copy.
            let result = Self.copyFile(url, error: error, suggestedName: name, type: type)
            Task { @MainActor in self.finish(result) }
        }
        deadline = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(120))
                self?.finish(.failure(ClipPhotoFileError.timedOut), cancelProvider: true)
            } catch { }
        }
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
        let continuation = self.continuation; self.continuation = nil
        deadline?.cancel(); deadline = nil
        let progress = self.progress; self.progress = nil
        provider = nil
        if cancelProvider { progress?.cancel() }
        continuation?.resume(with: result)
    }

    nonisolated private static func copyFile(_ url: URL?, error: Error?, suggestedName: String?,
                                             type: String) -> Result<PickedMovie, Error> {
        if let error { return .failure(ClipPhotoFileError.loading(error.localizedDescription)) }
        guard let url else { return .failure(ClipPhotoFileError.missingFile) }
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
}

private enum ClipPhotoFileError: LocalizedError {
    case loading(String), copying(String), missingFile, timedOut

    var errorDescription: String? {
        switch self {
        case .loading(let detail): "Couldn’t load this video from Photos. \(detail)"
        case .copying(let detail): "Couldn’t copy this video into Inkribe. \(detail)"
        case .missingFile: "Photos did not provide a readable video file."
        case .timedOut: "Photos did not finish providing this video within two minutes. Retry when the video is available on your iPhone."
        }
    }
}
