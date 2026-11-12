import AppFoundation
import Foundation
import Observation
import Photos
import SwiftUI

/// Inline clip-add rows for the editor Clips sheet. Local selection never
/// changes the project before the auto-append pipeline commits each clip;
/// a clip is saved as soon as its media is copied, inspected and appended.
struct AddClipsRows: View {
    let session: EditorSession
    let model: AddClipsModel
    let onPhotos: () -> Void
    let onFiles: () -> Void

    @ViewBuilder var body: some View {
        if !model.sourceOrder.isEmpty {
            ForEach(Array(model.sourceOrder.enumerated()), id: \.element) { index, id in
                selectionRow(index: index, id: id)
            }
        }
        addClipsRow
        if let error = model.error {
            Text(error).font(.footnote).foregroundStyle(.orange).textSelection(.enabled)
        }
    }

    private var addClipsRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Add clips", systemImage: "plus")
            HStack(spacing: 10) {
                Button("Photos", systemImage: "photo.on.rectangle") { onPhotos() }
                    .buttonStyle(.bordered)
                Button("Files", systemImage: "folder") { onFiles() }
                    .buttonStyle(.bordered)
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 4)
        .disabled(model.busy || !session.canChangeClips)
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
        let review = model.reviews[source.id]
        let appendError = model.appendErrors[source.id]
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                if let metadata = review?.metadata {
                    SourceThumbnail(source: source, duration: metadata.duration)
                } else { MediaThumbnail(data: nil) }
                VStack(alignment: .leading, spacing: 5) {
                    Text("New · \(number). \(source.displayName)")
                        .lineLimit(2).truncationMode(.middle)
                    if let metadata = review?.metadata {
                        Text(EditorTime.display(metadata.duration))
                            .font(.caption).foregroundStyle(.secondary)
                    } else if model.reviewing.contains(source.id) {
                        ProgressView("Checking media…").font(.caption)
                    }
                    if model.appendingSourceID == source.id {
                        ProgressView("Adding clip…").font(.caption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Remove selection", systemImage: "xmark") { model.removePending(source.id) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .frame(width: 44, height: 44).disabled(model.busy)
            }
            if let issue = review?.error {
                Text(issue).font(.footnote).foregroundStyle(.orange)
                Button("Retry media check") { model.reviewSources() }.disabled(model.busy)
            }
            if let appendError {
                Text(appendError).font(.footnote).foregroundStyle(.orange)
                Button("Retry adding clip") { model.retryAppend(source) }
                    .disabled(model.busy || !session.canChangeClips)
            }
        }
        .contextMenu { pendingActions(source.id) }
    }

    private func pendingPhotoRow(_ entry: PhotoMovieSelection, number: Int) -> some View {
        HStack(spacing: 12) {
            MediaThumbnail(data: nil)
            VStack(alignment: .leading, spacing: 5) {
                Text("New · \(number). \(entry.name)").lineLimit(2).truncationMode(.middle)
                HStack(spacing: 6) {
                    ProgressView()
                    Text(photoStageTitle(entry.stage)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Remove selection", systemImage: "xmark") { model.removePending(entry.id) }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .frame(width: 44, height: 44).disabled(model.busy)
        }
        .contextMenu { pendingActions(entry.id) }
    }

    private func failedPhotoRow(_ entry: PhotoMovieSelection, number: Int, message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                MediaThumbnail(data: nil)
                VStack(alignment: .leading, spacing: 5) {
                    Text("New · \(number). \(entry.name)").lineLimit(2).truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Remove selection", systemImage: "xmark") { model.removePending(entry.id) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .frame(width: 44, height: 44).disabled(model.busy)
            }
            Text(message).font(.footnote).foregroundStyle(.orange)
            HStack {
                Button("Retry") { model.preparePhotos([entry], selectionID: model.selectionID) }
                Button("Remove", role: .destructive) { model.removePending(entry.id) }
            }
            .buttonStyle(.borderless).disabled(model.busy)
        }
        .contextMenu { pendingActions(entry.id) }
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

    @ViewBuilder private func pendingActions(_ id: UUID) -> some View {
        let position = model.sourceOrder.firstIndex(of: id) ?? 0
        Button("Move earlier", systemImage: "arrow.up") { model.moveSelection(id, offset: -1) }
            .disabled(position == 0 || model.busy)
        Button("Move later", systemImage: "arrow.down") { model.moveSelection(id, offset: 1) }
            .disabled(position + 1 >= model.sourceOrder.count || model.busy)
        Divider()
        Button("Remove selection", systemImage: "trash", role: .destructive) { model.removePending(id) }
            .disabled(model.busy)
    }
}

/// Owned by the editor, independently of the sheet. A successfully prepared
/// source is appended and saved automatically, in selection order. Only
/// unfinished or failed selections remain local to this model.
@MainActor @Observable
final class AddClipsModel {
    var photoPicker: PhotoPickerRequest?
    private(set) var selectionID = UUID()
    private(set) var sources: [ImportInput] = []
    /// Registration order of every Photos and Files selection; drives row order
    /// and the order in which clips are saved.
    private(set) var sourceOrder: [UUID] = []
    /// All Photos selections between receivePhotos and their resolved loading,
    /// copying or failure stage. Success removes the entry.
    private(set) var photoEntries: [UUID: PhotoMovieSelection] = [:]
    private(set) var reviews: [UUID: ImportSourceReview] = [:]
    private(set) var reviewing: Set<UUID> = []
    private(set) var preparingPhotos = false
    private(set) var adding = false
    private(set) var appendingSourceID: UUID?
    private(set) var appendErrors: [UUID: String] = [:]
    private(set) var lastAddedClipID: UUID?
    private(set) var error: String?
    @ObservationIgnored private weak var session: EditorSession?
    @ObservationIgnored private var active = false
    @ObservationIgnored private var ownedPhotos: Set<URL> = []
    @ObservationIgnored private var photoTask: Task<Void, Never>?
    @ObservationIgnored private var reviewTask: Task<Void, Never>?
    @ObservationIgnored private var appendTask: Task<Void, Never>?
    @ObservationIgnored private var photoGeneration = UUID()
    @ObservationIgnored private var reviewGeneration = UUID()
    @ObservationIgnored private let importer = MediaImporter(repository: .shared)
    @ObservationIgnored private let reviewer = ImportMediaReviewer()
    private(set) var remainingCapacity = ProjectLimits.maximumClips
    /// Photos transfers are sequential on purpose: parallel provider requests
    /// contend for the Photos helper and the shared copy path.
    private let loadWindow = 1
    var busy: Bool { preparingPhotos || adding }
    /// Recomputed from the live document so clips that finish saving while a
    /// picker is open cannot let the next selection exceed the project limit.
    private var availableClipSlots: Int {
        if let count = session?.document?.clips.count {
            return max(0, ProjectLimits.maximumClips - count - sourceOrder.count)
        }
        return max(0, remainingCapacity - sourceOrder.count)
    }

    /// True while any selection is still being copied, checked or saved.
    /// Terminal failures do not count: closing discards them.
    var hasUnfinishedImports: Bool {
        guard active else { return false }
        if preparingPhotos || adding || appendingSourceID != nil || !reviewing.isEmpty { return true }
        if photoEntries.values.contains(where: { !$0.isFailed }) { return true }
        return sources.contains { source in
            appendErrors[source.id] == nil && reviews[source.id]?.error == nil
        }
    }

    var pendingFailureCount: Int {
        photoEntries.values.filter { $0.isFailed }.count +
            sources.filter { reviews[$0.id]?.error != nil || appendErrors[$0.id] != nil }.count
    }

    func beginSelection(session: EditorSession, remainingCapacity: Int = ProjectLimits.maximumClips) {
        endSelection()
        self.session = session
        self.remainingCapacity = max(0, remainingCapacity)
        // No staging can be in flight here; clear anything a crashed session
        // left in the durable staging area.
        PhotoMovieRequest.sweepStaleStaging()
        active = true
    }

    /// Starts a fresh selection when idle, or just refreshes capacity while
    /// rows are already pending.
    func prepareSelection(session: EditorSession, remainingCapacity: Int) {
        self.session = session
        let capacity = max(0, remainingCapacity)
        if active {
            self.remainingCapacity = capacity
        } else {
            beginSelection(session: session, remainingCapacity: capacity)
        }
    }

    func endSelection() {
        active = false; selectionID = UUID()
        photoGeneration = UUID(); reviewGeneration = UUID()
        photoTask?.cancel(); photoTask = nil
        reviewTask?.cancel(); reviewTask = nil
        appendTask?.cancel(); appendTask = nil
        preparingPhotos = false; adding = false; appendingSourceID = nil
        photoPicker = nil; sources = []; sourceOrder = []; photoEntries = [:]
        reviews = [:]; reviewing = []; appendErrors = [:]; lastAddedClipID = nil
        error = nil
        for url in ownedPhotos { try? FileManager.default.removeItem(at: url) }
        ownedPhotos.removeAll()
        session = nil
    }

    func openPhotos() {
        guard active, !busy, photoPicker == nil else { return }
        guard availableClipSlots > 0 else {
            error = "A project can include up to \(ProjectLimits.maximumClips) clips."
            return
        }
        // Ask for library access while nothing is presented: the system dialog
        // cannot reliably come up over a dismissing full-screen picker, and the
        // loader reads the cached status afterwards.
        Task { _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        photoPicker = PhotoPickerRequest(selectionID: selectionID, selectionLimit: availableClipSlots)
    }

    func receivePhotos(_ picks: [PhotoPick], request: PhotoPickerRequest) {
        guard active, selectionID == request.selectionID, photoPicker?.id == request.id else { return }
        let accepted = Array(picks.prefix(availableClipSlots))
        let overflowed = accepted.count < picks.count
        // Retain providers in the model before dismissing the native picker.
        let selections = accepted.enumerated().map { index, pick in
            PhotoMovieSelection(provider: pick.provider, assetID: pick.assetID,
                name: pick.provider.suggestedName ?? "Selected video \(index + 1)")
        }
        photoPicker = nil
        guard !selections.isEmpty else {
            if overflowed { error = "A project can include up to \(ProjectLimits.maximumClips) clips." }
            return
        }
        preparePhotos(selections, selectionID: request.selectionID)
        if overflowed { error = "A project can include up to \(ProjectLimits.maximumClips) clips." }
    }

    func receiveFiles(_ result: Result<[URL], Error>, selectionID: UUID) {
        guard active, self.selectionID == selectionID else { return }
        switch result {
        case .success(let urls):
            let accepted = Array(urls.prefix(availableClipSlots))
            let overflowed = accepted.count < urls.count
            guard !accepted.isEmpty else {
                if overflowed { error = "A project can include up to \(ProjectLimits.maximumClips) clips." }
                return
            }
            let additions = accepted.map { ImportInput(localURL: $0, origin: .files) }
            sources += additions; sourceOrder += additions.map(\.id)
            reviewSources()
            if overflowed { error = "A project can include up to \(ProjectLimits.maximumClips) clips." }
        case .failure(let failure):
            let value = failure as NSError
            if value.domain != NSCocoaErrorDomain || value.code != NSUserCancelledError {
                error = failure.localizedDescription
            }
        }
    }

    func reviewSources() {
        guard active else { return }
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
                if review.error == nil { scheduleAutoAppend() }
            }
        }
        // Also unblocks a ready row when an earlier failed selection was just
        // removed or moved; there may be no new review to kick the pipeline.
        scheduleAutoAppend()
    }

    func preparePhotos(_ items: [PhotoMovieSelection], selectionID: UUID) {
        guard active, self.selectionID == selectionID, !preparingPhotos, !items.isEmpty else { return }
        reviewGeneration = UUID(); reviewTask?.cancel(); reviewTask = nil; reviewing = []
        let token = UUID(); photoGeneration = token
        preparingPhotos = true; error = nil
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
                        let load = PhotoLoad(provider: item.provider, id: item.id,
                            name: item.name, assetID: item.assetID)
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
            let file = try await PhotoMovieLoader.load(load) { [self] stage in
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

    func removeFailure(_ id: UUID) {
        guard active, !busy else { return }
        photoEntries[id] = nil
        sourceOrder.removeAll { $0 == id }
        appendErrors[id] = nil
        scheduleAutoAppend()
    }

    func remove(_ source: ImportInput) {
        guard active, !busy else { return }
        sources.removeAll { $0.id == source.id }; reviews[source.id] = nil
        appendErrors[source.id] = nil
        sourceOrder.removeAll { $0 == source.id }
        if ownedPhotos.remove(source.localURL) != nil { try? FileManager.default.removeItem(at: source.localURL) }
        reviewSources()
    }

    func removePending(_ id: UUID) {
        if let source = sources.first(where: { $0.id == id }) { remove(source) }
        else { removeFailure(id) }
    }

    func moveSelection(_ id: UUID, offset: Int) {
        guard active, !busy, let index = sourceOrder.firstIndex(of: id) else { return }
        let target = index + offset
        guard sourceOrder.indices.contains(target) else { return }
        sourceOrder.swapAt(index, target)
        let positions = Dictionary(uniqueKeysWithValues: sourceOrder.enumerated().map { ($0.element, $0.offset) })
        sources.sort { positions[$0.id, default: Int.max] < positions[$1.id, default: Int.max] }
        scheduleAutoAppend()
    }

    func retryAppend(_ source: ImportInput) {
        guard active, !busy, session?.canChangeClips == true,
              reviews[source.id]?.metadata != nil,
              reviews[source.id]?.error == nil,
              reviews[source.id]?.kind == .video else { return }
        appendErrors[source.id] = nil
        error = nil
        scheduleAutoAppend()
    }

    /// Retried when the session becomes editable again after a competing edit.
    func resumeAutoAppend() {
        guard active else { return }
        scheduleAutoAppend()
    }

    /// Appends the next ready source in strict selection order. A photo still
    /// loading or a failed row deliberately holds later selections back so the
    /// saved clip order matches the order shown in the sheet.
    private func scheduleAutoAppend() {
        guard active, appendTask == nil, appendingSourceID == nil,
              let session, session.canChangeClips else { return }
        guard nextSourceToAppend() != nil else { return }
        let token = selectionID
        adding = true
        appendTask = Task {
            await drainAutoAppend(selectionID: token)
        }
    }

    private func nextSourceToAppend() -> ImportInput? {
        guard let firstID = sourceOrder.first else { return nil }
        guard photoEntries[firstID] == nil,
              let source = sources.first(where: { $0.id == firstID }),
              appendErrors[firstID] == nil,
              reviews[firstID]?.error == nil,
              reviews[firstID]?.metadata != nil,
              reviews[firstID]?.kind == .video else { return nil }
        return source
    }

    private func drainAutoAppend(selectionID token: UUID) async {
        defer {
            if selectionID == token {
                adding = false; appendTask = nil; appendingSourceID = nil
            }
        }
        while active, selectionID == token, session != nil, !Task.isCancelled {
            guard let next = nextSourceToAppend() else { break }
            await append(next, selectionID: token)
        }
    }

    private func append(_ source: ImportInput, selectionID token: UUID) async {
        guard active, selectionID == token, let session else { return }
        appendingSourceID = source.id
        appendErrors[source.id] = nil
        var staged: PreparedClipImport?
        do {
            let prepared = try await importer.prepareClips([source], requireVideo: true)
            staged = prepared
            try Task.checkCancellation()
            guard active, selectionID == token else { throw CancellationError() }
            let ids = try await session.appendClips(prepared)
            if active, selectionID == token {
                sources.removeAll { $0.id == source.id }
                sourceOrder.removeAll { $0 == source.id }
                reviews[source.id] = nil
                appendErrors[source.id] = nil
                lastAddedClipID = ids.first
            }
            if ownedPhotos.remove(source.localURL) != nil {
                try? FileManager.default.removeItem(at: source.localURL)
            }
        } catch is CancellationError {
            // The selection ended or the user canceled; committed clips stay.
            // A cancellation that did not end the selection must not let the
            // drain loop retry the same source forever.
            if active, selectionID == token {
                appendErrors[source.id] = "Adding this clip was cancelled. Retry or remove it."
            }
        } catch {
            if active, selectionID == token {
                appendErrors[source.id] = error.localizedDescription
            }
        }
        if let staged { try? await ProjectRepository.shared.discardStaging(staged.staging) }
        if selectionID == token { appendingSourceID = nil }
    }
}
