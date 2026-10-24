import AppFoundation
import JobQueue
import SwiftUI

/// One native root stack and one root sheet owner. Library/hero/activity scroll.
struct ProjectsView: View {
    @Environment(ProjectsModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appFoundationTheme) private var theme
    @State private var sheet: LibrarySheet?
    @State private var proStartedWithoutEntitlement = false
    @State private var attemptedThumbnails: Set<UUID> = []
    @State private var path: [ProjectsRoute] = []
    @State private var importedProjectIDs: [UUID] = []
    @State private var importPresented = false
    @State private var importNoticeCount = 0
    @State private var renameTarget: ProjectSummary?
    @State private var renamedTitle = ""
    @State private var showingRename = false
    @State private var trashTarget: ProjectSummary?
    @State private var showingTrash = false
    @State private var searchPresented = false
    private var searching: Bool { searchPresented || !model.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack(path: $path) { libraryLifecycle }
            .sheet(item: $sheet, onDismiss: finishPresentation) { destination in
                switch destination {
                case .newProject: ImportView(onImported: { importedProjectIDs = $0 })
                case .paywall: ProPaywall()
                case .celebration: ProCelebration()
                case .storage: StorageView()
                case .models: SpeechModelsView()
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
                model.processing.setForeground(scenePhase == .active)
                await model.processing.start()
                await model.refresh()
            }
            .onChange(of: scenePhase) { _, value in
                model.processing.setForeground(value == .active)
                if value == .active {
                    Task { await model.refresh(); await model.transcription.refreshAllowance() }
                } else {
                    Task { await model.editors.flushAll() }
                }
            }
            .refreshable { await model.refresh(); await model.exports.refreshArtifacts() }
    }

    private var libraryDialogs: some View {
        libraryNavigation
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
            } message: { Text(model.alertMessage ?? "") }
    }

    private var libraryNavigation: some View {
        @Bindable var binding = model
        return libraryScroll
            .navigationTitle("Inkribe")
            .themedSurface()
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $binding.search, isPresented: $searchPresented,
                        placement: .navigationBarDrawer(displayMode: .always), prompt: "Search projects")
            .toolbar { libraryToolbar }
            .navigationDestination(for: ProjectsRoute.self) { route in
                switch route {
                case .project(let id): ProjectEditorDestination(projectID: id)
                case .renameProject(let id): ProjectEditorDestination(projectID: id, renameOnOpen: true)
                case .settings: SettingsView(onShowPro: presentProStatus)
                case .queue: ProcessingQueueView()
                }
            }
    }

    private var libraryScroll: some View {
        let projects = model.projects
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                if !searching {
                    ProjectCreationHero(isEmpty: model.allProjects.isEmpty && model.libraryError == nil,
                        isBusy: model.isImporting || model.isPreparingPhotos, create: beginImport)
                    importSummary
                    saveActivity
                    queueActivity
                    if !model.transcription.modelAvailable && !model.transcription.models.isLoading {
                        Button { present(.models) } label: {
                            StudioActivityLabel(title: "Speech model needed",
                                detail: SpeechModelCatalog.downloadsEnabled ? "Choose a model to create captions on this device." : "Review the models included in this build.",
                                icon: "cpu")
                        }
                        .buttonStyle(.plain)
                    }
                }
                libraryHeader(count: projects.count)
                if !searching { filterBar }
                else if model.filter != .all {
                    Button("Clear project filters", systemImage: "line.3.horizontal.decrease.circle") { model.filter = .all }
                        .font(.subheadline).frame(minHeight: 44)
                }
                if projects.isEmpty { emptyLibrary }
                else { projectList(projects) }
                libraryIssues
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder private var importSummary: some View {
        if importNoticeCount > 0 {
            HStack {
                Label("\(importNoticeCount) projects added", systemImage: "checkmark.circle.fill").font(.subheadline)
                Spacer(minLength: 8)
                Button("Dismiss import notice", systemImage: "xmark") { importNoticeCount = 0 }
                    .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
            }
            .studioCard()
        }
        if model.isPreparingPhotos { ProgressView("Preparing videos from Photos…").studioCard() }
        if let issue = model.recoveryIssue {
            VStack(alignment: .leading, spacing: 10) {
                Label("Import needs attention", systemImage: "exclamationmark.triangle").font(.headline)
                Text(issue).font(.footnote).foregroundStyle(.secondary)
                Button("Review Storage") { present(.storage) }
            }
            .studioCard()
        }
    }

    @ViewBuilder private var saveActivity: some View {
        let pending = model.pendingEdits
        if !pending.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Label("Couldn’t save changes", systemImage: "doc.badge.clock").font(.headline)
                Text("Your latest changes are still open in Inkribe. Open the project to try saving again.")
                    .font(.footnote).foregroundStyle(.secondary)
                ForEach(pending) { item in
                    NavigationLink(value: ProjectsRoute.project(item.id)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(.subheadline.weight(.semibold))
                            Text(item.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                }
            }
            .studioCard()
        }
    }

    @ViewBuilder private var queueActivity: some View {
        let processing = model.processing
        let completed = model.exports.artifacts.values.filter { $0.outputURL != nil }.count
        let failures = processing.entries.filter { $0.record.status == .failed || $0.record.status == .unrecoverable }.count
        let storageProblem = model.transcription.persistenceError != nil || model.exports.persistenceError != nil || processing.lifecycle.error != nil
        if processing.activeCount > 0 || completed > 0 || failures > 0 || storageProblem || processing.lifecycle.userPaused {
            NavigationLink(value: ProjectsRoute.queue) {
                StudioActivityLabel(title: storageProblem ? "Queue needs attention" : processing.lifecycle.userPaused ? "Queue paused by you" : "Your processing queue",
                    detail: "\(processing.processingCount) processing · \(processing.pendingCount) pending · \(completed) files ready" + (failures > 0 ? " · \(failures) need retry" : ""),
                    icon: storageProblem ? "exclamationmark.triangle" : processing.lifecycle.userPaused ? "pause.circle" : "list.bullet.rectangle")
            }
            .buttonStyle(.plain)
        }
    }

    private func libraryHeader(count: Int) -> some View {
        @Bindable var binding = model
        return HStack(alignment: .firstTextBaseline) {
            Text(searching ? "Results" : "Projects").font(.title2.weight(.bold))
            Text("\(count)").font(.subheadline).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Menu {
                Picker("Sort projects", selection: $binding.sort) {
                    Text("Recently updated").tag(LibrarySort.recent)
                    Text("Oldest updated").tag(LibrarySort.oldest)
                    Text("Title").tag(LibrarySort.title)
                }
            } label: { Label("Sort", systemImage: "arrow.up.arrow.down").font(.subheadline).frame(minHeight: 44) }
        }
    }

    @ViewBuilder private var emptyLibrary: some View {
        if model.isLoading && model.allProjects.isEmpty {
            ProgressView("Loading projects…").frame(maxWidth: .infinity, minHeight: 120)
        } else if model.libraryError != nil {
            Text("Your library could not be refreshed. Retry below; saved projects have not been removed.")
                .font(.subheadline).foregroundStyle(.secondary).studioCard()
        } else if !model.isFiltering && model.libraryIssues.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("A place for every project", systemImage: "folder").font(.headline)
                Text("Your video, captions and edits stay together. Choose New Project above to get started.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .studioCard()
        } else {
            ContentUnavailableView {
                Label(model.isFiltering ? "No matching projects" : "Projects need attention", systemImage: "folder.badge.questionmark")
            } description: {
                Text(model.isFiltering ? "Try another title or clear your filters." : "Review the issues below or refresh the library.")
            } actions: {
                if model.isFiltering {
                    Button("Clear search and filters") { model.clearLibraryFilters(); searchPresented = false }
                } else { Button("Refresh") { Task { await model.refreshLibrary() } } }
            }
        }
    }

    private func projectList(_ projects: [ProjectSummary]) -> some View {
        LazyVStack(spacing: 12) {
            ForEach(projects) { project in
                HStack(alignment: .top, spacing: 4) {
                    NavigationLink(value: ProjectsRoute.project(project.id)) {
                        ProjectRow(project: project, status: projectStatus(project), cacheGeneration: model.cacheGeneration)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.mutatingProjectIDs.contains(project.id))
                    Menu { projectActions(project) } label: {
                        Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Actions for " + project.title)
                }
                .studioCard()
                .contextMenu { projectActions(project) }
                .task(id: "\(project.id)-\(model.cacheGeneration)") {
                    guard project.thumbnailURL == nil, project.mediaKind == .video, project.available,
                          attemptedThumbnails.insert(project.id).inserted else { return }
                    await model.regenerateThumbnail(project.id)
                }
            }
        }
    }

    @ViewBuilder private var libraryIssues: some View {
        if let error = model.libraryError {
            VStack(alignment: .leading, spacing: 10) {
                Label("Library unavailable", systemImage: "exclamationmark.triangle").font(.headline)
                Text(error).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                Button("Retry library") { Task { await model.refreshLibrary() } }
            }
            .studioCard()
        }
        if !model.libraryIssues.isEmpty && !model.isFiltering {
            VStack(alignment: .leading, spacing: 12) {
                Label("Projects needing attention", systemImage: "exclamationmark.triangle").font(.headline)
                ForEach(model.libraryIssues) { issue in
                    VStack(alignment: .leading, spacing: 6) {
                        if let project = model.allProjects.first(where: { $0.id == issue.id }) {
                            NavigationLink(project.title, value: ProjectsRoute.project(project.id))
                        }
                        Text(issue.description).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                Button("Open Storage") { present(.storage) }
            }
            .studioCard()
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
            Text(title).font(.subheadline.weight(model.filter == filter ? .semibold : .regular))
                .padding(.horizontal, 14).frame(minHeight: 44)
                .background(model.filter == filter ? theme.accentColor.opacity(0.18) : theme.surfaceColor, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(model.filter == filter ? .isSelected : [])
    }

    @ToolbarContentBuilder private var libraryToolbar: some ToolbarContent {
        if path.isEmpty {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink(value: ProjectsRoute.settings) { Label("Settings", systemImage: "gearshape") }
                    .accessibilityIdentifier("toolbar.settings")
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: ProjectsRoute.queue) { Label("Queue", systemImage: "list.bullet.rectangle") }
                    .accessibilityIdentifier("toolbar.queue")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: presentProStatus) {
                    Label("Inkribe Pro", systemImage: model.access.hasPro ? "crown.fill" : "crown")
                }
                .accessibilityIdentifier("toolbar.pro")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("New Project", systemImage: "plus", action: beginImport)
                    .disabled(model.isImporting || model.isPreparingPhotos)
            }
        }
    }

    @ViewBuilder private func projectActions(_ project: ProjectSummary) -> some View {
        let busy = model.mutatingProjectIDs.contains(project.id)
        let pending = model.editors.hasPending(project.id)
        Button("Rename", systemImage: "pencil") {
            if pending || !project.available || model.transcription.isActive(project.id) {
                // Rename through the existing editor when it has unsaved changes.
                path.append(.renameProject(project.id))
            } else {
                renameTarget = project; renamedTitle = project.title; showingRename = true
            }
        }
        .disabled(busy)
        Button("Duplicate", systemImage: "plus.square.on.square") { Task { await model.duplicate(project.id) } }
            .disabled(busy || pending || !project.available)
        Button("Move to Trash", systemImage: "trash", role: .destructive) { trashTarget = project; showingTrash = true }
            .disabled(busy || pending || model.transcription.isActive(project.id) || model.transcription.persistenceError != nil)
    }

    private func projectStatus(_ project: ProjectSummary) -> ProjectCardStatus {
        if model.pendingEdits.contains(where: { $0.id == project.id }) {
            return .init(title: "Couldn’t save changes", icon: "exclamationmark.circle", needsAttention: true)
        }
        if model.editors.hasPending(project.id) {
            return .init(title: "Saving…", icon: "clock", isWorking: true)
        }
        if !project.available { return .init(title: "Missing media", icon: "exclamationmark.triangle", needsAttention: true) }
        if model.mutatingProjectIDs.contains(project.id) { return .init(title: "Updating project…", icon: "clock", isWorking: true) }
        let speech = model.transcription
        let record = speech.record(for: project.id)
        if let record, !record.status.isTerminal {
            let paused = speech.queue?.isPaused == true
            let title = paused ? "Transcription paused" : record.status == .pending ? "Queued" :
                record.status == .cancelling ? "Cancelling…" : speech.queue?.liveProgress[record.id]?.message ?? "Transcribing…"
            let fraction = speech.queue?.liveProgress[record.id]?.fractionCompleted
            let working = !paused && record.status == .processing
            return .init(title: title, icon: paused ? "pause.circle" : "waveform",
                progress: working ? fraction.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil } : nil, isWorking: working)
        }
        switch project.captionState {
        case .incomplete: return .init(title: "Captions available · Incomplete", icon: "captions.bubble", needsAttention: true)
        case .saved: return .init(title: "Captions saved", icon: "captions.bubble.fill")
        case .emptyResult: return .init(title: "Retry transcription", icon: "arrow.clockwise", needsAttention: true)
        case .noAudio: return .init(title: "No audio track", icon: "speaker.slash")
        case .needsTranscription:
            if speech.persistenceError != nil { return .init(title: "Transcription unavailable", icon: "exclamationmark.triangle", needsAttention: true) }
            if let record, record.status.isRetryable || record.status == .unrecoverable {
                return .init(title: record.status == .cancelled ? "Transcription cancelled" : "Transcription needs retry", icon: "arrow.clockwise", needsAttention: true)
            }
            return .init(title: "Needs captions", icon: "captions.bubble")
        }
    }

    private var canPresentLibraryError: Bool { path.isEmpty && sheet == nil && !showingRename && !showingTrash }
    private func present(_ destination: LibrarySheet) { guard sheet == nil else { return }; sheet = destination }
    private func presentProStatus() {
        guard sheet == nil else { return }
        proStartedWithoutEntitlement = !model.access.hasPro
        sheet = model.access.hasPro ? .celebration : .paywall
    }
    private func beginImport() {
        guard path.isEmpty, sheet == nil, !model.isImporting, !model.isPreparingPhotos else { return }
        model.prepareImport()
        importedProjectIDs = []
        importPresented = true
        sheet = .newProject
    }
    private func finishPresentation() {
        if importPresented {
            model.clearSelection()
            importPresented = false
        }
        let celebrate = proStartedWithoutEntitlement && model.access.hasPro
        proStartedWithoutEntitlement = false
        let ids = importedProjectIDs
        importedProjectIDs = []
        if !ids.isEmpty {
            model.clearLibraryFilters(); searchPresented = false; model.sort = .recent
            if ids.count == 1 { path.append(.project(ids[0])) }
            else { importNoticeCount = ids.count }
        } else if celebrate {
            Task {
                await Task.yield()
                guard sheet == nil else { return }
                sheet = .celebration
            }
        }
    }
}

private enum LibrarySheet: String, Identifiable {
    case newProject, paywall, celebration, storage, models
    var id: Self { self }
}
private enum ProjectsRoute: Hashable { case project(UUID), renameProject(UUID), settings, queue }
