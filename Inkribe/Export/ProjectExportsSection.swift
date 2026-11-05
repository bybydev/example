import AppFoundation
import JobQueue
import SwiftUI
import UIKit

/// Compact project rows. Secondary actions share an ellipsis/context menu;
/// exact saved IDs remain the anchors for queue navigation and new exports.
struct ProjectExportsSection: View {
    @Environment(ProjectsModel.self) private var model
    @Environment(\.appFoundationTheme) private var theme
    let session: EditorSession
    var focusedJobID: UUID? = nil
    var showsUnavailableExport = false
    var requestError: String? = nil
    let onDetails: (UUID) -> Void
    let onReuseProfile: (ExportProfile) -> Void

    private var items: [ProjectExportListItem] {
        let entries = model.processing.entries.filter {
            $0.id.kind == .export && $0.projectID == session.projectID
        }
        let records = Dictionary(uniqueKeysWithValues: entries.map { ($0.id.jobID, $0) })
        let artifactIDs = model.exports.artifacts.values.filter { $0.projectID == session.projectID }.map(\.id)
        return Set(records.keys).union(artifactIDs).map { id in
            ProjectExportListItem(id: id,
                entry: records[id] ?? model.processing.entry(.init(kind: .export, jobID: id)),
                artifact: model.exports.artifacts[id])
        }.sorted {
            let a = $0.updatedAt ?? .distantPast, b = $1.updatedAt ?? .distantPast
            return a == b ? $0.id.uuidString < $1.id.uuidString : a > b
        }
    }

    var body: some View {
        Section {
            if showsUnavailableExport {
                Text("This export is no longer available. Other exports from this project are listed below.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let issue = model.exports.persistenceError {
                Text(issue).foregroundStyle(.red)
                Button("Retry export storage") { Task { await model.exports.retryStorage() } }
            }
            if let issue = model.processing.lifecycle.error {
                Text(issue).foregroundStyle(.red)
                Button("Retry processing control storage") { model.processing.retryControlStorage() }
            }
            if let requestError { Text(requestError).foregroundStyle(.red).textSelection(.enabled) }
            if items.isEmpty {
                Text("Your exports and their progress will appear here.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(items) { row($0) }
            if let error = model.exports.inventoryError {
                Text(error).font(.footnote).foregroundStyle(.orange)
                Button("Refresh exports") { Task { await model.exports.refreshArtifacts() } }
            }
        } header: {
            Text("Exports")
        } footer: {
            Text(model.processing.continuedProcessing.explanation(for: .export))
                .font(.footnote)
        }
        .buttonStyle(.borderless)
    }

    private func row(_ item: ProjectExportListItem) -> some View {
        Group {
            if item.canDeliver, let artifact = item.artifact {
                ProjectExportFileRow(artifact: artifact, updatedAt: item.updatedAt,
                    currentRevision: session.document?.contentRevision, hasPendingEdits: session.hasPendingChanges,
                    onDetails: { onDetails(item.id) }, reuseProfile: onReuseProfile)
            } else {
                ProjectExportJobRow(jobID: item.id, updatedAt: item.updatedAt, onDetails: { onDetails(item.id) })
            }
        }
        .padding(focusedJobID == item.id ? 8 : 0)
        .background(highlight(item.id), in: RoundedRectangle(cornerRadius: 10))
        .id(item.id)
    }
    private func highlight(_ id: UUID) -> Color {
        focusedJobID == id ? theme.accentColor.opacity(0.1) : .clear
    }
}

/// Merge queue metadata and retained files by durable job ID, including jobs
/// whose files are missing and files whose queue records have been removed.
private struct ProjectExportListItem: Identifiable {
    let id: UUID
    let entry: ProcessingEntry?
    let artifact: ExportArtifact?
    var updatedAt: Date? {
        [entry?.record.updatedAt, artifact?.updatedAt, artifact?.createdAt].compactMap { $0 }.max()
    }
    var canDeliver: Bool {
        artifact?.outputURL != nil && (entry == nil || entry?.record.status == .completed)
    }
}

private struct ProjectExportFileRow: View {
    @Environment(ProjectsModel.self) private var model
    let artifact: ExportArtifact
    let updatedAt: Date?
    let currentRevision: UInt64?
    let hasPendingEdits: Bool
    let onDetails: () -> Void
    let reuseProfile: (ExportProfile) -> Void
    @State private var deleting = false
    @State private var error: String?
    @State private var thumbnail: Data?
    private var older: Bool {
        hasPendingEdits || (artifact.revision.flatMap { revision in currentRevision.map { $0 != revision } } ?? false)
    }
    private var metadata: String {
        var parts = exportProfileMetadata(artifact.profile, duration: artifact.duration)
        if let bytes = artifact.outputBytes {
            parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }
    private var note: String {
        var parts = ["Completed"]
        if let updatedAt { parts.append(exportDate(updatedAt)) }
        if older { parts.append("Earlier version") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ExportDeliveryView(jobID: artifact.id) { delivery in
                HStack(spacing: 0) {
                    if artifact.profile?.format == .mp4 {
                        Button(action: delivery.preview) { rowLabel }
                            .buttonStyle(.plain)
                            .disabled(delivery.isBusy || model.exports.hasUserDelivery)
                            .accessibilityHint("Previews this video")
                    } else {
                        Menu { fileActions(delivery) } label: { rowLabel }
                            .buttonStyle(.plain)
                            .accessibilityHint("Opens export actions")
                    }
                    Menu { fileActions(delivery) } label: { ExportActionsLabel() }
                }
                .contextMenu { fileActions(delivery) }
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .alert("Delete this local export?", isPresented: $deleting) {
            Button("Delete export", role: .destructive) {
                Task {
                    do { try await model.exports.discard(artifact.id); await model.refreshStorage() }
                    catch { self.error = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Your project, original clips and copies already saved elsewhere are kept.") }
        .task(id: artifact.outputURL) {
            guard artifact.profile?.format == .mp4 else { return }
            do {
                let lease = try model.exports.beginDelivery(artifact.id, purpose: .artwork)
                defer { model.exports.endDelivery(lease.token) }
                let review = await ImportMediaReviewer().review(ImportInput(localURL: lease.url, origin: .files))
                guard !Task.isCancelled else { return }
                thumbnail = review.thumbnail
            } catch { /* Optional artwork must not prevent delivery. */ }
        }
    }

    private var rowLabel: some View {
        ExportRowLabel(profile: artifact.profile, thumbnail: thumbnail, metadata: metadata,
            note: note, noteIcon: "checkmark.circle")
    }
    @ViewBuilder private func fileActions(_ delivery: ExportDeliveryActions) -> some View {
        if artifact.profile?.format == .mp4 {
            Button("Preview video", systemImage: "play.rectangle", action: delivery.preview)
                .disabled(delivery.isBusy || model.exports.hasUserDelivery)
            Divider()
            Button("Save to Photos", systemImage: "photo.on.rectangle", action: delivery.saveToPhotos)
                .disabled(delivery.isBusy || model.exports.hasUserDelivery)
        }
        Button("Save to Files", systemImage: "folder", action: delivery.saveToFiles)
            .disabled(delivery.isBusy || model.exports.hasUserDelivery)
        Button("Share…", systemImage: "square.and.arrow.up", action: delivery.share)
            .disabled(delivery.isBusy || model.exports.hasUserDelivery)
        Divider()
        if let profile = artifact.profile {
            Button("Use export settings", systemImage: "slider.horizontal.3") { reuseProfile(profile) }
                .disabled(model.exports.hasUserDelivery)
        }
        Button("Details", systemImage: "info.circle", action: onDetails)
            .disabled(model.exports.hasUserDelivery)
        Divider()
        Button("Delete local export", systemImage: "trash", role: .destructive) { deleting = true }
            .disabled(model.exports.isDelivering(artifact.id) || model.exports.persistenceError != nil ||
                model.exports.mutatingIDs.contains(artifact.id))
    }
}

/// Resolve the record again for every action, including saved requests without
/// a queue record. Their frozen inputs stay accessible through Details.
private struct ProjectExportJobRow: View {
    @Environment(ProjectsModel.self) private var model
    @Environment(\.appFoundationTheme) private var theme
    let jobID: UUID
    let updatedAt: Date?
    let onDetails: () -> Void
    @State private var confirming: ProcessingAction?
    @State private var showingConfirmation = false
    @State private var error: String?
    private var key: ProcessingJobKey { .init(kind: .export, jobID: jobID) }
    private var entry: ProcessingEntry? { model.processing.entry(key) }
    private var artifact: ExportArtifact? { model.exports.artifacts[jobID] }
    private var profile: ExportProfile? {
        artifact?.profile ?? entry.flatMap { try? $0.record.decode(ExportJob.self).payload.profile }
    }
    private var metadata: String {
        var parts = exportProfileMetadata(profile, duration: artifact?.duration)
        if let updatedAt { parts.append(exportDate(updatedAt)) }
        return parts.joined(separator: " · ")
    }
    private var status: String {
        guard let entry else { return artifact?.issue == nil ? "Saved request" : "Request unavailable" }
        if !entry.record.status.isTerminal, model.exports.queue?.isPaused == true { return "Paused" }
        switch entry.record.status {
        case .pending: return "Waiting"
        case .failed: return "Couldn’t finish"
        case .unrecoverable: return "Request unavailable"
        case .completed: return "Completed"
        default: return entry.statusTitle
        }
    }
    private var statusTint: Color {
        if entry?.record.status == .failed || entry?.record.status == .unrecoverable || artifact?.issue != nil { return .red }
        if entry?.record.status == .processing, model.exports.queue?.isPaused != true { return theme.accentColor }
        return .secondary
    }
    private var statusIcon: String? {
        guard let entry else { return artifact?.issue == nil ? nil : "exclamationmark.circle" }
        if !entry.record.status.isTerminal, model.exports.queue?.isPaused == true { return "pause.circle" }
        switch entry.record.status {
        case .pending: return "clock"
        case .failed, .unrecoverable: return "exclamationmark.circle"
        case .completed: return "checkmark.circle"
        case .cancelled, .cancelling: return "xmark.circle"
        case .pausing: return "pause.circle"
        case .processing: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                Button(action: onDetails) {
                    ExportRowLabel(profile: profile, metadata: metadata, note: status,
                        noteTint: statusTint, noteIcon: statusIcon, fraction: entry?.fraction)
                }
                .buttonStyle(.plain)
                .disabled(model.exports.hasUserDelivery)
                .accessibilityHint("Opens export details")
                Menu { jobActions } label: { ExportActionsLabel() }
            }
            .contextMenu { jobActions }
            if model.processing.acting.contains(key) { ProgressView("Updating export…").font(.caption) }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .alert(confirming == .cancel ? "Cancel this export?" : "Delete this local export?",
            isPresented: $showingConfirmation) {
            Button(confirming == .cancel ? "Cancel export" : "Delete export", role: .destructive) {
                if let confirming { perform(confirming) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(confirming == .cancel ? "Saved captions and completed files are kept." :
                "Your project, original clips and copies already saved elsewhere are kept.")
        }
    }

    @ViewBuilder private var jobActions: some View {
        if model.processing.can(.retry, key) {
            Button("Retry export", systemImage: "arrow.clockwise") { perform(.retry) }
        }
        Button("Details", systemImage: "info.circle", action: onDetails)
            .disabled(model.exports.hasUserDelivery)
        if model.processing.can(.cancel, key) {
            Divider()
            Button("Cancel export", systemImage: "xmark.circle", role: .destructive) { confirm(.cancel) }
        }
        if model.processing.can(.discardExport, key) || (entry == nil && artifact != nil) {
            Divider()
            Button("Delete local export", systemImage: "trash", role: .destructive) { confirm(.discardExport) }
                .disabled(model.exports.isDelivering(jobID) || model.exports.persistenceError != nil ||
                    model.exports.mutatingIDs.contains(jobID))
        }
    }
    private func confirm(_ action: ProcessingAction) { confirming = action; showingConfirmation = true }
    private func perform(_ action: ProcessingAction) {
        error = nil
        Task {
            do {
                if action == .discardExport && entry == nil { try await model.exports.discard(jobID) }
                else { try await model.processing.perform(action, key) }
                await model.refreshStorage()
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct ExportRowLabel: View {
    let profile: ExportProfile?
    var thumbnail: Data? = nil
    let metadata: String
    var note: String?
    var noteTint: Color = .secondary
    var noteIcon: String? = nil
    var fraction: Double? = nil

    var body: some View {
        HStack(spacing: 11) {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                .frame(width: 48, height: 48)
                .overlay {
                    if let thumbnail, let image = UIImage(data: thumbnail) {
                        Image(uiImage: image).resizable().scaledToFit().frame(width: 48, height: 48)
                    } else {
                        Image(systemName: profile?.format == .srt ? "doc.text" :
                            profile == nil ? "square.and.arrow.up" : "film").foregroundStyle(.secondary)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(profile.map { $0.format == .srt ? "SRT subtitles" : "Captioned video" } ?? "Export")
                    .font(.body.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
                if !metadata.isEmpty { Text(metadata).font(.caption).foregroundStyle(.secondary) }
                if let note {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if let noteIcon { Label(note, systemImage: noteIcon).lineLimit(3) }
                        else { Text(note).lineLimit(3) }
                        if let fraction {
                            Text("\(Int((fraction * 100).rounded()))%")
                                .monospacedDigit().fixedSize()
                        }
                    }
                    .font(.caption).foregroundStyle(noteTint)
                }
                if let fraction { ProgressView(value: fraction).accessibilityLabel("Export progress") }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct ExportActionsLabel: View {
    var body: some View {
        Image(systemName: "ellipsis")
            .font(.body.weight(.semibold)).foregroundStyle(.secondary)
            .frame(width: 44, height: 44).contentShape(Rectangle())
            .accessibilityLabel("Export actions")
    }
}

private func exportProfileMetadata(_ profile: ExportProfile?, duration: MediaTime?) -> [String] {
    var parts: [String] = []
    if profile?.format == .mp4, let profile { parts.append(profile.resolution.title) }
    if let duration {
        let display = EditorTime.display(duration)
        parts.append(display.components(separatedBy: ".").first ?? display)
    }
    return parts
}

private func exportDate(_ date: Date) -> String {
    date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
}
