import Foundation
import SwiftUI

struct ProjectDetailRuntimeHost: View {
    @Environment(ProjectRuntimeManager.self) private var runtimeManager
    @State private var runtime: ProjectRuntime?
    @State private var errorMessage: String?
    @State private var isLoading = true

    let projectID: UUID
    let initialTitle: String
    let onProjectChanged: () -> Void

    init(
        projectID: UUID,
        initialTitle: String,
        onProjectChanged: @escaping () -> Void = {}
    ) {
        self.projectID = projectID
        self.initialTitle = initialTitle
        self.onProjectChanged = onProjectChanged
    }

    var body: some View {
        Group {
            if let runtime {
                ProjectDetailView(
                    runtime: runtime,
                    initialTitle: initialTitle,
                    onProjectChanged: onProjectChanged
                )
            } else if isLoading {
                ProgressView("Opening Project…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "Project Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(
                        errorMessage ?? "This project could not be opened."
                    )
                )
            }
        }
        .navigationTitle(runtime?.project?.title ?? initialTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: projectID) {
            if let runtime {
                runtimeManager.makeActive(runtime)
                return
            }

            isLoading = true
            defer { isLoading = false }

            do {
                runtime = try await runtimeManager.activate(
                    projectID: projectID
                )
                errorMessage = nil
            } catch {
                errorMessage = Self.message(for: error)
            }
        }
    }

    nonisolated private static func message(
        for error: Error
    ) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}

struct ProjectDetailView: View {
    private struct ItemTarget: Identifiable {
        let id: UUID
        let title: String
    }

    private struct ReaderTarget {
        let itemID: UUID
        let title: String
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(ProjectRuntimeManager.self) private var runtimeManager
    @State private var model: ProjectDetailModel
    @State private var projectVoicePresented = false
    @State private var projectSpeedPresented = false
    @State private var itemVoiceTarget: ItemTarget?
    @State private var itemSpeedTarget: ItemTarget?
    @State private var itemInfoTarget: ItemTarget?
    @State private var readerTarget: ReaderTarget?
    @State private var projectInfoPresented = false
    @State private var offlinePresented = false
    @State private var storagePresented = false
    @State private var renamePresented = false
    @State private var renameText = ""
    @State private var deletePresented = false

    let initialTitle: String
    let onProjectChanged: () -> Void

    init(
        runtime: ProjectRuntime,
        initialTitle: String,
        onProjectChanged: @escaping () -> Void = {}
    ) {
        self.initialTitle = initialTitle
        self.onProjectChanged = onProjectChanged
        _model = State(
            initialValue: ProjectDetailModel(runtime: runtime)
        )
    }

    var body: some View {
        Group {
            if model.isLoading && !model.didLoad {
                ProgressView("Loading Project…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let project = model.project {
                projectContent(project)
            } else {
                ContentUnavailableView(
                    "Project Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(
                        model.errorMessage ?? "This project could not be opened."
                    )
                )
            }
        }
        .navigationTitle(model.project?.title ?? initialTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                projectMenu
            }
        }
        .task {
            runtimeManager.makeActive(model.runtime)
            await model.loadIfNeeded()
        }
        .refreshable {
            await model.refresh()
        }
        .navigationDestination(
            isPresented: Binding(
                get: { readerTarget != nil },
                set: { presented in
                    if !presented {
                        readerTarget = nil
                    }
                }
            )
        ) {
            if let readerTarget {
                ReaderPlaceholderView(
                    runtime: model.runtime,
                    itemID: readerTarget.itemID,
                    title: readerTarget.title
                )
            }
        }
        .sheet(isPresented: $projectVoicePresented) {
            ProjectVoicePicker(
                model: model,
                onChanged: notifyProjectChanged
            )
        }
        .sheet(isPresented: $projectSpeedPresented) {
            ProjectSpeedPicker(
                model: model,
                onChanged: notifyProjectChanged
            )
        }
        .sheet(item: $itemVoiceTarget) { target in
            ItemVoicePicker(
                model: model,
                itemID: target.id,
                onChanged: notifyProjectChanged
            )
        }
        .sheet(item: $itemSpeedTarget) { target in
            ItemSpeedPicker(
                model: model,
                itemID: target.id,
                onChanged: notifyProjectChanged
            )
        }
        .sheet(item: $itemInfoTarget) { target in
            if let entry = model.itemEntry(target.id) {
                ProjectItemInfoSheet(entry: entry)
            }
        }
        .sheet(isPresented: $projectInfoPresented) {
            if let project = model.project {
                ProjectDetailInfoSheet(
                    project: project,
                    itemCount: model.items.count,
                    readyOfflineCount: model.readyOfflineCount
                )
            }
        }
        .sheet(isPresented: $offlinePresented) {
            OfflineAudioSheet(
                model: model,
                onChanged: notifyProjectChanged
            )
        }
        .sheet(isPresented: $storagePresented) {
            ProjectStorageSheet(model: model)
        }
        .alert(
            "Rename Project",
            isPresented: $renamePresented
        ) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                Task {
                    if await model.rename(to: renameText) {
                        notifyProjectChanged()
                    }
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
            isPresented: $deletePresented,
            titleVisibility: .visible
        ) {
            Button("Delete Project", role: .destructive) {
                Task {
                    if await model.deleteProject() {
                        runtimeManager.forget(
                            projectID: model.projectID
                        )
                        notifyProjectChanged()
                        dismiss()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The project and its generated audio will be removed from this device.")
        }
        .alert(
            "Project Error",
            isPresented: Binding(
                get: { model.errorMessage != nil && model.project != nil },
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

    private func projectContent(
        _ project: ProjectDocument
    ) -> some View {
        List {
            Section {
                projectHeader(project)
                    .listRowInsets(
                        EdgeInsets(
                            top: 18,
                            leading: 18,
                            bottom: 18,
                            trailing: 18
                        )
                    )
            }
            .listRowBackground(Color.clear)

            Section("Narration") {
                Button {
                    projectVoicePresented = true
                } label: {
                    LabeledContent(
                        "Voice",
                        value: projectVoiceLabel(project)
                    )
                }
                .foregroundStyle(.primary)

                Button {
                    projectSpeedPresented = true
                } label: {
                    LabeledContent(
                        "Speed",
                        value: projectSpeedLabel(project)
                    )
                }
                .foregroundStyle(.primary)
            }

            Section {
                ForEach(model.items) { entry in
                    Button {
                        readerTarget = ReaderTarget(
                            itemID: entry.id,
                            title: entry.item.title
                        )
                    } label: {
                        ProjectItemRow(
                            entry: entry,
                            isCurrent: model.currentItemID == entry.id
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        itemMenu(entry)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(
                            entry.generationStatus.state == .readyOffline
                                ? "Regenerate"
                                : "Generate"
                        ) {
                            generate(
                                entry,
                                regenerate:
                                    entry.generationStatus.state
                                        == .readyOffline
                            )
                        }
                        .tint(.accentColor)
                    }
                }
            } header: {
                Text(itemsSectionTitle(project))
            }
        }
        .listStyle(.insetGrouped)
    }

    private func projectHeader(
        _ project: ProjectDocument
    ) -> some View {
        VStack(spacing: 14) {
            ProjectArtworkView(
                url: model.artworkURL,
                sourceType: project.source.type,
                width: 116,
                height: 154
            )

            VStack(spacing: 4) {
                Text(project.title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)

                if let author = project.author {
                    Text(author)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            if let playback = project.playback {
                VStack(spacing: 5) {
                    ProgressView(value: playback.projectProgress)
                    Text(
                        playback.projectProgress,
                        format: .percent.precision(.fractionLength(0))
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if let itemID = model.continueItemID,
               let entry = model.itemEntry(itemID) {
                Button {
                    readerTarget = ReaderTarget(
                        itemID: itemID,
                        title: entry.item.title
                    )
                } label: {
                    Label(
                        project.playback == nil
                            ? "Start Listening"
                            : "Continue Listening",
                        systemImage: "play.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }

            if !model.items.isEmpty {
                HStack(spacing: 16) {
                    Label(
                        "\(model.readyOfflineCount) Ready",
                        systemImage: "checkmark.circle"
                    )
                    if model.waitingCount + model.generatingCount > 0 {
                        Label(
                            "\(model.waitingCount + model.generatingCount) Pending",
                            systemImage: "clock"
                        )
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func itemMenu(
        _ entry: ProjectDetailModel.ItemEntry
    ) -> some View {
        Button {
            readerTarget = ReaderTarget(
                itemID: entry.id,
                title: entry.item.title
            )
        } label: {
            Label("Open Reader", systemImage: "play.fill")
        }

        if entry.generationStatus.state != .readyOffline {
            Button {
                generate(entry, regenerate: false)
            } label: {
                Label(
                    "Generate Offline",
                    systemImage: "arrow.down.circle"
                )
            }
        }

        if entry.generationStatus.state != .notGenerated {
            Button {
                generate(entry, regenerate: true)
            } label: {
                Label("Regenerate", systemImage: "arrow.clockwise")
            }
        }

        Divider()

        Button {
            itemVoiceTarget = ItemTarget(
                id: entry.id,
                title: entry.item.title
            )
        } label: {
            Label("Voice…", systemImage: "waveform")
        }

        Button {
            itemSpeedTarget = ItemTarget(
                id: entry.id,
                title: entry.item.title
            )
        } label: {
            Label("Speed…", systemImage: "speedometer")
        }

        Button {
            itemInfoTarget = ItemTarget(
                id: entry.id,
                title: entry.item.title
            )
        } label: {
            Label("Chapter Info", systemImage: "info.circle")
        }

        if entry.generationStatus.audioBytes != nil
            || entry.generationStatus.state == .readyOffline
            || entry.generationStatus.state == .needsAttention {
            Divider()
            Button(role: .destructive) {
                Task {
                    if await model.clearGeneratedAudio(itemID: entry.id) {
                        notifyProjectChanged()
                    }
                }
            } label: {
                Label(
                    "Clear Generated Audio",
                    systemImage: "trash"
                )
            }
        }
    }

    private var projectMenu: some View {
        Menu {
            Button {
                projectInfoPresented = true
            } label: {
                Label("Project Info", systemImage: "info.circle")
            }

            Button {
                Task {
                    if await model.queueRemaining() {
                        notifyProjectChanged()
                    }
                }
            } label: {
                Label(
                    "Generate Remaining",
                    systemImage: "arrow.down.circle"
                )
            }

            Button {
                offlinePresented = true
            } label: {
                Label(
                    "Manage Offline Audio",
                    systemImage: "internaldrive"
                )
            }

            Button {
                renameText = model.project?.title ?? initialTitle
                renamePresented = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            Button {
                storagePresented = true
            } label: {
                Label("Storage", systemImage: "externaldrive")
            }

            Divider()

            Button(role: .destructive) {
                deletePresented = true
            } label: {
                Label("Delete Project", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Project Actions")
        .disabled(model.project == nil)
    }

    private func generate(
        _ entry: ProjectDetailModel.ItemEntry,
        regenerate: Bool
    ) {
        Task {
            if await model.queueGeneration(
                itemID: entry.id,
                regenerate: regenerate
            ) {
                notifyProjectChanged()
            }
        }
    }

    private func notifyProjectChanged() {
        onProjectChanged()
    }

    private func projectVoiceLabel(
        _ project: ProjectDocument
    ) -> String {
        let resolved = model.resolvedProjectSettings
        let name = ReadAloudNarrationCatalog.voiceName(
            resolved.voiceID
        )
        return project.settings.voiceID == nil
            ? "App Default · \(name)"
            : name
    }

    private func projectSpeedLabel(
        _ project: ProjectDocument
    ) -> String {
        let value = speedLabel(model.resolvedProjectSettings.speed)
        return project.settings.speed == nil
            ? "App Default · \(value)"
            : value
    }

    private func itemsSectionTitle(
        _ project: ProjectDocument
    ) -> String {
        switch project.source.type {
        case .epub:
            return "Chapters"
        case .pdf, .document, .paste:
            return "Sections"
        }
    }

    private func speedLabel(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1))) + "×"
    }
}

private struct ProjectItemRow: View {
    let entry: ProjectDetailModel.ItemEntry
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: statusIcon)
                .frame(width: 22)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.item.title)
                    .font(.body.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(statusLabel)
                    Text("·")
                    Text(
                        ReadAloudNarrationCatalog.voiceName(
                            entry.resolved.voiceID
                        )
                    )
                    Text("·")
                    Text(
                        entry.resolved.speed.formatted(
                            .number.precision(.fractionLength(1))
                        ) + "×"
                    )
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            if isCurrent {
                Image(systemName: "bookmark.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Current chapter")
            }
        }
        .padding(.vertical, 3)
    }

    private var statusLabel: String {
        switch entry.generationStatus.state {
        case .readyOffline: "Ready Offline"
        case .generating: "Generating"
        case .waiting: "Waiting"
        case .notGenerated: "Not Generated"
        case .needsAttention: "Needs Attention"
        }
    }

    private var statusIcon: String {
        switch entry.generationStatus.state {
        case .readyOffline: "checkmark.circle.fill"
        case .generating: "waveform"
        case .waiting: "clock"
        case .notGenerated: "circle"
        case .needsAttention: "exclamationmark.triangle"
        }
    }


}

private struct ReaderPlaceholderView: View {
    let runtime: ProjectRuntime
    let itemID: UUID
    let title: String

    var body: some View {
        let currentTitle =
            runtime.itemState(itemID)?.item.title ?? title

        ContentUnavailableView {
            Label(currentTitle, systemImage: "text.book.closed")
        } description: {
            Text("Reader implementation arrives in Phase 6.")
        }
        .navigationTitle(currentTitle)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ProjectDetailInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    let project: ProjectDocument
    let itemCount: Int
    let readyOfflineCount: Int

    var body: some View {
        NavigationStack {
            List {
                Section("Project") {
                    LabeledContent("Title", value: project.title)
                    if let author = project.author {
                        LabeledContent("Author", value: author)
                    }
                    LabeledContent(
                        "Source",
                        value: sourceLabel(project.source.type)
                    )
                    LabeledContent(
                        "Items",
                        value: String(itemCount)
                    )
                    LabeledContent(
                        "Ready Offline",
                        value: "\(readyOfflineCount) / \(itemCount)"
                    )
                }

                Section("Original Source") {
                    LabeledContent(
                        "File",
                        value: project.source.originalFileName
                    )
                    LabeledContent {
                        Text(project.createdAt, format: .dateTime)
                    } label: {
                        Text("Added")
                    }
                    LabeledContent {
                        Text(project.updatedAt, format: .dateTime)
                    } label: {
                        Text("Updated")
                    }
                }
            }
            .navigationTitle("Project Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func sourceLabel(
        _ type: ProjectSourceType
    ) -> String {
        switch type {
        case .epub: "EPUB"
        case .pdf: "PDF"
        case .document: "Document"
        case .paste: "Text"
        }
    }
}

private struct ProjectItemInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    let entry: ProjectDetailModel.ItemEntry

    var body: some View {
        NavigationStack {
            List {
                Section("Section") {
                    LabeledContent(
                        "Title",
                        value: entry.item.title
                    )
                    LabeledContent(
                        "Order",
                        value: String(entry.item.order + 1)
                    )
                    LabeledContent(
                        "Status",
                        value: statusLabel
                    )
                }

                Section("Narration") {
                    LabeledContent(
                        "Voice",
                        value: ReadAloudNarrationCatalog.voiceName(
                            entry.resolved.voiceID
                        )
                    )
                    LabeledContent(
                        "Speed",
                        value:
                            entry.resolved.speed.formatted(
                                .number.precision(.fractionLength(1))
                            ) + "×"
                    )
                    LabeledContent(
                        "Voice Mode",
                        value: entry.item.settings.voice.mode == .inherit
                            ? "Project Default"
                            : "Custom"
                    )
                    LabeledContent(
                        "Speed Mode",
                        value: entry.item.settings.speed.mode == .inherit
                            ? "Project Default"
                            : "Custom"
                    )
                }

                Section("Source") {
                    LabeledContent(
                        "Locator",
                        value: entry.item.sourceLocator.value
                    )
                    LabeledContent(
                        "Characters",
                        value: String(entry.item.text.count)
                    )
                }
            }
            .navigationTitle("Chapter Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var statusLabel: String {
        switch entry.generationStatus.state {
        case .readyOffline: "Ready Offline"
        case .generating: "Generating"
        case .waiting: "Waiting"
        case .notGenerated: "Not Generated"
        case .needsAttention: "Needs Attention"
        }
    }
}

private struct OfflineAudioSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: ProjectDetailModel
    let onChanged: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Summary") {
                    LabeledContent(
                        "Ready",
                        value: "\(model.readyOfflineCount) / \(model.items.count)"
                    )
                    if model.generatingCount > 0 {
                        LabeledContent(
                            "Generating",
                            value: String(model.generatingCount)
                        )
                    }
                    if model.waitingCount > 0 {
                        LabeledContent(
                            "Waiting",
                            value: String(model.waitingCount)
                        )
                    }
                    if model.needsAttentionCount > 0 {
                        LabeledContent(
                            "Needs Attention",
                            value: String(model.needsAttentionCount)
                        )
                    }
                }

                Section("Items") {
                    ForEach(model.items) { entry in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.item.title)
                                Text(statusLabel(entry))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let bytes = entry.generationStatus.audioBytes {
                                Text(
                                    ByteCountFormatter.string(
                                        fromByteCount: bytes,
                                        countStyle: .file
                                    )
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .contextMenu {
                            Button(
                                entry.generationStatus.state == .readyOffline
                                    ? "Regenerate"
                                    : "Generate Offline"
                            ) {
                                Task {
                                    if await model.queueGeneration(
                                        itemID: entry.id,
                                        regenerate:
                                            entry.generationStatus.state
                                                == .readyOffline
                                    ) {
                                        onChanged()
                                    }
                                }
                            }

                            if entry.generationStatus.audioBytes != nil
                                || entry.generationStatus.state == .readyOffline
                                || entry.generationStatus.state
                                    == .needsAttention {
                                Button(
                                    "Clear Generated Audio",
                                    role: .destructive
                                ) {
                                    Task {
                                        if await model.clearGeneratedAudio(
                                            itemID: entry.id
                                        ) {
                                            onChanged()
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                Section {
                    Button {
                        Task {
                            if await model.queueRemaining() {
                                onChanged()
                            }
                        }
                    } label: {
                        Label(
                            "Generate Remaining",
                            systemImage: "arrow.down.circle"
                        )
                    }

                    if model.generatedAudioBytes > 0 {
                        Button(role: .destructive) {
                            Task {
                                if await model.clearAllGeneratedAudio() {
                                    onChanged()
                                }
                            }
                        } label: {
                            Label(
                                "Clear Generated Audio",
                                systemImage: "trash"
                            )
                        }
                    }
                }
            }
            .navigationTitle("Offline Audio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func statusLabel(
        _ entry: ProjectDetailModel.ItemEntry
    ) -> String {
        switch entry.generationStatus.state {
        case .readyOffline: "Ready Offline"
        case .generating: "Generating"
        case .waiting: "Waiting"
        case .notGenerated: "Not Generated"
        case .needsAttention: "Needs Attention"
        }
    }
}

private struct ProjectStorageSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: ProjectDetailModel

    var body: some View {
        NavigationStack {
            List {
                Section("Generated Audio") {
                    LabeledContent(
                        "Size",
                        value: ByteCountFormatter.string(
                            fromByteCount: model.generatedAudioBytes,
                            countStyle: .file
                        )
                    )
                    LabeledContent(
                        "Ready Offline",
                        value: "\(model.readyOfflineCount) / \(model.items.count)"
                    )
                }

                Section {
                    Text("Detailed source/cache storage management is handled in the dedicated storage phase. This summary reports finalized item audio known to the project.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Storage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
