import JobQueue
import SwiftUI

/// Resolve by compound ID on every render/action, never retain a record snapshot.
struct ProcessingJobDetail: View {
    @Environment(ProjectsModel.self) private var model
    let key: ProcessingJobKey
    @State private var error: String?
    @State private var pendingAction: ProcessingAction?
    @State private var confirming = false
    @State private var recovering = false
    @State private var showingModels = false
    private var processing: ProcessingCoordinator { model.processing }
    private var entry: ProcessingEntry? { processing.entry(key) }
    private var artifact: ExportArtifact? { key.kind == .export ? model.exports.artifacts[key.jobID] : nil }
    private var capturedExportProfile: ExportProfile? {
        if let profile = artifact?.profile { return profile }
        guard let entry, let request = try? entry.record.decode(ExportJob.self) else { return nil }
        return request.payload.profile
    }
    private var projectID: UUID? { entry?.projectID ?? artifact?.projectID }
    private var project: ProjectSummary? { model.allProjects.first { $0.id == projectID } }

    var body: some View {
        List {
            Section {
                Text(artifact?.title ?? project?.title ?? key.kind.title).font(.title3.bold())
                LabeledContent("Type", value: key.kind.title)
                if let entry {
                    Text(entry.statusTitle).font(.headline)
                    if let fraction = entry.fraction { ProgressView(value: fraction) }
                    LabeledContent("Created") { Text(entry.record.createdAt, format: .dateTime) }
                    if let started = entry.record.startedAt {
                        LabeledContent("Last started") { Text(started, format: .dateTime) }
                    }
                    if let finished = entry.record.completedAt {
                        LabeledContent("Finished") { Text(finished, format: .dateTime) }
                    }
                    if let failure = entry.record.error { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
                    if !entry.record.status.isTerminal && processing.lifecycle.userPaused {
                        Text("Paused by you. Resume in Queue when you are ready.").foregroundStyle(.secondary)
                    }
                } else {
                    Text(artifact == nil ? "This queue record has been removed." : "This retained request/file has no queue record.")
                        .foregroundStyle(.secondary)
                }
                Text(key.jobID.uuidString).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            capturedRequest
            projectSection
            if key.kind == .export { exportSection }
            actionSection
            if let error { Section("Action could not finish") { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
        }
        .buttonStyle(.borderless)
        .navigationTitle("Job details")
        .navigationBarTitleDisplayMode(.inline)
        .themedSurface()
        .task { if key.kind == .export { await model.exports.refreshArtifacts() } }
        .sheet(isPresented: $showingModels) { SpeechModelsView() }
        .confirmationDialog(confirmationTitle, isPresented: $confirming) {
            if let pendingAction {
                Button(confirmationTitle, role: .destructive) { perform(pendingAction) }
            }
        } message: { Text(confirmationMessage) }
    }

    @ViewBuilder private var capturedRequest: some View {
        if let entry, key.kind == .transcription,
           let request = try? entry.record.decode(SpeechJob.self).payload {
            Section("Captured transcription request") {
                LabeledContent("Model", value: (try? SpeechModelCatalog.descriptor(request.resolvedModelID))?.displayName ?? request.resolvedModelID)
                LabeledContent("Language", value: SpeechLanguage.name(request.languageCode ?? "auto"))
                LabeledContent("Saved revision", value: String(request.expectedRevision))
                if let windows = request.windowIndices {
                    Text("Targeted retry: \(windows.count) ranges").font(.footnote)
                }
                if !model.transcription.models.isAvailable(request.resolvedModelID) {
                    Text("The captured model is not available. Install that model before retrying.")
                        .foregroundStyle(.secondary)
                    Button("Manage speech models", systemImage: "cpu") { showingModels = true }
                }
                Text("Retry keeps the captured model and language, rechecks the current project and allowance, and preserves accepted captions and edits.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        if key.kind == .export {
            Section("Frozen export request") {
                if let profile = capturedExportProfile {
                    LabeledContent("Format", value: profile.format.title)
                    if profile.format == .mp4 { LabeledContent("Resolution", value: profile.resolution.title) }
                }
                if let revision = artifact?.revision { LabeledContent("Saved revision", value: String(revision)) }
                Text("Uses the saved captions, style, trim and media captured when this export was requested. Later edits or new captions do not change it.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var projectSection: some View {
        Section("Project") {
            if let project {
                NavigationLink {
                    ProjectEditorDestination(projectID: project.id)
                } label: { Label("Open \(project.title)", systemImage: "folder") }
                if !project.available {
                    Text("Some original media is missing or changed. Open the project to relink it; saved captions remain available.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if project.captionState == .incomplete {
                    Text("Available captions and edits are saved. Missing ranges can be retried in the project.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Text("The project is unavailable or in Trash. Frozen exports remain independent of project deletion. Restore a trashed project in Storage before retrying transcription.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var exportSection: some View {
        Section("Local export") {
            if let artifact {
                LabeledContent("Request and files", value: ByteCountFormatter.string(fromByteCount: artifact.bytes, countStyle: .file))
                if let issue = artifact.issue { Text(issue).foregroundStyle(.red).textSelection(.enabled) }
                if entry?.record.status == .completed || (entry == nil && artifact.outputURL != nil) {
                    ExportResultView(jobID: key.jobID)
                }
                if entry == nil && artifact.issue == nil {
                    Button(artifact.outputURL == nil ? "Recover saved request into queue" : "Restore completed file to queue", systemImage: "arrow.clockwise") {
                        recovering = true; error = nil
                        Task {
                            defer { recovering = false }
                            do { try await model.exports.recover(key.jobID) }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                    .disabled(recovering || model.exports.persistenceError != nil || model.exports.isDelivering(key.jobID))
                }
                if entry == nil {
                    Button("Delete local export files", systemImage: "trash", role: .destructive) { confirm(.discardExport) }
                        .disabled(recovering || model.exports.persistenceError != nil || model.exports.isDelivering(key.jobID))
                }
            } else {
                Text("The saved request or output could not be found. Start a new export from the project.")
                    .foregroundStyle(.secondary)
            }
            if recovering { ProgressView("Recovering request…") }
        }
    }

    @ViewBuilder private var actionSection: some View {
        if entry != nil {
            Section("Job actions") {
                if processing.can(.retry, key) {
                    Button("Retry saved job", systemImage: "arrow.clockwise") { perform(.retry) }
                }
                if processing.can(.cancel, key) {
                    Button("Cancel job", systemImage: "xmark.circle", role: .destructive) { confirm(.cancel) }
                }
                if processing.can(.removeRecord, key) {
                    Button("Remove queue record", systemImage: "list.bullet.rectangle", role: .destructive) { confirm(.removeRecord) }
                }
                if processing.can(.discardExport, key) {
                    Button("Delete local export files", systemImage: "trash", role: .destructive) { confirm(.discardExport) }
                }
                if processing.acting.contains(key) { ProgressView("Updating job…") }
            }
        }
    }

    private var confirmationTitle: String {
        switch pendingAction {
        case .cancel: "Cancel job"
        case .removeRecord: "Remove queue record"
        case .discardExport: "Delete local export files"
        default: "Update job"
        }
    }
    private var confirmationMessage: String {
        switch pendingAction {
        case .cancel: "Saved captions and completed files are kept. Incomplete work can be retried."
        case .removeRecord: "Your project captions and recovery checkpoints are kept. Export files remain available under Retained files in Queue."
        case .discardExport: "Deletes only this export's frozen inputs, result and queue record. Save or share the file first if you need a copy. Your project and original media are kept."
        default: ""
        }
    }
    private func confirm(_ action: ProcessingAction) { pendingAction = action; confirming = true }
    private func perform(_ action: ProcessingAction) {
        error = nil
        Task {
            do {
                if action == .discardExport && entry == nil { try await model.exports.discard(key.jobID) }
                else { try await processing.perform(action, key) }
                await model.refreshStorage()
            } catch { self.error = error.localizedDescription }
        }
    }
}
