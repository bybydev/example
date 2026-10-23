import JobQueue
import SwiftUI

/// Job status stays compact while the transcript remains visible/editable.
struct PartialCaptionStatus: View {
    @Environment(ProjectsModel.self) private var model
    let document: ProjectDocument
    let preparing: Bool
    let retry: () -> Void
    let reset: () -> Void
    @State private var showingModels = false
    @State private var confirmReset = false

    var body: some View {
        let speech = model.transcription
        let record = speech.record(for: document.id)
        VStack(alignment: .leading, spacing: 8) {
            if let record, !record.status.isTerminal {
                let progress = speech.queue?.liveProgress[record.id]
                HStack {
                    Text(speech.queue?.isPaused == true ? "Transcription paused" : progress?.message ?? "Transcribing…")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Cancel") {
                        do { try speech.cancel(record.id) }
                        catch { model.alertMessage = error.localizedDescription }
                    }
                    .font(.caption).disabled(record.status == .cancelling)
                }
                if let value = progress?.fractionCompleted { ProgressView(value: value) }
            } else {
                HStack {
                    Label("Incomplete", systemImage: "exclamationmark.bubble")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Retry missing ranges", systemImage: "arrow.clockwise", action: retry)
                        .font(.caption)
                        .disabled(preparing || speech.isAuthorizing || speech.persistenceError != nil)
                }
                DisclosureGroup("Transcription details") {
                    if let error = record?.error { Text(error).font(.caption).foregroundStyle(.secondary) }
                    Text("Available captions are saved. Missing ranges can be retried without changing your edits.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Reset retry progress") { confirmReset = true }
                        .font(.caption).disabled(preparing || speech.isAuthorizing || speech.persistenceError != nil)
                }
                .font(.caption)
            }
            if let modelID = document.recognition?.modelID, !speech.models.isAvailable(modelID) {
                Button("Download the original speech model", systemImage: "cpu") { showingModels = true }
                    .font(.caption)
            }
            if let error = speech.persistenceError {
                Text(error).font(.caption).foregroundStyle(.red)
                Button("Retry job storage") { speech.retryStorage() }.font(.caption)
            }
            if preparing { ProgressView("Preparing retry…").font(.caption) }
        }
        .sheet(isPresented: $showingModels) { SpeechModelsView() }
        .confirmationDialog("Reset saved retry progress?", isPresented: $confirmReset) {
            Button("Reset retry progress", action: reset)
        } message: {
            Text("Your available captions and edits stay saved. Retry will rebuild progress from them and transcribe only missing ranges. This does not change model or runtime compatibility.")
        }
    }
}
