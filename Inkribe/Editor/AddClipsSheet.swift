import AppFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Local picker/review state, independent from Home's New Project importer.
/// Preparing files never creates a project or touches the saved document.
struct AddClipsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appFoundationTheme) private var theme
    let session: EditorSession
    let onAdded: ([UUID]) -> Void
    @State private var photos: [PhotosPickerItem] = []
    @State private var pickingPhotos = false
    @State private var pickingFiles = false
    @State private var sourceOrder: [UUID] = []
    @State private var sources: [ImportInput] = []
    @State private var ownedPhotos: Set<URL> = []
    @State private var photoFailures: [PhotoPreparationFailure] = []
    @State private var reviews: [UUID: ImportSourceReview] = [:]
    @State private var reviewing: Set<UUID> = []
    @State private var preparingPhotos = false
    @State private var adding = false
    @State private var task: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var urlText = ""
    @State private var rightsConfirmed = false
    @State private var error: String?
    @State private var notice: String?
    private let importer = MediaImporter(repository: .shared)
    private let reviewer = ImportMediaReviewer()
    private var busy: Bool { preparingPhotos || adding }
    private var ready: Bool {
        !sources.isEmpty && photoFailures.isEmpty && reviewing.isEmpty &&
            sources.allSatisfy { reviews[$0.id]?.metadata != nil } && session.canChangeClips
    }

    var body: some View {
        NavigationStack {
            Form {
                Group { sourcePicker; selectedMedia; failures; directURL; status }
                    .listRowBackground(theme.surfaceColor).listRowSeparatorTint(theme.borderColor)
            }
            .navigationTitle("Add clips").navigationBarTitleDisplayMode(.inline).themedSurface()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { task?.cancel(); dismiss() }.disabled(session.isChangingClips)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if !sources.isEmpty { Button("Add") { addSelected() }.disabled(busy || !ready) }
                }
            }
            .interactiveDismissDisabled(session.isChangingClips)
            .onChange(of: photos) { _, items in
                guard !items.isEmpty else { return }
                photos = []
                preparePhotos(items.map { PhotoPreparationFailure(id: UUID(), item: $0,
                    name: "Selected video", message: "") })
            }
            .fileImporter(isPresented: $pickingFiles, allowedContentTypes: [.movie, .audio], allowsMultipleSelection: true) { result in
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
            .photosPicker(isPresented: $pickingPhotos, selection: $photos, maxSelectionCount: 0,
                selectionBehavior: .ordered, matching: .videos)
            .onDisappear {
                guard !pickingFiles, !pickingPhotos else { return }
                task?.cancel(); generation = UUID(); cleanupPhotos()
            }
        }
    }

    private var sourcePicker: some View {
        Section {
            Button("Photos", systemImage: "photo.on.rectangle") { pickingPhotos = true }.disabled(busy)
            Button("Files", systemImage: "folder") { pickingFiles = true }.disabled(busy)
        } footer: {
            Text(session.document?.mediaEdits?.trim == nil
                ? "Clips are added to the end of this project. Transcribe them when you’re ready."
                : "Clips are added to the end. Your start trim stays; the end trim expands to include the new clips.")
        }
    }

    @ViewBuilder private var selectedMedia: some View {
        if !sources.isEmpty {
            Section("Selected clips · \(sources.count)") {
                ForEach(sources) { source in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            MediaThumbnail(data: reviews[source.id]?.thumbnail, audio: reviews[source.id]?.kind == .audio)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(source.displayName).lineLimit(2).truncationMode(.middle)
                                if let metadata = reviews[source.id]?.metadata {
                                    Text(EditorTime.display(metadata.duration)).font(.caption).foregroundStyle(.secondary)
                                } else if reviewing.contains(source.id) { ProgressView("Checking media…") }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Button("Remove selection", systemImage: "xmark") { remove(source) }
                                .labelStyle(.iconOnly).frame(width: 44, height: 44).disabled(busy)
                        }
                        if let issue = reviews[source.id]?.error {
                            Text(issue).font(.footnote).foregroundStyle(.orange)
                            Button("Retry media check", action: reviewSources).disabled(busy)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var failures: some View {
        if !photoFailures.isEmpty && !preparingPhotos {
            Section("Videos not prepared") {
                ForEach(photoFailures) { failure in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(failure.name)
                        Text(failure.message).font(.footnote).foregroundStyle(.secondary)
                        HStack {
                            Button("Retry") { preparePhotos([failure]) }
                            Button("Remove", role: .destructive) {
                                photoFailures.removeAll { $0.id == failure.id }; sourceOrder.removeAll { $0 == failure.id }
                            }
                        }.buttonStyle(.borderless).disabled(busy)
                    }
                }
                Text("Retry or remove these selections before adding clips.").font(.footnote)
            }
        }
    }

    @ViewBuilder private var directURL: some View {
        if sources.isEmpty && photoFailures.isEmpty {
            Section {
                DisclosureGroup("Import a direct media URL") {
                    TextField("https://example.com/video.mp4", text: $urlText)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    Toggle("I have the rights to import this media", isOn: $rightsConfirmed)
                    Button("Add clip from URL") { addURL() }
                        .disabled(busy || !rightsConfirmed || urlText.isEmpty || !session.canChangeClips)
                }.disabled(busy)
            } footer: { Text("Direct downloadable HTTPS media only.") }
        }
    }

    @ViewBuilder private var status: some View {
        if busy {
            Section {
                ProgressView(adding ? "Copying, checking and adding clips…" : "Preparing videos from Photos…")
                Button("Cancel preparation", role: .cancel) { task?.cancel() }.disabled(session.isChangingClips)
            }
        }
        if let error { Section { Text(error).font(.footnote).foregroundStyle(.orange).textSelection(.enabled) } }
        if let notice { Section { Text(notice).font(.footnote).foregroundStyle(.secondary) } }
    }

    private func reviewSources() {
        task?.cancel()
        let token = UUID(); generation = token
        let selected = sources
        reviewing = Set(selected.map(\.id)); error = nil
        task = Task {
            for source in selected {
                let review = await reviewer.review(source)
                guard !Task.isCancelled, generation == token else { return }
                reviews[source.id] = review; reviewing.remove(source.id)
            }
        }
    }

    private func preparePhotos(_ items: [PhotoPreparationFailure]) {
        guard !busy else { return }
        task?.cancel()
        let token = UUID(); generation = token
        preparingPhotos = true; reviewing = []; error = nil
        for item in items where !sourceOrder.contains(item.id) { sourceOrder.append(item.id) }
        task = Task {
            for entry in items {
                guard !Task.isCancelled, generation == token else { break }
                do {
                    guard let file = try await entry.item.loadTransferable(type: PickedMovie.self) else { throw ProjectStoreError.unsupportedMedia }
                    guard !Task.isCancelled, generation == token else {
                        try? FileManager.default.removeItem(at: file.localURL)
                        break
                    }
                    ownedPhotos.insert(file.localURL)
                    sources.append(ImportInput(id: entry.id, localURL: file.localURL, origin: .photos, displayName: file.displayName))
                    photoFailures.removeAll { $0.id == entry.id }
                } catch {
                    guard generation == token else { return }
                    photoFailures.removeAll { $0.id == entry.id }
                    photoFailures.append(PhotoPreparationFailure(id: entry.id, item: entry.item,
                        name: entry.name, message: Task.isCancelled ? "Preparation cancelled. Retry or remove this video." : error.localizedDescription))
                }
            }
            guard generation == token else { return }
            let stopped = Task.isCancelled
            if stopped {
                for item in items where !sources.contains(where: { $0.id == item.id }) && !photoFailures.contains(where: { $0.id == item.id }) {
                    photoFailures.append(PhotoPreparationFailure(id: item.id, item: item.item, name: item.name,
                        message: "Preparation cancelled. Retry or remove this video."))
                }
                notice = "Preparation cancelled. Your prepared selections are kept."
            }
            let positions = Dictionary(uniqueKeysWithValues: sourceOrder.enumerated().map { ($0.element, $0.offset) })
            sources.sort { positions[$0.id, default: 0] < positions[$1.id, default: 0] }
            preparingPhotos = false
            reviewSources()
        }
    }

    private func remove(_ source: ImportInput) {
        sources.removeAll { $0.id == source.id }; reviews[source.id] = nil
        sourceOrder.removeAll { $0 == source.id }
        if ownedPhotos.remove(source.localURL) != nil { try? FileManager.default.removeItem(at: source.localURL) }
        reviewSources()
    }

    private func addSelected() {
        guard ready, !busy else { return }
        let selected = sources
        beginAdding { try await importer.prepareClips(selected) }
    }
    private func addURL() {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", url.host?.isEmpty == false,
              url.user == nil, url.password == nil else { error = "Enter a valid HTTPS media URL."; return }
        beginAdding { try await importer.prepareDirectURL(url, rightsConfirmed: rightsConfirmed) }
    }
    private func beginAdding(_ prepare: @escaping @MainActor () async throws -> PreparedClipImport) {
        guard !busy, session.canChangeClips else { return }
        task?.cancel(); generation = UUID(); adding = true; error = nil; notice = nil
        task = Task {
            defer { adding = false }
            var staged: PreparedClipImport?
            do {
                let prepared = try await prepare(); staged = prepared
                try Task.checkCancellation()
                let ids = try await session.appendClips(prepared)
                onAdded(ids); dismiss()
            } catch is CancellationError { notice = "Adding clips cancelled. Your selections are kept." }
            catch { self.error = error.localizedDescription }
            if let staged { try? await ProjectRepository.shared.discardStaging(staged.staging) }
        }
    }
    private func cleanupPhotos() {
        for url in ownedPhotos { try? FileManager.default.removeItem(at: url) }
        ownedPhotos.removeAll()
    }
}
