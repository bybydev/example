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
    @State private var renameTarget: LibraryModel.Entry?
    @State private var renameText = ""
    @State private var deleteTarget: LibraryModel.Entry?
    @State private var infoTarget: LibraryModel.Entry?
    @State private var isIssuesPresented = false
    @State private var pendingPasteImport: PasteDraft?
    @State private var paywallPresented = false

    var body: some View {
        @Bindable var model = model

        Group {
            if model.isLoading && !model.didLoad {
                ProgressView("Loading Library…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.entries.isEmpty
                        && model.catalogIssues.isEmpty
                        && model.searchText.isEmpty {
                emptyState
            } else {
                libraryContent
            }
        }
        .readAloudThemeSurface()
        .navigationTitle("Library")
        .searchable(
            text: $model.searchText,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Search Library"
        )
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                sortMenu
                NavigationLink {
                    SettingsView()
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
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

                if model.didLoad {
                    HStack {
                        Spacer(minLength: 0)
                        floatingAddMenu
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
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
            isPresented:
                $paywallPresented
        ) {
            ReadAloudProPaywall()
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
                    if await model.delete(projectID: target.id) {
                        runtimeManager.forget(
                            projectID: target.id
                        )
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

    private var libraryContent: some View {
        ReadAloudThemedList {
            if let entry = model.continueListening {
                Section("Continue Listening") {
                    NavigationLink {
                        ProjectReaderRuntimeHost(
                            projectID: entry.id,
                            initialItemID: nil,
                            initialTitle: entry.snapshot.title,
                            onProjectChanged: {
                                Task {
                                    await model.refresh()
                                }
                            }
                        )
                    } label: {
                        ContinueListeningCard(entry: entry)
                    }
                    .buttonStyle(.plain)
                }
            }

            if !model.catalogIssues.isEmpty {
                Section {
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
                }
            }

            Section {
                if model.filteredEntries.isEmpty {
                    ContentUnavailableView(
                        "No Results",
                        systemImage: "magnifyingglass",
                        description: Text(
                            "No projects match “\(model.searchText)”."
                        )
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(model.filteredEntries) { entry in
                        NavigationLink {
                            ProjectDetailRuntimeHost(
                                projectID: entry.id,
                                initialTitle: entry.snapshot.title,
                                onProjectChanged: {
                                    Task {
                                        await model.refresh()
                                    }
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
                    }
                }
            } header: {
                Text("Your Library")
            }
        }
        .listStyle(.insetGrouped)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Your Library Is Empty", systemImage: "books.vertical")
        } description: {
            Text("Add a book, PDF, or document and listen completely on your device.")
        }
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
                .font(.title2.weight(.semibold))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .shadow(color: .black.opacity(0.16), radius: 10, x: 0, y: 4)
        .accessibilityLabel("Add to Library")
        .accessibilityHint("Import a book, PDF, document, or pasted text")
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
            Label("Import EPUB", systemImage: "book.closed")
        }

        Button {
            guard canCreateProject()
            else { return }
            presentFileImporter(types: [.pdf])
        } label: {
            Label("Import PDF", systemImage: "doc.richtext")
        }

        Button {
            guard canCreateProject()
            else { return }
            presentFileImporter(types: documentTypes)
        } label: {
            Label("Import Document", systemImage: "doc.text")
        }

        Button {
            guard canCreateProject()
            else { return }
            isPastePresented = true
        } label: {
            Label("Paste Text", systemImage: "doc.on.clipboard")
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

    private func canCreateProject()
        -> Bool
    {
        guard !model.isImporting else { return false }

        let allowed =
            ReadAloudAccessPolicy
                .canCreateProject(
                    existingProjectCount:
                        model.entries.count,
                    hasPro:
                        purchases.hasPro
                )

        if !allowed {
            paywallPresented = true
        }

        return allowed
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
            _ = await model.importFile(
                url,
                hasPro: purchases.hasPro
            )
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
                suggestedTitle: title,
                hasPro: purchases.hasPro
            )
            if imported && pasteDraft.text == text && pasteDraft.title == title {
                pasteDraft = PasteDraft()
            }
        }
    }
}

private struct ContinueListeningCard: View {
    let entry: LibraryModel.Entry

    var body: some View {
        HStack(spacing: 14) {
            ProjectArtworkView(
                url: entry.artworkURL,
                sourceType: entry.snapshot.sourceType,
                width: 72,
                height: 96
            )

            VStack(alignment: .leading, spacing: 7) {
                Text(entry.snapshot.title)
                    .font(.headline)
                    .lineLimit(2)

                if let author = entry.snapshot.author {
                    Text(author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                ProgressView(value: entry.snapshot.projectProgress)

                Text(entry.snapshot.projectProgress, format: .percent.precision(.fractionLength(0)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            Image(systemName: "play.fill")
                .font(.title3)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 6)
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
            .navigationTitle("Paste Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: onImport)
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
