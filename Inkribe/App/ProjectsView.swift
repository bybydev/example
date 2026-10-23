import JobQueue
import AppFoundation
import SwiftUI

/// P1's normal app root. The empty-library invitation appears only when no
/// projects exist; it is not a repeated onboarding interstitial.
struct ProjectsView: View {
    @Environment(ProjectsModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appFoundationTheme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showingImport = false
    @State private var proFlow: ProFlow?
    @State private var proFlowStartedWithoutEntitlement = false
    @State private var showingExport = false
    @State private var attemptedThumbnails: Set<UUID> = []
    @State private var path: [ProjectsRoute] = []
    @State private var importedProjectIDs: [UUID] = []
    @State private var importNoticeCount = 0
    @State private var renameTarget: ProjectSummary?
    @State private var renamedTitle = ""
    @State private var showingRename = false
    @State private var trashTarget: ProjectSummary?
    @State private var showingTrash = false

    // Separate opaque expressions keep library layout and presentation within
    // Swift's type-checking budget without moving parent-owned UI state.
    var body: some View {
        NavigationStack(path: $path) { libraryLifecycle }
        .sheet(item: $proFlow, onDismiss: handleProFlowDismissal) { flow in
            switch flow {
            case .paywall: ProPaywall()
            case .celebration: ProCelebration()
            }
        }
    }

    private var libraryLifecycle: some View {
        libraryDialogs
        .onChange(of: model.cacheGeneration) { _, _ in attemptedThumbnails.removeAll() }
        .onChange(of: model.transcription.resultGeneration) { _, _ in Task { await model.refreshLibrary() } }
        .onChange(of: path) { _, value in
            if value.isEmpty { Task { await model.refreshLibrary() } }
        }
        .task {
            model.transcription.setForeground(scenePhase == .active)
            model.transcription.start()
            model.exports.setForeground(scenePhase == .active)
            await model.exports.start()
            await model.refresh()
        }
        .sheet(isPresented: $showingExport) { ExportView(session: nil) }
        .onChange(of: scenePhase) { _, value in
            model.transcription.setForeground(value == .active)
            model.exports.setForeground(value == .active)
            if value == .active { Task { await model.refresh() } }
            if value == .active { Task { await model.transcription.refreshAllowance() } }
        }
        .refreshable { await model.refresh() }
    }

    private var libraryDialogs: some View {
        libraryNavigation
        .sheet(isPresented: $showingImport, onDismiss: finishImportNavigation) {
            ImportView(onImported: { importedProjectIDs = $0 })
                .environment(model)
        }
        .alert("Rename project", isPresented: $showingRename, presenting: renameTarget) { project in
            TextField("Project title", text: $renamedTitle)
            Button("Save") {
                let title = renamedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                Task {
                    do { try await model.rename(project, to: title) }
                    catch { model.alertMessage = error.localizedDescription }
                }
            }
            .disabled(renamedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || renamedTitle.count > 256)
            Button("Cancel", role: .cancel) { }
        } message: { _ in Text("Enter a name up to 256 characters.") }
        .confirmationDialog("Move project to Trash?", isPresented: $showingTrash, presenting: trashTarget) { project in
            Button("Move to Trash", role: .destructive) { Task { await model.trash(project.id) } }
        } message: { project in Text("\(project.title) can be restored from Storage until you empty Trash.") }
        .alert("Inkribe", isPresented: Binding(
            get: { canPresentLibraryError && model.alertMessage != nil },
            set: { if !$0 && canPresentLibraryError { model.alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
    }

    private var libraryNavigation: some View {
        @Bindable var binding = model
        return libraryScroll
        .navigationTitle("Inkribe")
        .themedSurface()
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $binding.search,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search project titles")
        .toolbar { libraryToolbar }
        .navigationDestination(for: ProjectsRoute.self) { route in
            switch route {
            case .project(let id): ProjectDetailView(projectID: id, access: model.access)
            case .settings: SettingsView(onShowPro: { presentProStatus() })
            }
        }
    }

    private var libraryScroll: some View {
        let projects = model.projects
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                importSummary
                libraryHeader(count: projects.count)
                filterBar
                if projects.isEmpty { emptyLibrary }
                else { projectGrid(projects) }
                libraryIssues
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    @ViewBuilder
    private var importSummary: some View {
        if importNoticeCount > 0 {
            HStack {
                Label("\(importNoticeCount) projects added", systemImage: "checkmark.circle.fill")
                Spacer()
                Button("Dismiss", systemImage: "xmark") { importNoticeCount = 0 }
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .font(.subheadline)
        }
        if model.exports.record != nil || model.exports.persistenceError != nil {
            Button("Current export", systemImage: "tray.and.arrow.up") { showingExport = true }
                .font(.subheadline)
        }
        if model.isPreparingPhotos {
            ProgressView("Preparing media…")
        }
    }

    private func libraryHeader(count: Int) -> some View {
        @Bindable var binding = model
        return HStack {
            Text("Projects").font(.title3.bold())
            Text("\(count)").foregroundStyle(.secondary)
            Spacer()
            Menu {
                Picker("Sort projects", selection: $binding.sort) {
                    Text("Recently updated").tag(LibrarySort.recent)
                    Text("Oldest updated").tag(LibrarySort.oldest)
                    Text("Title").tag(LibrarySort.title)
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
                    .frame(minHeight: 44)
            }
        }
    }

    @ViewBuilder
    private var emptyLibrary: some View {
        if model.isLoading && model.allProjects.isEmpty {
            ProgressView("Loading projects…")
                .frame(maxWidth: .infinity, minHeight: 180)
        } else if !model.isFiltering && model.libraryIssues.isEmpty {
            ContentUnavailableView {
                Label("Your next video starts here", systemImage: "film.stack")
            } description: {
                Text("Import a video or audio file to create your first project.")
            } actions: {
                Button("Add media", systemImage: "plus") { beginImport() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.vertical, 24)
        } else {
            ContentUnavailableView {
                Label(model.isFiltering ? "No matching projects" : "Projects need attention", systemImage: "folder.badge.questionmark")
            } description: {
                Text(model.isFiltering ? "Try another title or clear your filters." : "Review the issues below or refresh the library.")
            } actions: {
                if model.isFiltering {
                    Button("Clear search and filters") { model.clearLibraryFilters() }
                } else {
                    Button("Refresh") { Task { await model.refreshLibrary() } }
                }
            }
        }
    }

    private func projectGrid(_ projects: [ProjectSummary]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 280 : 155), spacing: 14, alignment: .top)], spacing: 14) {
            ForEach(projects) { project in
                projectCard(project)
            }
        }
    }

    private func projectCard(_ project: ProjectSummary) -> some View {
        NavigationLink(value: ProjectsRoute.project(project.id)) {
            ProjectCard(project: project, status: projectStatus(project), cacheGeneration: model.cacheGeneration)
        }
        .buttonStyle(.plain)
        .disabled(model.mutatingProjectIDs.contains(project.id))
        .overlay(alignment: .topTrailing) {
            Menu { projectActions(project) } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 44, height: 44)
                    .background(.regularMaterial, in: Circle())
            }
            .accessibilityLabel("Actions for " + project.title)
            .padding(16)
        }
        .contextMenu { projectActions(project) }
        .task(id: "\(project.id.uuidString)-\(model.cacheGeneration)") {
            guard project.thumbnailURL == nil, project.mediaKind == .video,
                  project.available, attemptedThumbnails.insert(project.id).inserted else { return }
            await model.regenerateThumbnail(project.id)
        }
    }

    @ViewBuilder
    private var libraryIssues: some View {
        if !model.libraryIssues.isEmpty && !model.isFiltering {
            VStack(alignment: .leading, spacing: 10) {
                Label("Projects needing attention", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                ForEach(model.libraryIssues) { issue in
                    VStack(alignment: .leading, spacing: 4) {
                        if let project = model.allProjects.first(where: { $0.id == issue.id }) {
                            NavigationLink(project.title, value: ProjectsRoute.project(project.id))
                        }
                        Text(issue.description).font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        if path.isEmpty {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink(value: ProjectsRoute.settings) {
                    Label("Settings", systemImage: "gearshape")
                }
                .accessibilityIdentifier("toolbar.settings")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    presentProStatus()
                } label: {
                    Label("Inkribe Pro", systemImage: model.access.hasPro ? "crown.fill" : "crown")
                }
                .accessibilityIdentifier("toolbar.pro")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add", systemImage: "plus") { beginImport() }
                    .disabled(model.isImporting || model.isPreparingPhotos)
            }
        }
    }

    // Sheets and pushed editors own their errors; the hidden grid must not
    // compete with them for the shared model's alert presentation.
    private var canPresentLibraryError: Bool {
        path.isEmpty && !showingImport && !showingExport && proFlow == nil
    }

    private func presentProStatus() {
        proFlowStartedWithoutEntitlement = !model.access.hasPro
        proFlow = model.access.hasPro ? .celebration : .paywall
    }

    private func handleProFlowDismissal() {
        let shouldCelebrate = proFlowStartedWithoutEntitlement && model.access.hasPro
        proFlowStartedWithoutEntitlement = false
        guard shouldCelebrate else { return }

        // Wait until the paywall has dismissed before presenting the celebration.
        Task { @MainActor in
            await Task.yield()
            guard proFlow == nil, model.access.hasPro else { return }
            proFlow = .celebration
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                filterButton("All", .all)
                filterButton("Video", .video)
                filterButton("Audio", .audio)
                filterButton("Missing media", .missingMedia)
            }
        }
        .scrollIndicators(.hidden)
        .accessibilityLabel("Project filters")
    }

    private func filterButton(_ title: String, _ filter: LibraryFilter) -> some View {
        Button { model.filter = filter } label: {
            Text(title)
                .font(.subheadline.weight(model.filter == filter ? .semibold : .regular))
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(model.filter == filter ? theme.accentColor.opacity(0.20) : theme.surfaceColor, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(model.filter == filter ? .isSelected : [])
    }

    @ViewBuilder
    private func projectActions(_ project: ProjectSummary) -> some View {
        let busy = model.mutatingProjectIDs.contains(project.id)
        Button("Rename", systemImage: "pencil") {
            renameTarget = project; renamedTitle = project.title; showingRename = true
        }
        .disabled(busy || !project.available || model.transcription.isActive(project.id))
        Button("Duplicate", systemImage: "plus.square.on.square") { Task { await model.duplicate(project.id) } }
            .disabled(busy || !project.available)
        Button("Move to Trash", systemImage: "trash", role: .destructive) {
            trashTarget = project; showingTrash = true
        }
        .disabled(busy || model.transcription.isActive(project.id) || model.transcription.persistenceError != nil)
    }

    private func projectStatus(_ project: ProjectSummary) -> ProjectCardStatus {
        if !project.available { return .init(title: "Missing media", icon: "exclamationmark.triangle", needsAttention: true) }
        if model.mutatingProjectIDs.contains(project.id) { return .init(title: "Updating project…", icon: "clock", isWorking: true) }
        let speech = model.transcription
        let record = speech.record(for: project.id)
        if let record, !record.status.isTerminal {
            let paused = speech.queue?.isPaused == true
            let title = paused ? "Transcription paused" : record.status == .pending ? "Queued" :
                record.status == .cancelling ? "Cancelling…" : speech.queue?.liveProgress[record.id]?.message ?? "Transcribing…"
            let fraction = speech.queue?.liveProgress[record.id]?.fractionCompleted
            let working = !paused && record.status != .pending
            return .init(title: title, icon: paused ? "pause.circle" : "waveform",
                progress: working ? fraction.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil } : nil, isWorking: working)
        }
        switch project.captionState {
        case .incomplete: return .init(title: "Captions available · Incomplete", icon: "captions.bubble", needsAttention: true)
        case .saved: return .init(title: "Captions saved", icon: "captions.bubble.fill")
        case .emptyResult: return .init(title: "Retry transcription", icon: "arrow.clockwise", needsAttention: true)
        case .noAudio: return .init(title: "No audio track", icon: "speaker.slash")
        case .needsTranscription:
            if speech.persistenceError != nil {
                return .init(title: "Transcription unavailable", icon: "exclamationmark.triangle", needsAttention: true)
            }
            if let record, record.status.isRetryable || record.status == .unrecoverable {
                return .init(title: record.status == .cancelled ? "Transcription cancelled" : "Transcription needs retry",
                    icon: "arrow.clockwise", needsAttention: true)
            }
            return .init(title: "Needs captions", icon: "captions.bubble")
        }
    }

    private func beginImport() {
        guard !model.isImporting, !model.isPreparingPhotos else { return }
        model.prepareImport()
        importedProjectIDs = []
        showingImport = true
    }

    private func finishImportNavigation() {
        let ids = importedProjectIDs
        importedProjectIDs = []
        guard !ids.isEmpty else { return }
        model.clearLibraryFilters()
        model.sort = .recent
        if ids.count == 1 {
            path.append(.project(ids[0]))
        } else {
            importNoticeCount = ids.count
        }
    }
}

private enum ProFlow: String, Identifiable {
    case paywall, celebration
    var id: String { rawValue }
}

private enum ProjectsRoute: Hashable {
    case project(UUID)
    case settings
}

