import AppFoundation
import SwiftUI

/// On-device export bundles remain accessible independently of queue records
/// and project lifetime. Mutations stay in each row's menu.
struct RetainedExportsView: View {
    @Environment(ProjectsModel.self) private var model
    @Environment(\.appFoundationTheme) private var theme
    @Environment(\.queueProjectNavigation) private var openProject
    @State private var details: ProcessingJobKey?
    @State private var isOpeningProject = false
    private var artifacts: [ExportArtifact] {
        model.exports.artifacts.values.sorted {
            let a = $0.createdAt ?? .distantPast, b = $1.createdAt ?? .distantPast
            return a == b ? $0.id.uuidString < $1.id.uuidString : a > b
        }
    }

    var body: some View {
        List {
            if let issue = model.exports.persistenceError {
                Section {
                    Text(issue).font(.footnote).foregroundStyle(.red).textSelection(.enabled)
                    Button("Retry export storage") { Task { await model.exports.retryStorage() } }
                }
            }
            if let issue = model.exports.inventoryError {
                Section {
                    Text(issue).font(.footnote).foregroundStyle(.red).textSelection(.enabled)
                    Button("Refresh files") { Task { await model.exports.refreshArtifacts() } }
                }
            }
            Section {
                if artifacts.isEmpty {
                    ContentUnavailableView("No Stored Exports", systemImage: "archivebox",
                        description: Text("Saved export requests and completed files appear here."))
                        .listRowSeparator(.hidden)
                }
                ForEach(artifacts) { artifact in
                    let key = ProcessingJobKey(kind: .export, jobID: artifact.id)
                    RetainedExportRow(artifact: artifact,
                        onDetails: { details = key },
                        onJumpToProject: { jumpToProject(key) })
                        .disabled(isOpeningProject || model.exports.hasUserDelivery)
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(theme.borderColor)
                }
            } footer: {
                Text("These requests and files live on this device. Removing a queue record keeps them here. Local storage holds up to 100 exports; save the files you need before deleting old exports.")
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .navigationTitle("Export Storage")
        .navigationBarTitleDisplayMode(.inline)
        .themedSurface()
        .queueJobDetails($details)
        .onAppear { isOpeningProject = false }
        .task { await model.exports.start(); await model.exports.refreshArtifacts() }
        .refreshable { await model.exports.refreshArtifacts() }
    }

    private func jumpToProject(_ key: ProcessingJobKey) {
        guard !isOpeningProject, !model.exports.hasUserDelivery,
              let route = model.queueProjectRoute(for: key) else { return }
        isOpeningProject = true
        openProject(route)
    }
}

/// One on-device export bundle. Delivery, recovery and deletion share this row's
/// menu; tapping the row only opens read-only details.
private struct RetainedExportRow: View {
    @Environment(ProjectsModel.self) private var model
    @Environment(\.appFoundationTheme) private var theme
    let artifact: ExportArtifact
    let onDetails: () -> Void
    let onJumpToProject: () -> Void
    @State private var deleting = false
    @State private var recovering = false
    @State private var error: String?

    private var key: ProcessingJobKey { .init(kind: .export, jobID: artifact.id) }
    private var entry: ProcessingEntry? { model.processing.entry(key) }
    private var canDeliver: Bool {
        artifact.outputURL != nil && (entry == nil || entry?.record.status == .completed)
    }
    private var canRestore: Bool { entry == nil && artifact.issue == nil }
    private var canDelete: Bool {
        (entry == nil || entry?.record.status.isTerminal == true) &&
            !model.exports.isDelivering(artifact.id) &&
            model.exports.persistenceError == nil &&
            !model.exports.mutatingIDs.contains(artifact.id)
    }
    private var status: String {
        if let issue = artifact.issue { return issue }
        if let entry {
            return entry.record.status == .completed ? "Completed file" : entry.statusTitle
        }
        return artifact.outputURL == nil ? "Saved request" : "Completed file"
    }

    var body: some View {
        ExportDeliveryView(jobID: artifact.id) { delivery in
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    Button(action: onDetails) { rowLabel }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens export details")
                    Menu { rowActions(delivery) } label: {
                        Image(systemName: "ellipsis")
                            .font(.body.weight(.semibold)).foregroundStyle(.secondary)
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                            .accessibilityLabel("Export actions")
                    }
                }
                .contextMenu { rowActions(delivery) }
                if recovering { ProgressView("Restoring…").font(.caption) }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
        }
        .alert("Delete this local export?", isPresented: $deleting) {
            Button("Delete export", role: .destructive) {
                Task {
                    do {
                        try await model.exports.discard(artifact.id)
                        await model.refreshStorage()
                    } catch { self.error = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Your project, original clips and copies already saved elsewhere are kept.")
        }
    }

    private var rowLabel: some View {
        HStack(spacing: 12) {
            Image(systemName: artifact.profile?.format == .srt ? "doc.text" : "film")
                .foregroundStyle(theme.accentColor).frame(width: 24)
            VStack(alignment: .leading, spacing: 5) {
                Text(artifact.title).font(.body.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
                Text(artifact.profile?.format.title ?? "Export").font(.subheadline).foregroundStyle(.secondary)
                Text(status)
                    .font(.caption).foregroundStyle(artifact.issue == nil ? Color.secondary : Color.red).lineLimit(2)
                Text(ByteCountFormatter.string(fromByteCount: artifact.bytes, countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder private func rowActions(_ delivery: ExportDeliveryActions) -> some View {
        if canDeliver {
            if artifact.profile?.format == .mp4 {
                Button("Preview video", systemImage: "play.rectangle", action: delivery.preview)
                    .disabled(delivery.isBusy || model.exports.hasUserDelivery)
                Button("Save to Photos", systemImage: "photo.on.rectangle", action: delivery.saveToPhotos)
                    .disabled(delivery.isBusy || model.exports.hasUserDelivery)
            }
            Button("Save to Files", systemImage: "folder", action: delivery.saveToFiles)
                .disabled(delivery.isBusy || model.exports.hasUserDelivery)
            Button("Share…", systemImage: "square.and.arrow.up", action: delivery.share)
                .disabled(delivery.isBusy || model.exports.hasUserDelivery)
            Divider()
        }
        if model.queueProjectID(for: key) != nil {
            Button("Jump to Project", systemImage: "arrow.up.forward.app", action: onJumpToProject)
        }
        Button("Details", systemImage: "info.circle", action: onDetails)
        if canRestore || canDelete {
            Divider()
        }
        if canRestore {
            Button(artifact.outputURL == nil ? "Recover saved request" : "Restore to queue",
                systemImage: "arrow.clockwise") { recover() }
                .disabled(recovering || model.exports.isDelivering(artifact.id) ||
                    model.exports.persistenceError != nil)
        }
        if canDelete {
            Button("Delete local export", systemImage: "trash", role: .destructive) { deleting = true }
        }
    }

    private func recover() {
        error = nil
        recovering = true
        Task {
            defer { recovering = false }
            do {
                try await model.exports.recover(artifact.id)
                await model.refreshStorage()
            } catch { self.error = error.localizedDescription }
        }
    }
}
