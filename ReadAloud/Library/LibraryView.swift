import AppFoundation
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(ProjectRuntimeManager.self) private var runtimeManager
    @Environment(PurchaseManager.self) private var purchases
    @Environment(\.appFoundationTheme) private var theme
    @State private var model = LibraryModel()
    @State private var isFileImporterPresented = false
    @State private var allowedContentTypes: [UTType] = [.data]
    @State private var pasteDraft = PasteDraft()
    @State private var isPastePresented = false
    @State private var isURLPresented = false
    @State private var urlDraft = ""
    @State private var pendingURLImport: URL?
    @State private var renameTarget: LibraryModel.Entry?
    @State private var renameText = ""
    @State private var deleteTarget: LibraryModel.Entry?
    @State private var infoTarget: LibraryModel.Entry?
    @State private var isIssuesPresented = false
    @State private var proDestination: LibraryProDestination?
    @State private var pendingPasteImport: PasteDraft?
    @State private var selectedSourceFilter: LibrarySourceFilter = .all

    var body: some View {
        Group {
            if model.isLoading && !model.didLoad {
                ProgressView("Loading Library…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                libraryContent
            }
        }
        .readAloudThemeSurface()
        .navigationTitle("Library")
        .navigationSubtitle("Your space for listening.")
        .navigationBarTitleDisplayMode(.large)
        .searchable(
            text: Binding(
                get: { model.searchText },
                set: { model.searchText = $0 }
            ),
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Search your library"
        )
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                sortMenu
                Button {
                    proDestination = purchases.hasPro ? .celebration : .paywall
                } label: {
                    Label("Pro", systemImage: purchases.hasPro ? "crown.fill" : "crown")
                }
                .labelStyle(.iconOnly)
                .accessibilityLabel(purchases.hasPro ? "Pro Status" : "Unlock Pro")
                .accessibilityIdentifier("toolbar.pro")
                NavigationLink {
                    SettingsView()
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
        }
        // Overlay instead of reserving a full bottom row. RootView's
        // mini-player safe-area inset keeps this button above the player,
        // whether the player is compact or expanded.
        .overlay(alignment: .bottomTrailing) {
            if model.didLoad {
                floatingAddMenu
                    .padding(.trailing, 20)
                    .padding(.bottom, 12)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.isImporting && model.importProgress == nil {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Cancelling import…")
                        .font(.subheadline)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
        }
        .onDisappear {
            model.cancelImport()
        }
        .refreshable {
            await model.refresh()
        }
        .task {
            await model.loadIfNeeded()
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: allowedContentTypes
        ) { result in
            switch result {
            case .success(let url):
                startFileImport(url)
            case .failure(let error):
                let cocoaError = error as NSError
                guard !(error is CancellationError),
                      !(cocoaError.domain == NSCocoaErrorDomain
                        && cocoaError.code == NSUserCancelledError) else {
                    return
                }
                model.errorMessage = error.localizedDescription
            }
        }
        .sheet(
            isPresented: $isPastePresented,
            onDismiss: {
                guard let draft = pendingPasteImport else { return }
                pendingPasteImport = nil
                startPasteImport(text: draft.text, title: draft.title)
            }
        ) {
            PasteTextSheet(
                draft: $pasteDraft,
                onCancel: {
                    pendingPasteImport = nil
                    isPastePresented = false
                },
                onImport: {
                    pendingPasteImport = pasteDraft
                    isPastePresented = false
                }
            )
        }
        .sheet(
            isPresented: $isURLPresented,
            onDismiss: {
                guard let url = pendingURLImport else { return }
                pendingURLImport = nil
                Task { _ = await model.importWeb(url) }
            }
        ) {
            FromURLSheet(
                urlText: $urlDraft,
                onCancel: {
                    pendingURLImport = nil
                    isURLPresented = false
                },
                onImport: { url in
                    pendingURLImport = url
                    isURLPresented = false
                }
            )
        }
        .sheet(item: $proDestination) { destination in
            switch destination {
            case .paywall:
                ReadAloudProPaywall()
            case .celebration:
                ProCelebrationView(
                    configuration: FoundationProCelebrationConfiguration(
                        navigationTitle: "ReadAloud Pro",
                        message: "Thanks for supporting ReadAloud. Enjoy unlimited listening, all 28 voices, and every theme."
                    )
                )
            }
        }
        .sheet(item: $infoTarget) { entry in
            ProjectInfoSheet(entry: entry)
        }
        .sheet(isPresented: $isIssuesPresented) {
            LibraryIssuesSheet(issues: model.catalogIssues)
        }
        .sheet(
            isPresented: Binding(
                get: { model.importProgress != nil },
                set: { presented in
                    if !presented {
                        model.cancelImport()
                    }
                }
            )
        ) {
            if let progress = model.importProgress {
                ImportProgressSheet(
                    progress: progress,
                    onCancel: {
                        model.cancelImport()
                    }
                )
            }
        }
        .alert(
            "Rename Project",
            isPresented: Binding(
                get: { renameTarget != nil },
                set: { presented in
                    if !presented {
                        renameTarget = nil
                    }
                }
            )
        ) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                guard let target = renameTarget else { return }
                Task {
                    if await model.rename(
                        projectID: target.id,
                        to: renameText
                    ) {
                        try? await runtimeManager.refreshIfLoaded(
                            projectID: target.id
                        )
                    }
                    renameTarget = nil
                }
            }
            .disabled(
                renameText.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
            )
        }
        .confirmationDialog(
            "Delete Project?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { presented in
                    if !presented {
                        deleteTarget = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Project", role: .destructive) {
                guard let target = deleteTarget else { return }
                Task {
                    do {
                        try await runtimeManager.deleteProject(projectID: target.id)
                        await model.refresh()
                    } catch {
                        model.errorMessage = error.localizedDescription
                    }
                    deleteTarget = nil
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let deleteTarget {
                Text("“\(deleteTarget.snapshot.title)” and its local audio will be removed from this device.")
            }
        }
        .alert(
            "Library Error",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { presented in
                    if !presented {
                        model.errorMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                model.errorMessage = nil
            }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var featuredEntry: LibraryModel.Entry? {
        if let runtime = runtimeManager.playerRuntime,
           let entry = model.entries.first(where: { $0.id == runtime.id }) { return entry }
        return model.continueListening
            ?? model.entries.max(by: { $0.snapshot.updatedAt < $1.snapshot.updatedAt })
    }

    private var visibleEntries: [LibraryModel.Entry] {
        model.filteredEntries.filter {
            selectedSourceFilter.matches($0.snapshot.sourceType)
        }
    }

    private var libraryContent: some View {
        ReadAloudThemedList {
            VStack(alignment: .leading, spacing: 18) {
                if model.entries.isEmpty {
                    emptyLibraryHero
                } else if let featuredEntry {
                    continueListeningHero(featuredEntry)
                }

                filterStrip

                HStack {
                    Text("Your Library")
                        .font(.headline)
                    Spacer()
                    Text("\(visibleEntries.count) items")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 8)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            if !model.catalogIssues.isEmpty {
                Button {
                    isIssuesPresented = true
                } label: {
                    Label(
                        "\(model.catalogIssues.count) project package(s) need attention",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.subheadline)
                }
                .foregroundStyle(.secondary)
                .listRowBackground(Color.clear)
            }

            if visibleEntries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: model.entries.isEmpty ? "books.vertical" : "line.3.horizontal.decrease.circle")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text(model.entries.isEmpty ? "No items yet" : "No matching items")
                        .font(.subheadline.weight(.medium))
                    Text(
                        model.entries.isEmpty
                            ? "Books and articles you add will appear here."
                            : "Try another filter or search."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            } else {
                ForEach(visibleEntries) { entry in
                    NavigationLink {
                        ProjectDetailRuntimeHost(
                            projectID: entry.id,
                            initialTitle: entry.snapshot.title,
                            onProjectChanged: {
                                Task { await model.refresh() }
                            }
                        )
                    } label: {
                        LibraryProjectRow(entry: entry)
                    }
                    .contextMenu {
                        projectMenu(entry)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Delete", role: .destructive) {
                            deleteTarget = entry
                        }
                        Button("Rename") {
                            beginRename(entry)
                        }
                        .tint(.accentColor)
                    }
                    .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                    .listRowBackground(Color.clear)
                }
            }

            // Keep the final row reachable behind the floating Add button.
            Color.clear
                .frame(height: 66)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .accessibilityHidden(true)
        }
        .listStyle(.plain)
    }

    private var emptyLibraryHero: some View {
        VStack(spacing: 14) {
            Image(systemName: "headphones")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 72, height: 72)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 20))

            Text("Your listening library starts here")
                .font(.title3.bold())
                .multilineTextAlignment(.center)
                .foregroundStyle(theme.primaryForegroundColor)

            Text("Add a book, web article, or your own text to listen whenever you like.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(heroSecondaryText)

            Menu {
                addMenuItems
            } label: {
                Label("Add Content", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.backgroundColor)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12))
            }
            .disabled(model.isImporting)
            .accessibilityHint("Choose a book, document, web article, or text to add")
            listeningUsage
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(heroBackground, in: RoundedRectangle(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(theme.primaryForegroundColor.opacity(0.12), lineWidth: 1)
        }
    }

    private func continueListeningHero(_ entry: LibraryModel.Entry) -> some View {
        let runtime = runtimeManager.runtimeIfLoaded(projectID: entry.id)
        let presentation = ListeningHeroPresentation(
            state: runtime?.activity.playbackState,
            active: runtime?.isPlaybackActive == true,
            paused: runtime?.isPlaybackPaused == true,
            preparing: runtime?.isPlayerPreparing == true,
            hasHistory: runtime?.project?.playback?.lastPlayedAt != nil || entry.snapshot.lastPlayedAt != nil
        )
        let progress = runtime?.project?.playback?.projectProgress ?? entry.snapshot.projectProgress
        let currentID = runtime?.playerControlItemID(fallback: runtime?.continueItemID)
        let chapterIndex = runtime?.itemStates.firstIndex { $0.id == currentID }
        let hasPresentedPlayer = runtime != nil
            && runtimeManager.playerRuntime === runtime
            && runtime?.isPlayerDismissed == false
            && currentID != nil

        return VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text(presentation.heading)
                    .font(.caption2.weight(.bold))
                    .tracking(1.4)
                Spacer()
                Image(systemName: "headphones")
            }
            .foregroundStyle(heroSecondaryText)

            NavigationLink {
                ProjectReaderRuntimeHost(
                    projectID: entry.id,
                    initialItemID: currentID,
                    initialTitle: entry.snapshot.title,
                    onProjectChanged: { Task { await model.refresh() } }
                )
            } label: {
                HStack(spacing: 14) {
                    ProjectArtworkView(
                        url: entry.artworkURL, sourceType: entry.snapshot.sourceType,
                        width: 70, height: 94
                    )
                    VStack(alignment: .leading, spacing: 6) {
                        Text(runtime?.project?.title ?? entry.snapshot.title)
                            .font(.headline)
                            .foregroundStyle(theme.primaryForegroundColor)
                            .lineLimit(2)
                        Text(entry.snapshot.author ?? ReadAloudDisplay.sourceType(entry.snapshot.sourceType))
                            .font(.subheadline)
                            .foregroundStyle(heroSecondaryText)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the reader")

            if let runtime, let chapterIndex {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Chapter \(chapterIndex + 1) of \(runtime.itemStates.count)")
                        .font(.caption)
                        .foregroundStyle(heroSecondaryText)
                    Text(runtime.itemStates[chapterIndex].item.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: min(1, max(0, progress)))
                    .tint(Color.accentColor)
                    .accessibilityLabel("Listening progress")
                Text("\(Int(min(1, max(0, progress)) * 100))% listened")
                    .font(.caption)
                    .foregroundStyle(heroSecondaryText)
            }
            if runtime == nil {
                ProgressView("Loading chapters…").font(.caption)
            }
            if !hasPresentedPlayer, runtime?.isPlayerPreparing == true {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Preparing audio…").font(.caption)
                }
            }
            if !hasPresentedPlayer, let error = presentation.error {
                Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Button {
                guard let runtime, let currentID else { return }
                if hasPresentedPlayer {
                    runtimeManager.openPlayerReader()
                    return
                }
                do {
                    runtimeManager.makeActive(runtime)
                    try runtime.listen(itemID: currentID)
                } catch { model.errorMessage = error.localizedDescription }
            } label: {
                Label(hasPresentedPlayer ? "Open Reader" : presentation.label,
                      systemImage: hasPresentedPlayer ? "book" : presentation.symbol)
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundStyle(theme.backgroundColor)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(runtime == nil || currentID == nil)
            listeningUsage
        }
        .padding(20)
        .background(heroBackground, in: RoundedRectangle(cornerRadius: 22))
        .task(id: entry.id) {
            do { _ = try await runtimeManager.prepareRuntime(projectID: entry.id) }
            catch is CancellationError { }
            catch { model.errorMessage = error.localizedDescription }
        }
    }

    private var heroBackground: Color {
        theme.surfaceColor
    }

    private var listeningUsage: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    purchases.hasPro ? "Unlimited listening · Pro"
                        : runtimeManager.listeningAllowance.usageDescription(at: context.date),
                    systemImage: purchases.hasPro ? "infinity" : "clock"
                )
                if !purchases.hasPro {
                    let reset = runtimeManager.listeningAllowance.resetDate(at: context.date)
                    Text("Resets \(reset.formatted(date: .abbreviated, time: .shortened))")
                }
            }
            .font(.caption)
            .foregroundStyle(heroSecondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
            .accessibilityElement(children: .combine)
        }
    }

    private var heroSecondaryText: Color {
        theme.primaryForegroundColor.opacity(0.7)
    }

    private var filterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LibrarySourceFilter.allCases) { filter in
                    let selected = selectedSourceFilter == filter
                    let count = model.entries.filter {
                        filter.matches($0.snapshot.sourceType)
                    }.count

                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedSourceFilter = filter
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(filter.title)
                                .font(.system(size: 13, weight: .medium))
                            if count > 0 {
                                Text("\(count)")
                                    .font(.system(size: 11, weight: .medium))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(
                                        selected ? Color.white.opacity(0.22)
                                            : Color.secondary.opacity(0.12),
                                        in: Capsule()
                                    )
                            }
                        }
                        .foregroundStyle(selected ? Color.white : theme.primaryForegroundColor)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            selected ? Color.accentColor
                                : theme.primaryForegroundColor.opacity(0.07),
                            in: Capsule()
                        )
                        .overlay {
                            Capsule().strokeBorder(
                                selected ? Color.clear : theme.primaryForegroundColor.opacity(0.14),
                                lineWidth: 0.5
                            )
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
        .contentMargins(.horizontal, 0)
    }

    private var sortMenu: some View {
        Menu {
            Picker(
                "Sort",
                selection: Binding(
                    get: { model.sortOption },
                    set: { model.sortOption = $0 }
                )
            ) {
                ForEach(LibraryModel.SortOption.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel("Sort Library")
    }

    private var floatingAddMenu: some View {
        Menu {
            addMenuItems
        } label: {
            Image(systemName: "plus")
                .foregroundStyle(
                    theme.appearance.preferredColorScheme == .dark
                        ? theme.backgroundColor : Color.white
                )
                .font(.system(size: 19, weight: .semibold))
                .frame(width: 48, height: 48)
                .background(Color.accentColor.gradient, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.16), radius: 10, x: 0, y: 4)
        .accessibilityLabel("Add to Library")
        .accessibilityHint("Add an EPUB, PDF, document, web article, or text")
        .disabled(model.isImporting)
    }

    @ViewBuilder
    private var addMenuItems: some View {
        Button {
            guard canCreateProject()
            else { return }
            presentFileImporter(
                types: [UTType(filenameExtension: "epub") ?? .data]
            )
        } label: {
            Label("Add EPUB", systemImage: "book.closed")
        }

        Button {
            guard canCreateProject()
            else { return }
            presentFileImporter(types: [.pdf])
        } label: {
            Label("Add PDF", systemImage: "doc.richtext")
        }

        Button {
            guard canCreateProject()
            else { return }
            presentFileImporter(types: documentTypes)
        } label: {
            Label("Add Document", systemImage: "doc.text")
        }

        Button {
            guard canCreateProject() else { return }
            isURLPresented = true
        } label: {
            Label("Add Web Article", systemImage: "link")
        }

        Button {
            guard canCreateProject()
            else { return }
            isPastePresented = true
        } label: {
            Label("Add Text", systemImage: "doc.on.clipboard")
        }
    }

    @ViewBuilder
    private func projectMenu(_ entry: LibraryModel.Entry) -> some View {
        Button {
            infoTarget = entry
        } label: {
            Label("Project Info", systemImage: "info.circle")
        }

        Button {
            beginRename(entry)
        } label: {
            Label("Rename", systemImage: "pencil")
        }

        Divider()

        Button(role: .destructive) {
            deleteTarget = entry
        } label: {
            Label("Delete Project", systemImage: "trash")
        }
    }

    private var documentTypes: [UTType] {
        let extensions = [
            "txt", "text",
            "md", "markdown", "mdown", "mkd",
            "srt", "vtt", "webvtt",
            "rtf",
            "html", "htm",
            "docx", "odt", "pptx",
        ]
        let resolved = extensions.compactMap {
            UTType(filenameExtension: $0)
        }
        return resolved.isEmpty ? [.data] : resolved
    }

    private func canCreateProject() -> Bool {
        !model.isImporting
    }

    private func presentFileImporter(types: [UTType]) {
        allowedContentTypes = types
        isFileImporterPresented = true
    }

    private func beginRename(_ entry: LibraryModel.Entry) {
        renameTarget = entry
        renameText = entry.snapshot.title
    }

    private func startFileImport(_ url: URL) {
        guard canCreateProject() else { return }

        Task {
            _ = await model.importFile(url)
        }
    }

    private func startPasteImport(
        text: String,
        title: String
    ) {
        guard canCreateProject() else { return }

        Task {
            let imported = await model.importPaste(
                text: text,
                suggestedTitle: title
            )
            if imported && pasteDraft.text == text && pasteDraft.title == title {
                pasteDraft = PasteDraft()
            }
        }
    }
}

private enum LibrarySourceFilter: String, CaseIterable, Identifiable {
    case all, epub, pdf, articles, documents, text

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All"
        case .epub: "EPUB"
        case .pdf: "PDF"
        case .articles: "Articles"
        case .documents: "Documents"
        case .text: "Text"
        }
    }

    func matches(_ source: ProjectSourceType) -> Bool {
        switch self {
        case .all: true
        case .epub: source == .epub
        case .pdf: source == .pdf
        case .articles: source == .article
        case .documents: source == .document
        case .text: source == .paste
        }
    }
}

private struct LibraryProjectRow: View {
    let entry: LibraryModel.Entry

    var body: some View {
        HStack(spacing: 14) {
            ProjectArtworkView(
                url: entry.artworkURL,
                sourceType: entry.snapshot.sourceType,
                width: 52,
                height: 70
            )

            VStack(alignment: .leading, spacing: 5) {
                Text(entry.snapshot.title)
                    .font(.headline)
                    .lineLimit(2)

                if let author = entry.snapshot.author {
                    Text(author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    Text(ReadAloudDisplay.sourceType(entry.snapshot.sourceType))
                    if entry.snapshot.projectProgress > 0 {
                        Text("·")
                        Text(
                            entry.snapshot.projectProgress,
                            format: .percent.precision(.fractionLength(0))
                        )
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

}

private struct LibraryIssuesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let issues: [ProjectCatalogIssue]

    var body: some View {
        NavigationStack {
            List(issues, id: \.packageName) { issue in
                VStack(alignment: .leading, spacing: 5) {
                    Text(issue.packageName)
                        .font(.headline)
                    Text(issue.message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 3)
            }
            .readAloudThemeSurface()
            .navigationTitle("Library Issues")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct ProjectInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    let entry: LibraryModel.Entry

    var body: some View {
        NavigationStack {
            ReadAloudThemedList {
                Section {
                    HStack(alignment: .top, spacing: 16) {
                        ProjectArtworkView(
                            url: entry.artworkURL,
                            sourceType: entry.snapshot.sourceType,
                            width: 72,
                            height: 96
                        )
                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.snapshot.title)
                                .font(.headline)
                            if let author = entry.snapshot.author {
                                Text(author)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Project") {
                    LabeledContent(
                        "Type",
                        value: ReadAloudDisplay.sourceType(entry.snapshot.sourceType)
                    )
                    LabeledContent {
                        Text(
                            entry.snapshot.projectProgress,
                            format: .percent.precision(.fractionLength(0))
                        )
                    } label: {
                        Text("Progress")
                    }
                    if let url = entry.snapshot.originalURL {
                        LabeledContent("Website") {
                            Link(url.host ?? "Open Original", destination: url)
                                .lineLimit(1)
                        }
                    }
                    if let site = entry.snapshot.siteName {
                        LabeledContent("Site", value: site)
                    }
                    if let language = entry.snapshot.language {
                        LabeledContent("Language", value: language)
                    }
                    if let published = entry.snapshot.publishedTime {
                        LabeledContent("Published", value: published)
                    }
                    LabeledContent {
                        Text(entry.snapshot.createdAt, format: .dateTime)
                    } label: {
                        Text("Added")
                    }
                    LabeledContent {
                        Text(entry.snapshot.updatedAt, format: .dateTime)
                    } label: {
                        Text("Updated")
                    }
                }
            }
            .readAloudThemeSurface()
            .navigationTitle("Project Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

}

private struct PasteDraft {
    var title = ""
    var text = ""
}

private struct PasteTextSheet: View {
    @Binding var draft: PasteDraft
    let onCancel: () -> Void
    let onImport: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Optional title", text: $draft.title)
                }

                Section("Text") {
                    TextEditor(text: $draft.text)
                        .frame(minHeight: 240)
                }
            }
            .readAloudThemeSurface()
            .navigationTitle("Add Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add to Library", action: onImport)
                        .disabled(
                            draft.text.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).isEmpty
                        )
                }
            }
        }
    }
}

private struct FromURLSheet: View {
    @Binding var urlText: String
    let onCancel: () -> Void
    let onImport: (URL) -> Void

    private var validURL: URL? {
        let value = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host != nil,
              url.user == nil,
              url.password == nil else { return nil }
        return url
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Paste article URL", text: $urlText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.URL)
                } header: {
                    Text("Article URL")
                } footer: {
                    Text("Public articles are saved for offline reading. Sites requiring login or JavaScript may not be supported.")
                }
            }
            .readAloudThemeSurface()
            .navigationTitle("Add Web Article")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add to Library") {
                        guard let url = validURL else { return }
                        onImport(url)
                    }
                    .disabled(validURL == nil)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct ImportProgressSheet: View {
    let progress: ReadAloudImportProgress
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "books.vertical")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)

                VStack(spacing: 8) {
                    Text("Importing")
                        .font(.title2.bold())
                    Text(stageLabel(progress))
                        .foregroundStyle(.secondary)
                }

                if let value = progress.fractionCompleted {
                    ProgressView(value: value)
                        .padding(.horizontal, 32)
                } else {
                    ProgressView()
                }

                if let detail = progress.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Spacer()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func stageLabel(
        _ progress: ReadAloudImportProgress
    ) -> String {
        switch progress.stage {
        case .preparing: "Preparing…"
        case .extracting: "Extracting content…"
        case .normalizing: "Organizing content…"
        case .persisting: "Adding to Library…"
        case .finished: "Finishing…"
        }
    }
}

private enum LibraryProDestination: String, Identifiable {
    case paywall
    case celebration

    var id: String { rawValue }
}

