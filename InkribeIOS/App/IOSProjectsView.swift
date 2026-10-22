import AVKit
import CoreMedia
import UIKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// P1's normal app root. The empty-library invitation appears only when no
/// projects exist; it is not a repeated onboarding interstitial.
struct IOSProjectsView: View {
    @Environment(IOSProjectsModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingImport = false
    @State private var showingStorage = false
    @State private var attemptedThumbnails: Set<UUID> = []

    var body: some View {
        @Bindable var binding = model
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Text("Your projects")
                            .font(.title3.bold())
                        Spacer()
                        Menu {
                            Button("Recently updated", systemImage: "clock") { changeSort(.recent) }
                            Button("Oldest updated", systemImage: "calendar") { changeSort(.oldest) }
                            Button("Title", systemImage: "textformat.abc") { changeSort(.title) }
                        } label: {
                            Label("Sort", systemImage: "arrow.up.arrow.down")
                        }
                    }
                    filterBar

                    if model.projects.isEmpty {
                        if model.isLoading {
                            ProgressView("Loading projects…")
                                .frame(maxWidth: .infinity, minHeight: 180)
                        } else if model.search.isEmpty && model.filter == .all && model.libraryIssues.isEmpty {
                            ContentUnavailableView {
                                Label("Your next video starts here", systemImage: "film.stack")
                            } description: {
                                Text("Import a video or audio file to create your first project.")
                            } actions: {
                                Button("Add media", systemImage: "plus") { showingImport = true }
                                    .buttonStyle(.borderedProminent)
                            }
                            .padding(.vertical, 24)
                        } else {
                            ContentUnavailableView.search(text: model.search)
                        }
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 14)],
                                  spacing: 14) {
                            ForEach(model.projects) { project in
                                NavigationLink(value: project.id) {
                                    projectCard(project)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if !model.libraryIssues.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Projects needing attention", systemImage: "exclamationmark.triangle")
                                .font(.headline)
                            ForEach(model.libraryIssues) { issue in
                                Text(issue.description)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(16)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .navigationTitle("Inkribe")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $binding.search,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search project titles")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Storage", systemImage: "internaldrive") { showingStorage = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add", systemImage: "plus") { showingImport = true }
                        .tint(.indigo)
                }
            }
            .navigationDestination(for: UUID.self) { id in
                IOSProjectDetailView(projectID: id)
            }
            .sheet(isPresented: $showingImport) {
                IOSImportView()
                    .environment(model)
            }
            .sheet(isPresented: $showingStorage) {
                IOSStorageView()
                    .environment(model)
            }
            .alert("Inkribe", isPresented: Binding(
                get: { model.alertMessage != nil },
                set: { if !$0 { model.alertMessage = nil } }
            )) {
                Button("OK", role: .cancel) { model.alertMessage = nil }
            } message: {
                Text(model.alertMessage ?? "")
            }
            .onChange(of: model.cacheGeneration) { _, _ in attemptedThumbnails.removeAll() }
            .onChange(of: model.search) { _, _ in Task { await model.refresh() } }
            .onChange(of: model.filter) { _, _ in Task { await model.refresh() } }
            .task { await model.refresh() }
            .onChange(of: scenePhase) { _, value in
                if value == .active { Task { await model.refresh() } }
            }
            .refreshable { await model.refresh() }

        }
    }

    private var filterBar: some View {
        @Bindable var binding = model
        return Picker("Filter", selection: $binding.filter) {
            Text("All").tag(IOSLibraryFilter.all)
            Text("Video").tag(IOSLibraryFilter.video)
            Text("Audio").tag(IOSLibraryFilter.audio)
            Text("Missing media").tag(IOSLibraryFilter.missingMedia)
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Project filter")
    }

    private func projectCard(_ project: IOSProjectSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.indigo.opacity(0.25))
                if let url = project.thumbnailURL,
                   let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(height: 130)
                        .clipped()
                } else {
                    Image(systemName: project.mediaKind == .audio ? "waveform" : "film")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(.secondary)
                }
                if !project.available {
                    Label("Missing", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.bold())
                        .padding(6)
                        .background(.regularMaterial, in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(8)
                }
            }
            .frame(height: 130)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .task(id: "\(project.id.uuidString)-\(model.cacheGeneration)") {
                guard project.thumbnailURL == nil, project.mediaKind == .video,
                      project.available, attemptedThumbnails.insert(project.id).inserted else { return }
                await model.regenerateThumbnail(project.id)
            }
            Text(project.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .foregroundStyle(.primary)
            HStack(spacing: 4) {
                Text(formattedDuration(project.duration))
                Text("·")
                Text(project.updatedAt, style: .date)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    private func formattedDuration(_ time: MediaTime) -> String {
        let seconds = CMTimeGetSeconds(time.cmTime)
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let value = Int(seconds)
        return String(format: "%d:%02d", value / 60, value % 60)
    }

    private func changeSort(_ value: IOSLibrarySort) {
        model.sort = value
        Task { await model.refresh() }
    }
}

/// A real, offline-reopenable P1 media document viewer. Editor commands,
/// caption timeline and transcription deliberately wait for P2/P3.
struct IOSProjectDetailView: View {
    @Environment(IOSProjectsModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let projectID: UUID

    @State private var document: IOSProjectDocument?
    @State private var originalAvailable: [UUID: Bool] = [:]
    @State private var title = ""
    @State private var player: AVPlayer?
    @State private var currentMediaURL: URL?
    @State private var saveTask: Task<Void, Never>?
    @State private var isSavingTitle = false
    @State private var relinkAsset: UUID?
    @State private var isRelinking = false
    @State private var showDeleteConfirmation = false
    @State private var loadError: String?

    var body: some View {
        ScrollView {
            if let document {
                VStack(alignment: .leading, spacing: 18) {
                    if let player {
                        VideoPlayer(player: player)
                            .frame(maxWidth: .infinity)
                            .frame(height: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    } else {
                        ContentUnavailableView(
                            "Preview unavailable",
                            systemImage: "film",
                            description: Text("The original media may be missing or unsupported.")
                        )
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Project name").font(.caption).foregroundStyle(.secondary)
                        TextField("Project title", text: $title)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Project title, saved automatically")
                            .onSubmit { saveTask?.cancel(); Task { await saveTitle() } }
                            .onChange(of: title) { _, newValue in
                                guard newValue != document.title else { return }
                                saveTask?.cancel()
                                saveTask = Task {
                                    try? await Task.sleep(for: .milliseconds(650))
                                    guard !Task.isCancelled else { return }
                                    await saveTitle()
                                }
                            }
                    }

                    HStack {
                        Label("\(document.clips.count) clips", systemImage: "film.stack")
                        Spacer()
                        Text("\(document.canvas.width) × \(document.canvas.height)")
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)

                    Text("Original media").font(.headline)
                    ForEach(document.assets) { asset in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Image(systemName: asset.kind == .video ? "film" : "waveform")
                                Text(asset.displayName).lineLimit(2)
                                Spacer(minLength: 8)
                                if originalAvailable[asset.id] == false {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                }
                            }
                            .font(.subheadline.weight(.medium))
                            Text(mediaDetails(asset))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if originalAvailable[asset.id] == false {
                                Text("Original not found. Select the exact original file to restore it.")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                Button("Find original…", systemImage: "folder") {
                                    relinkAsset = asset.id
                                    isRelinking = true
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(16)
            } else if let loadError {
                ContentUnavailableView("Cannot open project",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(loadError))
                    .padding(20)
            } else {
                ProgressView("Opening project…").padding(32)
            }
        }
        .navigationTitle(document?.title ?? "Project")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Duplicate project", systemImage: "plus.square.on.square") {
                        Task { await model.duplicate(projectID) }
                    }
                    Button("Move to Trash", systemImage: "trash", role: .destructive) {
                        showDeleteConfirmation = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("Move this project to Trash?", isPresented: $showDeleteConfirmation) {
            Button("Move to Trash", role: .destructive) {
                Task { await model.trash(projectID); dismiss() }
            }
        } message: {
            Text("Original files are preserved in Trash until you empty it.")
        }
        .fileImporter(isPresented: $isRelinking, allowedContentTypes: [.movie, .audio]) { result in
            switch result {
            case .success(let url):
                guard let relinkAsset else { return }
                Task {
                    await model.relink(projectID: projectID, assetID: relinkAsset, from: url)
                    await load()
                }
            case .failure(let error):
                model.alertMessage = error.localizedDescription
            }
        }
        .task(id: projectID) { await load() }
        .onDisappear {
            player?.pause()
            saveTask?.cancel()
            Task { await saveTitle() }
        }
    }

    private func load() async {
        loadError = nil
        let draftAtStart = title
        let mayReplaceDraft = document == nil || title == document?.title
        do {
            let loaded = try await model.repository.open(projectID)
            // A relink refresh may overlap an autosave or more typing. Accept
            // newer committed metadata without replacing an unsaved draft.
            if loaded.contentRevision >= (document?.contentRevision ?? 0) {
                document = loaded
                if mayReplaceDraft, title == draftAtStart, !isSavingTitle {
                    title = loaded.title
                }
            }
            var availability: [UUID: Bool] = [:]
            var firstURL: URL?
            for asset in loaded.assets {
                let url = try? await model.repository.sourceURL(
                    projectID: projectID, assetID: asset.id
                )
                availability[asset.id] = url != nil
                if firstURL == nil { firstURL = url }
            }
            originalAvailable = availability
            if currentMediaURL != firstURL {
                player?.pause()
                currentMediaURL = firstURL
                player = firstURL.map { AVPlayer(url: $0) }
            }
        } catch {
            loadError = error.localizedDescription
            model.alertMessage = error.localizedDescription
        }
    }

    private func saveTitle() async {
        // Debounce, submit and dismissal can overlap. A single writer drains
        // the latest draft, using each returned revision for the next write.
        guard !isSavingTitle else { return }
        isSavingTitle = true
        var didSave = false
        defer {
            isSavingTitle = false
            if didSave { Task { await model.refresh() } }
        }
        while let current = document {
            let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value != current.title else { return }
            do {
                let saved = try await model.rename(current, to: value)
                if let displayed = document,
                   displayed.id == saved.id,
                   displayed.contentRevision <= saved.contentRevision {
                    document = saved
                }
                didSave = true
                // Never assign to title or reload after a save. If the user
                // typed during the await, the loop commits that newer draft.
                // Once writing starts, cancelling the debounce must not drop it.
            } catch {
                model.alertMessage = error.localizedDescription
                return // Preserve the draft and report a conflict/write failure.
            }
        }
    }

    private func mediaDetails(_ asset: IOSSourceAsset) -> String {
        let duration = CMTimeGetSeconds(asset.metadata.duration.cmTime)
        let dimensions = asset.kind == .video
            ? "\(asset.metadata.displayedWidth) × \(asset.metadata.displayedHeight) • " : ""
        let frameRate = asset.metadata.nominalFrameRate.map {
            String(format: " • %.2f fps", $0)
        } ?? ""
        return dimensions + String(format: "%.1f s", duration)
            + frameRate + " • \(asset.metadata.audioTrackCount) audio tracks"
    }
}
