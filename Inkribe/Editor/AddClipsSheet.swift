import AppFoundation
import Foundation
import Observation
import SwiftUI

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
            PhotosVideoPicker { providers in
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
                    SourceThumbnail(source: source, duration: metadata.duration)
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

    private func pendingPhotoRow(_ entry: PhotoMovieSelection, number: Int) -> some View {
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

    private func failedPhotoRow(_ entry: PhotoMovieSelection, number: Int, message: String) -> some View {
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

    private func photoStageTitle(_ stage: PhotoMovieSelection.Stage) -> String {
        switch stage {
        case .waiting: "Waiting…"
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

/// Owned by the editor, independently of the pushed screen and native pickers.
/// Only explicit navigation/dismissal ends a selection; view disappearance does not.
@MainActor @Observable
final class AddClipsModel {
    var photoPicker: PhotoPickerRequest?
    private(set) var selectionID = UUID()
    private(set) var sources: [ImportInput] = []
    /// Registration order of every Photos and Files selection; drives row order.
    private(set) var sourceOrder: [UUID] = []
    /// All Photos selections between receivePhotos and their resolved loading,
    /// copying or failure stage. Success removes the entry.
    private(set) var photoEntries: [UUID: PhotoMovieSelection] = [:]
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
    /// Sequential materialization: parallel provider file requests contend for
    /// the Photos helper and the shared copy path, so even benign attempts
    /// cross the per-attempt watchdogs and get generation-killed mid-transfer.
    /// One video at a time keeps the full attempt budget and a high success
    /// rate; total time stays bounded because each video has its own ladder.
    private let loadWindow = 1
    var busy: Bool { preparingPhotos || adding }

    /// Failed selections keep their provider for Retry, in selection order.
    var photoFailures: [PhotoMovieSelection] {
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
        // No staging can be in flight here; clear anything a crashed session
        // left in the durable staging area.
        PhotoMovieRequest.sweepStaleStaging()
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
        photoPicker = PhotoPickerRequest(selectionID: selectionID)
    }

    func receivePhotos(_ providers: [NSItemProvider], request: PhotoPickerRequest) {
        guard active, selectionID == request.selectionID, photoPicker?.id == request.id else { return }
        // Retain providers in the model before dismissing the native picker.
        let selections = providers.enumerated().map { index, provider in
            PhotoMovieSelection(provider: provider,
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
        startReviews()
    }

    /// Kicked after each successful materialize so a finished row shows its
    /// cover and duration while later selections still load. Safe during photo
    /// preparation: the reviewed list is an immutable snapshot taken here, and
    /// every shared write is MainActor-serialized.
    func reviewSourcesDuringPreparation() {
        guard active else { return }
        startReviews()
    }

    private func startReviews() {
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

    func preparePhotos(_ items: [PhotoMovieSelection], selectionID: UUID) {
        guard active, self.selectionID == selectionID, !busy, !items.isEmpty else { return }
        reviewGeneration = UUID(); reviewTask?.cancel(); reviewTask = nil; reviewing = []
        let token = UUID(); photoGeneration = token
        preparingPhotos = true; error = nil; notice = nil
        // Register every selection first so rows appear immediately, like Files,
        // and cancellation leaves unfinished selections retryable.
        for item in items {
            var entry = photoEntries[item.id] ?? item
            entry.stage = .waiting
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
                // Its turn now: promote the queued rows this chunk will load.
                for item in chunk { photoEntries[item.id]?.stage = .loading }
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
            let file = try await PhotoMovieRequest.load(load.provider) { [self] stage in
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
            // Finish this row's picture immediately; later selections still load.
            reviewSourcesDuringPreparation()
        } catch {
            guard active, photoGeneration == token else { return }
            advancePhotoStage(load.id, .failed(error.localizedDescription))
        }
    }

    private func advancePhotoStage(_ id: UUID, _ stage: PhotoMovieSelection.Stage?) {
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

