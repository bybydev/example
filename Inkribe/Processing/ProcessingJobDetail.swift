import JobQueue
import SwiftUI

/// Resolve by compound ID on every render/action, never retain a record snapshot.
/// Read-only inspection. Mutations belong to the row that owns this job.
struct ProcessingJobDetail: View {
    @Environment(ProjectsModel.self) private var model
    let key: ProcessingJobKey
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
                    if !entry.record.status.isTerminal,
                       let pause = processing.lifecycle.pauseDescription(for: key.kind) {
                        Text(pause).foregroundStyle(.secondary)
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
            if entry?.record.status.isTerminal == false {
                Section {
                    Text(processing.continuedProcessing.explanation(for: key.kind))
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Closing Inkribe from the app switcher stops processing. Reopen the app to continue saved work.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Job details")
        .navigationBarTitleDisplayMode(.inline)
        .themedSurface()
        .task { if key.kind == .export { await model.exports.refreshArtifacts() } }
    }

    @ViewBuilder private var capturedRequest: some View {
        if let entry, key.kind == .transcription,
           let request = try? entry.record.decode(SpeechJob.self).payload {
            Section("Captured transcription request") {
                LabeledContent("Language", value: SpeechLanguage.name(request.languageCode ?? "auto"))
                LabeledContent("Saved revision", value: String(request.expectedRevision))
                if let windows = request.windowIndices {
                    Text("Targeted retry: \(windows.count) ranges").font(.footnote)
                }
                if !model.transcription.modelAvailable {
                    Text("Speech recognition for this retry is unavailable. Review Speech Models in Settings, then try again.")
                        .foregroundStyle(.secondary)
                }
                Text("Retry uses the active speech model, rechecks the current project and allowance, and preserves accepted captions and edits.")
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
                Text(project.title).font(.headline)
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
                if let url = artifact.outputURL {
                    Label("Ready to save or share", systemImage: "checkmark.circle")
                    Text(url.lastPathComponent).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                } else {
                    Text("The completed file is unavailable. Your project and saved captions are preserved; create a new export from the project.")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Request and files", value: ByteCountFormatter.string(fromByteCount: artifact.bytes, countStyle: .file))
                if let issue = artifact.issue { Text(issue).foregroundStyle(.red).textSelection(.enabled) }
            } else {
                Text("The saved request or output could not be found. Start a new export from the project.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
