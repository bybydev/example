import AppFoundation
import JobQueue
import SwiftUI
import UIKit

private enum QueueScope: String, CaseIterable, Identifiable {
    case all = "All", pending = "Pending", processing = "Processing", done = "Done", failed = "Failed"
    var id: Self { self }
    func includes(_ entry: ProcessingEntry) -> Bool {
        switch self {
        case .all: true
        case .pending: entry.pending
        case .processing: entry.processing
        case .done: entry.record.status == .completed
        case .failed: entry.record.status.isTerminal && entry.record.status != .completed
        }
    }
}

private enum QueueSort: String, CaseIterable, Identifiable {
    case newest = "Newest first", oldest = "Oldest first", project = "Project name"
    var id: Self { self }
}

struct ProcessingQueueSheet: View {
    @Environment(ProjectsModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ProcessingQueueView()
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }.disabled(model.exports.isDelivering)
                    }
                }
        }
        .interactiveDismissDisabled(model.exports.isDelivering)
    }
}

/// Custom native queue, inspired by Spokio's scopes, rows and live detail IDs.
/// All activity content scrolls. Display sorting never changes execution order.
struct ProcessingQueueView: View {
    @Environment(ProjectsModel.self) private var model
    @Environment(\.appFoundationTheme) private var theme
    @State private var scope = QueueScope.all
    @State private var kind: ProcessingKind?
    @State private var search = ""
    @State private var sort = QueueSort.newest
    @State private var error: String?
    @State private var bulkAction: ProcessingAction?
    @State private var bulkKeys: [ProcessingJobKey] = []
    @State private var confirmingBulk = false
    @State private var runningBulk = false
    private var processing: ProcessingCoordinator { model.processing }

    private var matching: [ProcessingEntry] {
        processing.entries.filter { entry in
            (kind == nil || kind == entry.id.kind) &&
                (search.isEmpty || title(entry).localizedStandardContains(search) ||
                 entry.id.kind.title.localizedStandardContains(search) ||
                 entry.record.error?.localizedStandardContains(search) == true)
        }
    }
    private var visible: [ProcessingEntry] {
        matching.filter { scope.includes($0) }.sorted { a, b in
            switch sort {
            case .newest: if a.record.createdAt != b.record.createdAt { return a.record.createdAt > b.record.createdAt }
            case .oldest: if a.record.createdAt != b.record.createdAt { return a.record.createdAt < b.record.createdAt }
            case .project:
                let order = title(a).localizedStandardCompare(title(b))
                if order != .orderedSame { return order == .orderedAscending }
            }
            return a.record.id.uuidString < b.record.id.uuidString
        }
    }

    var body: some View {
        List {
            controls
            storageProblems
            if let error { Section { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
            Section {
                if visible.isEmpty {
                    ContentUnavailableView {
                        Label(processing.entries.isEmpty ? "Your queue is empty" : "No matching jobs",
                              systemImage: "list.bullet.rectangle")
                    } description: {
                        Text(processing.entries.isEmpty ? "Transcribe a project or export a video or subtitles. Work stays in the queue when you leave this screen." : "Try another status, type or search.")
                    }
                } else {
                    ForEach(visible) { entry in
                        NavigationLink(value: entry.id) {
                            ProcessingQueueRow(entry: entry, title: title(entry),
                                thumbnailURL: project(entry)?.thumbnailURL,
                                cacheGeneration: model.cacheGeneration)
                        }
                        .listRowBackground(theme.surfaceColor)
                    }
                }
            } header: {
                Text("\(visible.count) jobs")
            } footer: {
                Text("One heavy operation runs at a time. Transcription and export share capacity fairly. Display sorting does not reorder work.")
            }
            retainedFiles
            Section {
                Text("Keep Inkribe open to process jobs. Leaving the foreground pauses work; returning resumes it unless you paused the queue yourself. Saved captions and completed files remain available.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Queue")
        .navigationBarTitleDisplayMode(.inline)
        .themedSurface()
        .searchable(text: $search, prompt: "Search projects or errors")
        .navigationDestination(for: ProcessingJobKey.self) { ProcessingJobDetail(key: $0) }
        .toolbar { actionsMenu }
        .task { await processing.start(); await model.exports.refreshArtifacts() }
        .refreshable { await model.exports.refreshArtifacts(); await model.refreshStorage() }
        .confirmationDialog("Update these jobs?", isPresented: $confirmingBulk) {
            Button(bulkAction == .cancel ? "Cancel jobs" : "Remove finished records", role: .destructive) {
                if let bulkAction { runBulk(bulkAction, keys: bulkKeys) }
            }
        } message: {
            Text(bulkAction == .cancel ? "Cancel \(bulkKeys.count) selected jobs. Saved captions and completed files are kept." : "Remove \(bulkKeys.count) finished records. Project captions, recovery checkpoints and retained export files are kept. Export files stay in Retained files below.")
        }
    }

    private var controls: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Label(notice, systemImage: processing.lifecycle.userPaused ? "pause.circle" : "list.bullet.rectangle")
                    .font(.headline)
                if processing.lifecycle.userPaused || processing.activeCount > 0 {
                    Button(processing.lifecycle.userPaused ? "Resume queue" : "Pause queue",
                           systemImage: processing.lifecycle.userPaused ? "play.fill" : "pause.fill") {
                        do { try processing.setPaused(!processing.lifecycle.userPaused) }
                        catch { self.error = error.localizedDescription }
                    }
                    .disabled(processing.lifecycle.error != nil)
                }
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(QueueScope.allCases) { value in
                            Button { scope = value } label: {
                                Text("\(value.rawValue) \(matching.filter { value.includes($0) }.count)")
                                    .font(.subheadline.weight(scope == value ? .semibold : .regular))
                                    .padding(.horizontal, 12).frame(minHeight: 44)
                                    .background(scope == value ? theme.accentColor.opacity(0.18) : theme.surfaceColor, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(scope == value ? .isSelected : [])
                        }
                    }
                }
                .scrollIndicators(.hidden)
                Picker("Job type", selection: $kind) {
                    Text("All types").tag(ProcessingKind?.none)
                    ForEach(ProcessingKind.allCases) { Text($0.title).tag(Optional($0)) }
                }
                Picker("Display order", selection: $sort) {
                    ForEach(QueueSort.allCases) { Text($0.rawValue).tag($0) }
                }
                if runningBulk { ProgressView("Updating jobs…") }
            }
            .buttonStyle(.borderless)
        }
    }

    private var notice: String {
        if processing.lifecycle.error != nil { return "Processing storage needs attention" }
        if processing.lifecycle.userPaused { return "Paused by you" }
        if !processing.lifecycle.foreground { return "Paused outside the foreground" }
        return "\(processing.processingCount) processing · \(processing.pendingCount) pending"
    }

    @ViewBuilder private var storageProblems: some View {
        if let issue = processing.lifecycle.error {
            Section("Processing control storage") {
                Text(issue).foregroundStyle(.red).textSelection(.enabled)
                Button("Retry control storage") { processing.retryControlStorage() }
            }
        }
        if let issue = model.transcription.persistenceError {
            Section("Transcription storage") {
                Text(issue).foregroundStyle(.red).textSelection(.enabled)
                Button("Retry transcription storage") { model.transcription.retryStorage() }
                Text("The original queue file is retained. No empty replacement or reset is performed.").font(.footnote)
            }
        }
        if let issue = model.exports.persistenceError {
            Section("Export storage") {
                Text(issue).foregroundStyle(.red).textSelection(.enabled)
                Button("Retry export storage") { Task { await model.exports.retryStorage() } }
                Text("Retained requests and files are preserved while queue recovery is unavailable.").font(.footnote)
            }
        }
        if let issue = model.exports.inventoryError {
            Section("Export file inventory") {
                Text(issue).foregroundStyle(.red).textSelection(.enabled)
                Button("Refresh retained files") { Task { await model.exports.refreshArtifacts() } }
            }
        }
    }

    @ViewBuilder private var retainedFiles: some View {
        if !model.exports.orphanedArtifacts.isEmpty {
            Section {
                ForEach(model.exports.orphanedArtifacts) { artifact in
                    NavigationLink(value: ProcessingJobKey(kind: .export, jobID: artifact.id)) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(artifact.title).font(.headline)
                            Text(artifact.issue ?? (artifact.outputURL == nil ? "Saved request · not in queue" : "Completed file · not in queue"))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(ByteCountFormatter.string(fromByteCount: artifact.bytes, countStyle: .file))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                }
            } header: { Text("Retained files and requests") }
            footer: { Text("Requests and results survive record removal and interrupted queue publication. Inspect, recover or explicitly delete each one. No unsaved result expires automatically.") }
        }
        Section {
            Text("\(model.exports.artifacts.count) retained export requests/results · \(ByteCountFormatter.string(fromByteCount: model.exports.artifacts.values.reduce(0) { $0 + $1.bytes }, countStyle: .file))")
                .font(.footnote).foregroundStyle(.secondary)
            Text("Unreadable folders may have incomplete size information. Storage shows the aggregate export usage.")
                .font(.footnote).foregroundStyle(.secondary)
            Text("Local retention holds up to 100 exports, including files without queue records. Save what you need, then delete older local exports to make room. Removing a queue record alone keeps its file.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var actionsMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Retry eligible filtered jobs", systemImage: "arrow.clockwise") {
                    runBulk(.retry, keys: visible.map(\.id))
                }
                .disabled(runningBulk || !visible.contains { processing.can(.retry, $0.id) })
                Button("Cancel filtered jobs", systemImage: "xmark.circle", role: .destructive) {
                    confirmBulk(.cancel)
                }
                .disabled(runningBulk || !visible.contains { processing.can(.cancel, $0.id) })
                Button("Remove finished filtered records", systemImage: "trash", role: .destructive) {
                    confirmBulk(.removeRecord)
                }
                .disabled(runningBulk || !visible.contains { processing.can(.removeRecord, $0.id) })
            } label: { Label("Queue actions", systemImage: "ellipsis.circle") }
        }
    }
    private func confirmBulk(_ action: ProcessingAction) {
        bulkAction = action
        bulkKeys = visible.filter { processing.can(action, $0.id) }.map(\.id)
        confirmingBulk = true
    }
    private func runBulk(_ action: ProcessingAction, keys: [ProcessingJobKey]) {
        runningBulk = true; error = nil
        Task {
            let failures = await processing.performBulk(action, keys: keys)
            error = failures.isEmpty ? nil : failures.joined(separator: "\n\n")
            runningBulk = false
            await model.refreshStorage()
        }
    }
    private func project(_ entry: ProcessingEntry) -> ProjectSummary? {
        model.allProjects.first { $0.id == entry.projectID }
    }
    private func title(_ entry: ProcessingEntry) -> String {
        if entry.id.kind == .export, let artifact = model.exports.artifacts[entry.record.id] { return artifact.title }
        return project(entry)?.title ?? entry.record.title ?? "Unavailable project"
    }
}

private struct ProcessingQueueRow: View {
    let entry: ProcessingEntry
    let title: String
    let thumbnailURL: URL?
    let cacheGeneration: Int
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            QueueThumbnail(url: thumbnailURL, generation: cacheGeneration, icon: entry.id.kind.icon)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline).lineLimit(2)
                Label(entry.id.kind.title, systemImage: entry.id.kind.icon).font(.caption).foregroundStyle(.secondary)
                Text(entry.statusTitle).font(.subheadline)
                if let value = entry.fraction {
                    ProgressView(value: value).accessibilityLabel("Job progress")
                }
                if let error = entry.record.error {
                    Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(entry.record.createdAt, style: .relative).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

private struct QueueThumbnail: View {
    let url: URL?
    let generation: Int
    let icon: String
    @State private var thumbnail: UIImage?
    var body: some View {
        RoundedRectangle(cornerRadius: 10).fill(.quaternary)
            .frame(width: 48, height: 48)
            .overlay {
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                        .frame(width: 48, height: 48).clipped()
                } else { Image(systemName: icon).foregroundStyle(.secondary) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .accessibilityHidden(true)
            .task(id: "\(url?.path ?? "")-\(generation)") {
                thumbnail = nil
                let data = await ProjectThumbnailData.shared.load(url)
                guard !Task.isCancelled else { return }
                thumbnail = data.flatMap { UIImage(data: $0) }
            }
    }
}
