import AppFoundation
import JobQueue
import SwiftUI

/// Project-scoped activity and retained files inside the existing Export form.
struct ProjectExportsSection: View {
    @Environment(ProjectsModel.self) private var model
    let session: EditorSession
    var excludingActivityID: UUID? = nil
    let onReuseProfile: (ExportProfile) -> Void
    private var completed: [ExportArtifact] {
        model.exports.artifacts.values.filter { artifact in
            artifact.projectID == session.projectID && artifact.outputURL != nil &&
                (model.exports.queue?.records[artifact.id] == nil || model.exports.queue?.records[artifact.id]?.status == .completed)
        }.sorted {
            let a = $0.createdAt ?? .distantPast, b = $1.createdAt ?? .distantPast
            return a == b ? $0.id.uuidString < $1.id.uuidString : a > b
        }
    }
    private var activity: [ProcessingEntry] {
        model.processing.entries.filter { $0.id.kind == .export && $0.projectID == session.projectID &&
            $0.record.status != .completed && $0.id.jobID != excludingActivityID }
    }

    var body: some View {
        Group {
            if !activity.isEmpty {
                Section("Export activity") {
                    ForEach(activity) { entry in
                        VStack(alignment: .leading, spacing: 8) {
                            Label(entry.statusTitle, systemImage: "film").font(.subheadline)
                            if let fraction = entry.fraction { ProgressView(value: fraction) }
                            NavigationLink { ProcessingJobDetail(key: entry.id) } label: {
                                Label("View in Queue", systemImage: "list.bullet.rectangle")
                            }
                            if entry.record.status.isRetryable {
                                Button("Retry export") {
                                    Task {
                                        do { try await model.processing.perform(.retry, entry.id) }
                                        catch { model.alertMessage = error.localizedDescription }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            Section("Exported files") {
                if completed.isEmpty {
                    Text("Your exported videos and subtitles will appear here.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(completed) { artifact in
                    ProjectExportRow(artifact: artifact, currentRevision: session.document?.contentRevision,
                        hasPendingEdits: session.hasPendingChanges, reuseProfile: onReuseProfile)
                }
                if let error = model.exports.inventoryError {
                    Text(error).font(.footnote).foregroundStyle(.orange)
                    Button("Refresh exports") { Task { await model.exports.refreshArtifacts() } }
                }
            }
        }
        .buttonStyle(.borderless)
    }
}

private struct ProjectExportRow: View {
    @Environment(ProjectsModel.self) private var model
    let artifact: ExportArtifact
    let currentRevision: UInt64?
    let hasPendingEdits: Bool
    let reuseProfile: (ExportProfile) -> Void
    @State private var deleting = false
    @State private var error: String?
    @State private var thumbnail: Data?
    private var older: Bool {
        hasPendingEdits || (artifact.revision.flatMap { revision in currentRevision.map { $0 != revision } } ?? false)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                MediaThumbnail(data: thumbnail, symbol: artifact.profile?.format == .srt ? "doc.text" : "film")
                VStack(alignment: .leading, spacing: 5) {
                    Text(artifact.profile?.format == .srt ? "SRT subtitles" : "Captioned video").font(.headline)
                    if let profile = artifact.profile, profile.format == .mp4 {
                        Text("\(profile.resolution.title) · \(artifact.duration.map(EditorTime.display) ?? "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let bytes = artifact.outputBytes { Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
                    if let date = artifact.createdAt { Text(date, format: .dateTime.month(.abbreviated).day().hour().minute()).font(.caption).foregroundStyle(.secondary) }
                }
            }
            if older {
                Text("Created before your latest changes").font(.caption).foregroundStyle(.secondary)
            }
            if let profile = artifact.profile {
                Button("Use these export settings", systemImage: "slider.horizontal.3") { reuseProfile(profile) }
            }
            ExportResultView(jobID: artifact.id)
            Button("Delete local export", systemImage: "trash", role: .destructive) { deleting = true }
                .disabled(model.exports.isDelivering(artifact.id) || model.exports.persistenceError != nil)
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .padding(.vertical, 8)
        .confirmationDialog("Delete this local export?", isPresented: $deleting) {
            Button("Delete export", role: .destructive) {
                Task { do { try await model.exports.discard(artifact.id); await model.refreshStorage() } catch { self.error = error.localizedDescription } }
            }
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
}

/// Export now follows the same durable worker in-place, including waiting,
/// cancellation/retry and delivery. It never competes with the shared native gate.
struct ImmediateExportStatus: View {
    @Environment(ProjectsModel.self) private var model
    let jobID: UUID
    @State private var error: String?
    private var key: ProcessingJobKey { .init(kind: .export, jobID: jobID) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let entry = model.processing.entry(key) {
                Text(model.processing.lifecycle.userPaused && !entry.record.status.isTerminal ? "Queue paused by you. Resume in Queue to continue." : entry.statusTitle)
                if let fraction = entry.fraction { ProgressView(value: fraction) }
                if entry.record.status == .completed { ExportResultView(jobID: jobID) }
                if model.processing.can(.cancel, key) { Button("Cancel export", role: .cancel) { perform(.cancel) } }
                if model.processing.can(.retry, key) { Button("Retry export") { perform(.retry) } }
                NavigationLink { ProcessingJobDetail(key: key) } label: { Label("View in Queue", systemImage: "list.bullet.rectangle") }
            } else if model.exports.artifacts[jobID]?.outputURL != nil { ExportResultView(jobID: jobID) }
            else { Text("Review this export in Queue.").foregroundStyle(.secondary) }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
    }
    private func perform(_ action: ProcessingAction) {
        Task { do { try await model.processing.perform(action, key) } catch { self.error = error.localizedDescription } }
    }
}
