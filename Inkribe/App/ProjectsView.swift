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
    @State private var attemptedThumbnailTasks: [UUID: String] = [:]
    @State private var path: [ProjectsRoute] = []
    @State private var importedProjectIDs: [UUID] = []
    @State private var importPresented = false
    @State private var importFolderID: UUID?
    @State private var importNoticeCount = 0
    @State private var renameTarget: ProjectSummary?
    @State private var renamedTitle = ""
    @State private var showingRename = false
    @State private var trashTarget: ProjectSummary?
    @State private var showingTrash = false
    @State private var searchPresented = false
    @State private var folderToDelete: LibraryFolder?
    @State private var projectToDelete: ProjectRepository.TrashedProject?
    @State private var pendingQueueRoute: QueueProjectRoute?
    @State private var queueFallbackDetails: ProcessingJobKey?
    @State private var didEnterBackground = false
    private var searching: Bool { searchPresented || !model.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack(path: $path) { libraryLifecycle }
            .sheet(item: $sheet, onDismiss: finishPresentation) { destination in
                switch destination {
                case .newProject: ImportView(onImported: { importedProjectIDs = $0 })
                case .paywall: ProPaywall()
                case .celebration: ProCelebration()
                case .captionUsage: ProUpsell(feature: .captioning, isUsageOverview: true)
                case .storage: StorageView()
                case .folder(let folder): LibraryFolderEditor(folder: folder, onSaved: { searchPresented = false })
                }
            }
            .queueJobDetails($queueFallbackDetails)
            .task {
                updateProcessingScene(scenePhase)
                await model.processing.start()
                await model.refresh()
            }
            .onChange(of: scenePhase) { _, phase in
                updateProcessingScene(phase)
                if phase == .active {
                    Task { await model.refresh(); await model.transcription.refreshAllowance() }
                } else {
                    Task { await model.editors.flushAll() }
                }
            }
            .environment(\.queueProjectNavigation, QueueProjectNavigation(open: openQueueProject))
    }

    private var libraryLifecycle: some View {
        libraryDialogs
            .onChange(of: model.transcription.resultGeneration) { _, _ in Task { await model.refreshLibrary() } }
            .onChange(of: path) { _, value in
                if value.isEmpty { Task { await model.refreshLibrary() } }
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
            } message: { project in Text("\(project.title) can be restored from the Trash pill or Storage.") }
            .confirmationDialog("Delete folder?", isPresented: Binding(
                get: { folderToDelete != nil }, set: { if !$0 { folderToDelete = nil } }
            ), presenting: folderToDelete) { folder in
                Button("Delete Folder", role: .destructive) {
                    folderToDelete = nil
                    Task { await model.deleteFolder(folder.id) }
                }
                Button("Cancel", role: .cancel) { folderToDelete = nil }
            } message: { folder in
                Text("Delete “\(folder.name)”? Its projects stay in All. Projects in Trash are kept too.")
            }
            .confirmationDialog("Delete project forever?", isPresented: Binding(
                get: { projectToDelete != nil }, set: { if !$0 { projectToDelete = nil } }
            ), presenting: projectToDelete) { project in
                Button("Delete Forever", role: .destructive) {
                    projectToDelete = nil
                    Task { await model.permanentlyDelete(project.id) }
                }
                Button("Cancel", role: .cancel) { projectToDelete = nil }
            } message: { project in
                Text("“\(project.title)” and its original media, captions and edits will be permanently removed. Completed export files are kept.")
            }
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
            .navigationSubtitle("Your caption studio")
            .themedSurface()
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $binding.search, isPresented: $searchPresented,
                        placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search projects")
            .toolbar { libraryToolbar }
            .navigationDestination(for: ProjectsRoute.self) { route in
                switch route {
                case .project(let id): ProjectEditorDestination(projectID: id)
                case .renameProject(let id): ProjectEditorDestination(projectID: id, renameOnOpen: true)
                case .settings: SettingsView(onShowPro: presentProStatus)
                case .queue: ProcessingQueueView()
                case .queueProject(let route):
                    ProjectEditorDestination(projectID: route.projectID, queueRoute: route)
                }
            }
    }

    private var libraryScroll: some View {
        let projects = model.projects
        return List {
            VStack(alignment: .leading, spacing: 20) {
                if !searching {
                    libraryHero
                    importSummary
                    saveActivity
                    if !model.transcription.modelAvailable && !model.transcription.models.isLoading {
                        Button { path.append(.settings) } label: {
                            StudioActivityLabel(title: "Transcription setup needed",
                                detail: "Open Settings to prepare on-device transcription.",
                                icon: "gearshape")
                        }
                        .buttonStyle(.plain)
                    }
                }
                libraryHeader
                if !searching { folderStrip }
                else if model.scope != .all {
                    Button("Search all projects", systemImage: "rectangle.stack") { model.scope = .all }
                        .font(.subheadline).frame(minHeight: 44)
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 8)
            .buttonStyle(.borderless)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            if model.scope == .trash {
                if model.visibleTrashed.isEmpty { emptyLibrary.libraryChromeRow() }
                else { trashList }
            } else if projects.isEmpty { emptyLibrary.libraryChromeRow() }
            else { projectList(projects) }
            libraryIssues.libraryChromeRow()

            // Keep the final row reachable above the floating Add button.
            Color.clear.frame(height: 88)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .accessibilityHidden(true)
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.interactively)
        .overlay(alignment: .bottomTrailing) {
            if path.isEmpty {
                floatingNewProjectButton
                    .padding(.trailing, 20)
                    .padding(.bottom, 12)
            }
        }
    }

    private var floatingNewProjectButton: some View {
        Menu {
            Button("New Project", systemImage: "plus.rectangle", action: beginImport)
                .disabled(model.isImporting || model.isPreparingPhotos)
            Button("New Folder", systemImage: "folder.badge.plus") { present(.folder(nil)) }
                .disabled(!model.organizationReady)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(theme.appearance.preferredColorScheme == .dark ? theme.backgroundColor : Color.white)
                .frame(width: 56, height: 56)
                .background(theme.accentColor, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.16), radius: 10, x: 0, y: 4)
        .disabled(model.isImporting || model.isPreparingPhotos)
        .accessibilityLabel("Add")
        .accessibilityHint("Create a project or folder")
        .accessibilityIdentifier("home.add")
    }

    /// Browsing filters and sort order never change the featured project.
    private var recentProject: ProjectSummary? {
        model.allProjects.max { a, b in
            if a.updatedAt != b.updatedAt { return a.updatedAt < b.updatedAt }
            return a.id.uuidString > b.id.uuidString
        }
    }

    private var libraryHero: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let project = recentProject {
                    recentProjectSection(project)
                } else if !model.hasLoadedLibrary && model.libraryError == nil {
                    ProgressView("Loading projects…")
                        .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
                        .padding(20)
                } else {
                    ProjectCreationHero(isBusy: model.isImporting || model.isPreparingPhotos, create: beginImport)
                        .padding(20)
                }
            }

            if !model.access.hasPro {
                heroDivider
                captionUsage
            }

            heroDivider
            queueSummary
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfaceColor, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(theme.borderColor, lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .accessibilityIdentifier("home.hero")
    }

    private var heroDivider: some View {
        Divider()
            .overlay(theme.borderColor)
            .padding(.horizontal, 20)
            .accessibilityHidden(true)
    }

    private func recentProjectSection(_ project: ProjectSummary) -> some View {
        Button { path.append(.project(project.id)) } label: {
            VStack(alignment: .leading, spacing: 14) {
                Label("Recent Project", systemImage: "clock.arrow.circlepath")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    ProjectRow(project: project, status: projectStatus(project), cacheGeneration: model.cacheGeneration,
                               isFavorite: model.isFavorite(project.id))
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(20)
            .contentShape(Rectangle())
        }
        // Explicit non-row button style confines activation to this section.
        .buttonStyle(.borderless)
        .disabled(model.mutatingProjectIDs.contains(project.id))
        .accessibilityHint("Opens the most recently updated project")
        .accessibilityIdentifier("home.recentProject")
        .task(id: thumbnailTaskID(for: project)) {
            await prepareThumbnail(for: project)
        }
    }

    private var captionUsage: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let speech = model.transcription
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    guard !model.access.hasPro else { return }
                    present(.captionUsage)
                } label: {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Captioning This Week", systemImage: "waveform")
                                .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                            if speech.allowanceError != nil || speech.persistenceError != nil {
                                Text("Usage is unavailable. Retry to load your weekly allowance.")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else if let usage = speech.allowance {
                                Text(usage.summary).font(.caption).foregroundStyle(.secondary)
                                ProgressView(value: min(1, max(0, Double(usage.used + usage.reserved) / Double(Commerce.weeklySeconds))))
                                    .tint(theme.accentColor)
                                    .accessibilityLabel("Weekly captioning allowance used or reserved")
                                if usage.reserved > 0 {
                                    Text("\(usage.reserved / 60)m \(usage.reserved % 60)s reserved for queued work")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Text("Resets \(usage.resetsAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption2).foregroundStyle(.secondary)
                            } else {
                                ProgressView("Loading usage…").font(.caption).foregroundStyle(.secondary)
                            }
                            Text("Unlock unlimited captioning")
                                .font(.caption.weight(.medium)).foregroundStyle(theme.accentColor)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    .multilineTextAlignment(.leading)
                    .padding(20)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityElement(children: .combine)
                .accessibilityHint("Shows upgrade options for unlimited captioning")

                if speech.allowanceError != nil || speech.persistenceError != nil {
                    // A separate sibling button; never nest Retry inside the upsell button.
                    Button("Retry usage") {
                        if speech.persistenceError != nil { speech.retryStorage() }
                        else { Task { await speech.refreshAllowance() } }
                    }
                    .buttonStyle(.borderless)
                    .frame(minHeight: 44)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Refresh an open home screen when the weekly allowance rolls over.
            .task(id: CaptionAllowanceLedger.week(containing: context.date)) {
                await speech.refreshAllowance()
            }
        }
        .accessibilityIdentifier("home.captionUsage")
    }

    @ViewBuilder private var importSummary: some View {
        if importNoticeCount > 0 {
            HStack {
                Label("\(importNoticeCount) project\(importNoticeCount == 1 ? "" : "s") added", systemImage: "checkmark.circle.fill").font(.subheadline)
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
                    Button { path.append(.project(item.id)) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(.subheadline.weight(.semibold))
                            Text(item.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
            .studioCard()
        }
    }

    private var queueSummary: some View {
        let processing = model.processing
        let entries = processing.entries
        let processingCount = entries.filter(\.processing).count
        let pendingCount = entries.filter(\.pending).count
        let completed = model.exports.artifacts.values.filter { $0.outputURL != nil }.count
        let failures = entries.filter(\.failed).count
        let storageProblem = model.transcription.persistenceError != nil || model.exports.persistenceError != nil
            || model.exports.inventoryError != nil || processing.lifecycle.error != nil
        let paused = processing.lifecycle.needsResume || (!processing.lifecycle.foreground &&
            processing.lifecycle.backgroundKinds.isEmpty && processing.activeCount > 0)
        let needsAttention = storageProblem || failures > 0
        let title = needsAttention ? "Queue needs attention" : paused ? "Queue paused" : "Processing Queue"
        let detail = "\(processingCount) processing · \(pendingCount) waiting · \(completed) files ready"
            + (failures > 0 ? " · \(failures) need attention" : "")

        return Button { path.append(.queue) } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: needsAttention ? "exclamationmark.triangle" : paused ? "pause.circle" : "list.bullet.rectangle")
                    .font(.headline).foregroundStyle(theme.accentColor).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44, alignment: .center)
            .padding(20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens processing jobs and completed files")
        .accessibilityIdentifier("home.queue")
    }

    private var libraryHeader: some View {
        @Bindable var binding = model
        return HStack(spacing: 4) {
            Text(searching ? "Results" : model.scope == .trash ? "Trash" : "Projects")
                .font(.title2.weight(.bold)).fixedSize(horizontal: false, vertical: true)
            Menu {
                Picker("Sort By", selection: $binding.sort) {
                    ForEach(ProjectSortField.allCases) { field in
                        Text(field.title).tag(field)
                    }
                }
                Picker("Order", selection: $binding.isSortAscending) {
                    Text("Ascending").tag(true)
                    Text("Descending").tag(false)
                }
            } label: { Image(systemName: "arrow.up.arrow.down").frame(width: 44, height: 44) }
            .accessibilityLabel("Sort projects")
            Menu {
                if let folder = model.selectedFolder {
                    Button("Rename Folder", systemImage: "pencil") { present(.folder(folder)) }
                        .disabled(!model.organizationReady)
                    Button("Delete Folder", systemImage: "trash", role: .destructive) { folderToDelete = folder }
                        .disabled(!model.organizationReady)
                    Divider()
                }
                Button("Manage Storage", systemImage: "internaldrive") { present(.storage) }
            } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
            .accessibilityLabel("Project options")
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var emptyLibrary: some View {
        if model.scope == .trash && model.isLoadingTrash {
            ProgressView("Loading Trash…").frame(maxWidth: .infinity, minHeight: 120)
        } else if !model.hasLoadedLibrary && model.libraryError == nil && model.scope != .trash {
            ProgressView("Loading projects…").frame(maxWidth: .infinity, minHeight: 120)
        } else if model.scope == .trash && model.trashError != nil {
            Text("Trash could not be refreshed. Retry below; no projects have been removed.")
                .font(.subheadline).foregroundStyle(.secondary).studioCard()
        } else if model.scope != .trash && model.libraryError != nil {
            Text("Your library could not be refreshed. Retry below; saved projects have not been removed.")
                .font(.subheadline).foregroundStyle(.secondary).studioCard()
        } else {
            ContentUnavailableView {
                Label(emptyTitle, systemImage: model.scope == .trash ? "trash" : "folder")
            } description: {
                Text(emptyDescription)
            }
        }
    }

    private var emptyTitle: String {
        if searching { return "No matching projects" }
        switch model.scope {
        case .all: return "No projects yet"
        case .favorites: return "No favorites yet"
        case .folder: return "Folder is empty"
        case .trash: return "Trash is empty"
        }
    }

    private var emptyDescription: String {
        if searching { return "Try another title or search All projects." }
        switch model.scope {
        case .all: return "Use + to create a project from video or audio."
        case .favorites: return "Add a project to Favorites from its actions menu."
        case .folder: return "Move projects here from their actions menu, or use + to create one in this folder."
        case .trash: return "Projects moved to Trash stay here until you restore or permanently delete them."
        }
    }

    private func projectList(_ projects: [ProjectSummary]) -> some View {
        ForEach(projects) { project in
            NavigationLink(value: ProjectsRoute.project(project.id)) {
                ProjectRow(project: project, status: projectStatus(project), cacheGeneration: model.cacheGeneration,
                           isFavorite: model.isFavorite(project.id), isCompact: true)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .disabled(model.mutatingProjectIDs.contains(project.id))
            .contextMenu { projectActions(project) }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button("Move to Trash", systemImage: "trash", role: .destructive) {
                    trashTarget = project; showingTrash = true
                }
                .disabled(!canTrash(project))
                Button("Rename", systemImage: "pencil") { beginRename(project) }
                    .tint(theme.accentColor)
                    .disabled(model.mutatingProjectIDs.contains(project.id))
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                favoriteAction(project).tint(.orange)
            }
            .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(theme.borderColor)
            .task(id: thumbnailTaskID(for: project)) {
                await prepareThumbnail(for: project)
            }
        }
    }

    private func thumbnailTaskID(for project: ProjectSummary) -> String {
        "\(project.id)-\(project.contentRevision)-\(model.cacheGeneration)"
    }

    private func prepareThumbnail(for project: ProjectSummary) async {
        let taskID = thumbnailTaskID(for: project)
        guard !Task.isCancelled, project.thumbnailURL == nil, project.mediaKind == .video, project.available,
              attemptedThumbnailTasks[project.id] != taskID else { return }
        attemptedThumbnailTasks[project.id] = taskID
        await model.regenerateMissingThumbnail(project.id)
    }

    private var trashList: some View {
        ForEach(model.visibleTrashed) { project in
            VStack(alignment: .leading, spacing: 12) {
                Text(project.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                if let issue = project.issue {
                    Text(issue).font(.caption).foregroundStyle(.secondary)
                }
                ViewThatFits(in: .horizontal) {
                    HStack { trashActions(project) }
                    VStack(alignment: .leading) { trashActions(project) }
                }
                .buttonStyle(.borderless)
                .frame(minHeight: 44)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .contextMenu { trashActions(project) }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                restoreAction(project).tint(theme.accentColor)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                permanentlyDeleteAction(project)
            }
            .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(theme.borderColor)
        }
    }

    @ViewBuilder private func trashActions(_ project: ProjectRepository.TrashedProject) -> some View {
        restoreAction(project)
        permanentlyDeleteAction(project)
    }

    private func restoreAction(_ project: ProjectRepository.TrashedProject) -> some View {
        Button("Restore", systemImage: "arrow.uturn.backward") { Task { await model.restore(project.id) } }
            .disabled(project.issue != nil || model.mutatingProjectIDs.contains(project.id))
    }

    private func permanentlyDeleteAction(_ project: ProjectRepository.TrashedProject) -> some View {
        Button("Delete Forever", systemImage: "trash", role: .destructive) { projectToDelete = project }
            .disabled(model.mutatingProjectIDs.contains(project.id) || model.transcription.persistenceError != nil
                      || model.transcription.isActive(project.id) || model.editors.hasPending(project.id))
    }

    @ViewBuilder private var libraryIssues: some View {
        if let error = model.organizationError {
            VStack(alignment: .leading, spacing: 10) {
                Label("Folders and favorites need attention", systemImage: "exclamationmark.triangle").font(.headline)
                Text(error).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                Button("Retry folders and favorites") { Task { await model.refreshOrganization() } }
            }
            .studioCard()
        }
        if let error = model.trashError {
            VStack(alignment: .leading, spacing: 10) {
                Label("Trash unavailable", systemImage: "exclamationmark.triangle").font(.headline)
                Text(error).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                Button("Retry Trash") { Task { await model.refreshTrash() } }
            }
            .studioCard()
        }
        if model.scope != .trash, let error = model.libraryError {
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

    private var folderStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                scopePill("All", icon: "rectangle.stack.fill", scope: .all)
                scopePill("Favorites", icon: "star.fill", scope: .favorites)
                    .disabled(!model.organizationReady)
                ForEach(model.folders) { folder in
                    scopePill(folder.name, icon: "folder.fill", scope: .folder(folder.id))
                        .disabled(!model.organizationReady)
                }
                scopePill("Trash", icon: "trash", scope: .trash)
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        .accessibilityLabel("Project folders")
    }
    private func scopePill(_ title: String, icon: String, scope: LibraryScope) -> some View {
        Button { model.scope = scope } label: {
            LibraryScopePill(title: title, systemImage: icon, count: model.projectCount(in: scope),
                             isSelected: model.scope == scope)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(model.scope == scope ? .isSelected : [])
    }

    @ToolbarContentBuilder private var libraryToolbar: some ToolbarContent {
        if path.isEmpty {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(action: presentProStatus) {
                    Label("Inkribe Pro", systemImage: model.access.hasPro ? "crown.fill" : "crown")
                }
                .labelStyle(.iconOnly)
                .accessibilityIdentifier("toolbar.pro")
                NavigationLink(value: ProjectsRoute.settings) { Label("Settings", systemImage: "gearshape") }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("toolbar.settings")
            }
        }
    }

    @ViewBuilder private func projectActions(_ project: ProjectSummary) -> some View {
        let busy = model.mutatingProjectIDs.contains(project.id)
        let pending = model.editors.hasPending(project.id)
        favoriteAction(project)
        Menu {
            Button {
                Task { _ = await model.moveProjects([project.id], to: nil) }
            } label: {
                Label("None", systemImage: model.folderID(for: project.id) == nil ? "checkmark" : "folder")
            }
            ForEach(model.folders) { folder in
                Button {
                    Task { _ = await model.moveProjects([project.id], to: folder.id) }
                } label: {
                    Label(folder.name, systemImage: model.folderID(for: project.id) == folder.id ? "checkmark" : "folder")
                }
            }
        } label: { Label("Move to Folder", systemImage: "folder") }
        .disabled(busy || !model.organizationReady)
        Divider()
        Button("Rename", systemImage: "pencil") { beginRename(project) }.disabled(busy)
        Button("Duplicate", systemImage: "plus.square.on.square") { Task { await model.duplicate(project.id) } }
            .disabled(busy || pending || !project.available)
        Button("Move to Trash", systemImage: "trash", role: .destructive) { trashTarget = project; showingTrash = true }
            .disabled(!canTrash(project))
    }

    private func favoriteAction(_ project: ProjectSummary) -> some View {
        Button(model.isFavorite(project.id) ? "Remove from Favorites" : "Add to Favorites",
               systemImage: model.isFavorite(project.id) ? "star.slash" : "star") {
            Task { await model.toggleFavorite(project.id) }
        }
        .disabled(model.mutatingProjectIDs.contains(project.id) || !model.organizationReady)
    }

    private func canTrash(_ project: ProjectSummary) -> Bool {
        !model.mutatingProjectIDs.contains(project.id) && !model.editors.hasPending(project.id)
            && !model.transcription.isActive(project.id) && model.transcription.persistenceError == nil
    }

    private func beginRename(_ project: ProjectSummary) {
        guard !model.mutatingProjectIDs.contains(project.id) else { return }
        if model.editors.hasPending(project.id) || !project.available || model.transcription.isActive(project.id) {
            path.append(.renameProject(project.id))
        } else {
            renameTarget = project; renamedTitle = project.title; showingRename = true
        }
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

    private var canPresentLibraryError: Bool {
        path.isEmpty && sheet == nil && !showingRename && !showingTrash && folderToDelete == nil && projectToDelete == nil
    }
    private func present(_ destination: LibrarySheet) { guard sheet == nil else { return }; sheet = destination }
    private func presentProStatus() {
        guard sheet == nil else { return }
        proStartedWithoutEntitlement = !model.access.hasPro
        sheet = model.access.hasPro ? .celebration : .paywall
    }
    private func beginImport() {
        guard path.isEmpty, sheet == nil, !model.isImporting, !model.isPreparingPhotos else { return }
        model.prepareImport()
        importFolderID = model.selectedFolder?.id
        importedProjectIDs = []
        importPresented = true
        sheet = .newProject
    }
    private func finishPresentation() {
        if let route = pendingQueueRoute {
            pendingQueueRoute = nil
            showQueueProject(route)
            return
        }
        if importPresented {
            model.clearSelection()
            importPresented = false
        }
        let celebrate = proStartedWithoutEntitlement && model.access.hasPro
        proStartedWithoutEntitlement = false
        let ids = importedProjectIDs
        let folder = importFolderID
        importFolderID = nil
        importedProjectIDs = []
        if !ids.isEmpty {
            Task {
                let filed = if let folder { await model.moveProjects(ids, to: folder) } else { true }
                model.clearLibraryFilters(); searchPresented = false
                if filed, let folder { model.scope = .folder(folder) }
                if filed && ids.count == 1 && path.isEmpty && sheet == nil { path.append(.project(ids[0])) }
                else { importNoticeCount = ids.count }
            }
        } else if celebrate {
            Task {
                await Task.yield()
                guard sheet == nil else { return }
                sheet = .celebration
            }
        }
    }

    private func openQueueProject(_ route: QueueProjectRoute) {
        guard !model.exports.hasUserDelivery, pendingQueueRoute == nil else { return }
        if sheet != nil {
            pendingQueueRoute = route
            sheet = nil
        } else {
            showQueueProject(route)
        }
    }

    private func showQueueProject(_ route: QueueProjectRoute) {
        // A project can move to Trash while its enclosing sheet dismisses.
        guard model.allProjects.contains(where: { $0.id == route.projectID }) else {
            queueFallbackDetails = route.job
            return
        }
        path.append(.queueProject(route))
    }

    private func updateProcessingScene(_ phase: ScenePhase) {
        if phase == .background { didEnterBackground = true }
        let returning = phase == .active && didEnterBackground
        if phase == .active { didEnterBackground = false }
        model.processing.setForeground(phase == .active, recoveringFromBackground: returning)
    }
}

private enum LibrarySheet: Identifiable {
    case newProject, paywall, celebration, storage, captionUsage
    case folder(LibraryFolder?)
    var id: String {
        switch self {
        case .newProject: "newProject"
        case .paywall: "paywall"
        case .celebration: "celebration"
        case .storage: "storage"
        case .captionUsage: "captionUsage"
        case .folder(let folder): "folder-" + (folder?.id.uuidString ?? "new")
        }
    }
}
private enum ProjectsRoute: Hashable {
    case project(UUID), renameProject(UUID), settings, queue, queueProject(QueueProjectRoute)
}

private extension View {
    func libraryChromeRow() -> some View {
        self
            .buttonStyle(.borderless)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}


