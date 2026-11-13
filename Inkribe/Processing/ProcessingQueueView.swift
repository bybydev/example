import AppFoundation
import JobQueue
import SwiftUI

private enum QueueScope: String, CaseIterable, Identifiable {
    case all = "All", pending = "Pending", processing = "Processing", done = "Done", failed = "Failed"
    var id: Self { self }
    var icon: String {
        switch self {
        case .all: "rectangle.stack.fill"
        case .pending: "clock"
        case .processing: "waveform"
        case .done: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        }
    }
    func includes(_ entry: ProcessingEntry) -> Bool {
        switch self {
        case .all: true
        case .pending: entry.pending
        case .processing: entry.processing
        case .done: entry.record.status == .completed
        case .failed: entry.failed
        }
    }
}

private enum QueueSort: String, CaseIterable, Identifiable {
    case createdAt = "Date Created", project = "Project Name"
    var id: Self { self }
}

struct ProcessingQueueSheet: View {
    @Environment(ProjectsModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ProcessingQueueView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }.disabled(model.exports.hasUserDelivery)
                    }
                }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(model.exports.hasUserDelivery)
    }
}

/// Display filters never change execution order. Rows hand off to project tools;
/// full job inspection and housekeeping remain available from their context menu.
struct ProcessingQueueView: View {
    @Environment(ProjectsModel.self) private var model
    @Environment(\.appFoundationTheme) private var theme
    @Environment(\.queueProjectNavigation) private var openProject
    @State private var scope = QueueScope.all
    @State private var kind: ProcessingKind?
    @State private var search = ""
    @State private var sort = QueueSort.createdAt
    @State private var ascending = false
    @State private var details: ProcessingJobKey?
    @State private var showingRetained = false
    @State private var retainedProjectRoute: QueueProjectRoute?
    @State private var isOpeningProject = false
    @State private var error: String?
    @State private var pendingAction: ProcessingAction?
    @State private var actionKeys: [ProcessingJobKey] = []
    @State private var confirming = false
    @State private var runningAction = false
    private var processing: ProcessingCoordinator { model.processing }

    private var matching: [ProcessingEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return processing.entries.filter { entry in
            (kind == nil || kind == entry.id.kind) &&
                (query.isEmpty || title(entry).localizedStandardContains(query) ||
                 detail(entry).localizedStandardContains(query) ||
                 entry.id.kind.title.localizedStandardContains(query) ||
                 entry.record.error?.localizedStandardContains(query) == true)
        }
    }
    private var visible: [ProcessingEntry] {
        matching.filter { scope.includes($0) }.sorted { a, b in
            switch sort {
            case .createdAt:
                if a.record.createdAt != b.record.createdAt {
                    return ascending ? a.record.createdAt < b.record.createdAt : a.record.createdAt > b.record.createdAt
                }
            case .project:
                let order = title(a).localizedStandardCompare(title(b))
                if order != .orderedSame { return ascending ? order == .orderedAscending : order == .orderedDescending }
            }
            return a.record.id.uuidString < b.record.id.uuidString
        }
    }

    var body: some View {
        queueList
            .navigationTitle("Queue")
            .navigationSubtitle("\(processing.entries.count) jobs · \(processing.processingCount) processing · \(processing.pendingCount) pending")
            .navigationBarTitleDisplayMode(.large)
            .themedSurface()
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search jobs")
            .toolbar { queueToolbar }
            .queueJobDetails($details)
            .sheet(isPresented: $showingRetained, onDismiss: finishRetainedNavigation) { retainedSheet }
            .onAppear { isOpeningProject = false }
            .task { await processing.start(); await model.exports.refreshArtifacts() }
            .refreshable { await model.exports.refreshArtifacts(); await model.refreshStorage() }
            .alert(confirmationTitle, isPresented: $confirming) {
                Button(confirmationTitle, role: .destructive) {
                    if let pendingAction { run(pendingAction, keys: actionKeys) }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text(confirmationMessage)
            }
    }

    private var retainedSheet: some View {
        NavigationStack {
            RetainedExportsView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showingRetained = false }.disabled(model.exports.hasUserDelivery)
                    }
                }
        }
        .environment(\.queueProjectNavigation, QueueProjectNavigation { route in
            guard retainedProjectRoute == nil, !model.exports.hasUserDelivery else { return }
            retainedProjectRoute = route
            showingRetained = false
        })
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(model.exports.hasUserDelivery)
    }

    private var queueList: some View {
        List {
            notices
            Section {
                scopeStrip
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 14, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            Section {
                if visible.isEmpty {
                    ContentUnavailableView(processing.entries.isEmpty ? "Queue Empty" : "No Matches",
                        systemImage: "tray", description: Text(processing.entries.isEmpty ?
                            "Transcribe a project or create an export to get started." : "Try changing the search, status or job type."))
                        .frame(maxWidth: .infinity, minHeight: 220)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(visible) { entry in jobRow(entry) }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .listSectionSpacing(8)
        .scrollDismissesKeyboard(.interactively)
    }

    private var scopeStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(QueueScope.allCases) { value in
                    Button { scope = value } label: {
                        LibraryScopePill(title: value.rawValue, systemImage: value.icon,
                            count: matching.filter { value.includes($0) }.count, isSelected: scope == value)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(scope == value ? .isSelected : [])
                }
            }.padding(.trailing, 16)
        }
        .scrollIndicators(.hidden)
        .accessibilityLabel("Job status")
    }

    private func jobRow(_ entry: ProcessingEntry) -> some View {
        HStack(spacing: 4) {
            Button { details = entry.id } label: {
                ProcessingQueueRow(entry: entry, title: title(entry), detail: detail(entry),
                    paused: processing.queue(for: entry.id.kind)?.isPaused == true)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens job details")
            if hasRowActions(entry.id) {
                Menu { rowActions(entry.id) } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                        .accessibilityLabel("Job actions")
                }
            }
        }
        .disabled(isOpeningProject || model.exports.hasUserDelivery)
        .contextMenu { rowActions(entry.id) }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if processing.can(.retry, entry.id) {
                Button("Retry", systemImage: "arrow.clockwise") { run(.retry, keys: [entry.id]) }.tint(.blue)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if processing.can(.cancel, entry.id) {
                Button("Cancel", systemImage: "xmark.circle", role: .destructive) { confirm(.cancel, keys: [entry.id]) }
            }
        }
        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(theme.borderColor)
    }

    private func hasRowActions(_ key: ProcessingJobKey) -> Bool {
        model.queueProjectID(for: key) != nil ||
            processing.can(.retry, key) ||
            processing.can(.cancel, key) ||
            processing.can(.discardExport, key)
    }

    @ViewBuilder private func rowActions(_ key: ProcessingJobKey) -> some View {
        if model.queueProjectID(for: key) != nil {
            Button("Jump to Project", systemImage: "arrow.up.forward.app") { jumpToProject(key) }
        }
        if processing.can(.retry, key) { Button("Retry", systemImage: "arrow.clockwise") { run(.retry, keys: [key]) } }
        if processing.can(.cancel, key) {
            Button("Cancel Job", systemImage: "xmark.circle", role: .destructive) { confirm(.cancel, keys: [key]) }
        }
        if processing.can(.discardExport, key) {
            Button("Delete Local Export", systemImage: "trash", role: .destructive) { confirm(.discardExport, keys: [key]) }
        }
    }

    private var queueToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Picker("Sort By", selection: $sort) {
                    ForEach(QueueSort.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Order", selection: $ascending) {
                    Text("Ascending").tag(true)
                    Text("Descending").tag(false)
                }
            } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
            Menu {
                Picker("Job Type", selection: $kind) {
                    Text("All Types").tag(ProcessingKind?.none)
                    Text("Captions").tag(Optional(ProcessingKind.transcription))
                    Text("Exports").tag(Optional(ProcessingKind.export))
                }
                Divider()
                Button("Export Storage", systemImage: "archivebox") { showingRetained = true }
                if processing.lifecycle.needsResume || processing.activeCount > 0 {
                    Button(processing.lifecycle.needsResume ? "Resume Queue" : "Pause Queue",
                        systemImage: processing.lifecycle.needsResume ? "play.fill" : "pause.fill") {
                        do { try processing.setPaused(!processing.lifecycle.needsResume) }
                        catch { self.error = error.localizedDescription }
                    }.disabled(processing.lifecycle.error != nil)
                }
                Divider()
                Button("Retry Filtered Jobs", systemImage: "arrow.clockwise") { run(.retry, keys: visible.map(\.id)) }
                    .disabled(runningAction || !visible.contains { processing.can(.retry, $0.id) })
                Button("Cancel Filtered Jobs", systemImage: "xmark.circle", role: .destructive) {
                    confirm(.cancel, keys: visible.map(\.id))
                }.disabled(runningAction || !visible.contains { processing.can(.cancel, $0.id) })
                Button("Remove Finished Filtered Records", systemImage: "trash", role: .destructive) {
                    confirm(.removeRecord, keys: visible.map(\.id))
                }.disabled(runningAction || !visible.contains { processing.can(.removeRecord, $0.id) })
            } label: { Label("Queue Options", systemImage: "ellipsis") }
        }
    }

    @ViewBuilder private var notices: some View {
        if processing.lifecycle.userPaused {
            notice("Queue paused", message: "Resume from Queue options when you’re ready.", icon: "pause.circle.fill", tint: .orange)
        }
        ForEach(ProcessingKind.allCases) { kind in
            if let background = processing.continuedProcessing.notices[kind] {
                notice(kind == .transcription ? "Caption processing" : "Export processing",
                    message: background.message, icon: "arrow.up.forward.app", tint: .orange)
            }
        }
        if let issue = processing.lifecycle.error {
            notice("Processing unavailable", message: issue, icon: "exclamationmark.triangle.fill", tint: .red) {
                processing.retryControlStorage()
            }
        }
        if let issue = model.transcription.persistenceError {
            notice("Transcription storage needs attention", message: issue, icon: "exclamationmark.triangle.fill", tint: .red) {
                model.transcription.retryStorage()
            }
        }
        if let issue = model.exports.persistenceError {
            notice("Export storage needs attention", message: issue, icon: "exclamationmark.triangle.fill", tint: .red) {
                Task { await model.exports.retryStorage() }
            }
        }
        if let issue = model.exports.inventoryError {
            notice("Export files need attention", message: issue, icon: "exclamationmark.triangle.fill", tint: .orange) {
                Task { await model.exports.refreshArtifacts() }
            }
        }
        if let error { notice("Action could not finish", message: error, icon: "exclamationmark.circle", tint: .red) }
        if runningAction {
            ProgressView("Updating jobs…").listRowBackground(Color.clear).listRowSeparator(.hidden)
        }
    }

    private func notice(_ title: String, message: String, icon: String, tint: Color,
                        retry: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.subheadline.weight(.semibold)).foregroundStyle(tint)
            Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let retry { Button("Retry", action: retry).font(.subheadline.weight(.semibold)) }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 0, trailing: 16))
        .listRowBackground(Color.clear).listRowSeparator(.hidden)
    }

    private var confirmationTitle: String {
        let count = actionKeys.count
        switch pendingAction {
        case .cancel:
            return "Cancel \(count) \(count == 1 ? "job" : "jobs")?"
        case .discardExport:
            return "Delete \(count) \(count == 1 ? "local export" : "local exports")?"
        default:
            return "Remove \(count) \(count == 1 ? "record" : "records")?"
        }
    }
    private var confirmationMessage: String {
        switch pendingAction {
        case .cancel: "Saved captions and completed files are kept."
        case .discardExport:
            "Deletes only the selected exports' frozen inputs, results and queue records. Save or share the files first if you need a copy. Your projects and original media are kept."
        default:
            "Only finished records are removed. Captions and export files are kept. Find stored exports in Queue options → Export Storage."
        }
    }
    private func confirm(_ action: ProcessingAction, keys: [ProcessingJobKey]) {
        actionKeys = keys.filter { processing.can(action, $0) }
        guard !actionKeys.isEmpty else { return }
        pendingAction = action
        confirming = true
    }
    private func run(_ action: ProcessingAction, keys: [ProcessingJobKey]) {
        guard !runningAction else { return }
        runningAction = true; error = nil
        Task {
            let failures = await processing.performBulk(action, keys: keys)
            error = failures.isEmpty ? nil : failures.joined(separator: "\n\n")
            runningAction = false
            await model.refreshStorage()
        }
    }
    private func jumpToProject(_ key: ProcessingJobKey) {
        guard !isOpeningProject, !model.exports.hasUserDelivery,
              let route = model.queueProjectRoute(for: key) else { return }
        isOpeningProject = true
        openProject(route)
    }
    private func finishRetainedNavigation() {
        guard let route = retainedProjectRoute else { return }
        retainedProjectRoute = nil
        openProject(route)
    }
    private func title(_ entry: ProcessingEntry) -> String {
        let project = model.allProjects.first { $0.id == entry.projectID }
        let artifactTitle = entry.id.kind == .export ? model.exports.artifacts[entry.id.jobID]?.title : nil
        return project?.title ?? artifactTitle ?? entry.record.title ?? "Unavailable project"
    }
    private func detail(_ entry: ProcessingEntry) -> String {
        guard entry.id.kind == .export else { return "Captions" }
        let artifact = model.exports.artifacts[entry.id.jobID]
        let profile = artifact?.profile ?? (try? entry.record.decode(ExportJob.self))?.payload.profile
        guard let profile else { return "Export" }
        var parts = profile.format == .mp4
            ? ["Captioned video", profile.resolution.title]
            : ["SRT subtitles"]
        if let duration = artifact?.duration {
            let display = EditorTime.display(duration)
            parts.append(display.components(separatedBy: ".").first ?? display)
        }
        return parts.joined(separator: " · ")
    }
}
