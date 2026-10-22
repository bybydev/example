import CoreMedia
import JobQueue
import SwiftUI

/// P2 is language/start/status and read-only saved output, not the P3 editor.
struct IOSTranscriptionView: View {
    @Environment(IOSProjectsModel.self) private var model
    @AppStorage("com.hoangbkit.inkribe.ios.speech-language") private var language = "auto"
    let document: IOSProjectDocument

    var body: some View {
        let speech = model.transcription
        VStack(alignment: .leading, spacing: 12) {
            Label("Captions", systemImage: "captions.bubble").font(.headline)
            if let result = document.recognition {
                Text("Transcription saved on this device")
                    .font(.caption).foregroundStyle(.secondary)
                if result.words.isEmpty {
                    Text("No speech was detected in this media.")
                        .foregroundStyle(.secondary)
                } else {
                    let wordIndex = Dictionary(uniqueKeysWithValues: result.words.map { ($0.id, $0) })
                    // Lazy rows avoid constructing every caption view for long recordings.
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(result.cues) { cue in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(time(cue.interval.start)).font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text(cue.wordIDs.compactMap { wordIndex[$0]?.text }.joined()
                                    .trimmingCharacters(in: .whitespacesAndNewlines))
                                    .textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            } else {
                let record = speech.record(for: document.id)
                Picker("Language", selection: $language) {
                    ForEach(IOSSpeechLanguage.codes, id: \.self) { code in
                        Text(IOSSpeechLanguage.name(code)).tag(code)
                    }
                }
                .disabled(speech.isActive(document.id))
                if let record {
                    status(record, speech: speech)
                }
                if !speech.isActive(document.id) && !(record?.status.isRetryable ?? false) {
                    Button("Transcribe", systemImage: "waveform") {
                        Task {
                            do { try await speech.enqueue(projectID: document.id, language: language) }
                            catch { model.alertMessage = error.localizedDescription }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!speech.modelAvailable || speech.persistenceError != nil)
                }
                if !speech.modelAvailable {
                    Text("The speech model is missing from this app installation.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let error = speech.persistenceError {
                Text(error).font(.footnote).foregroundStyle(.red)
                Button("Retry local job storage") { speech.retryStorage() }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .task { speech.start() }
    }

    @ViewBuilder
    private func status(_ record: JobRecord, speech: IOSTranscriptionController) -> some View {
        let progress = speech.queue?.liveProgress[record.id]
        if !record.status.isTerminal {
            Text(record.status == .pending ? "Waiting to transcribe…" :
                record.status == .cancelling ? "Cancelling…" : progress?.message ?? "Preparing transcription…")
                .font(.subheadline)
            if let fraction = progress?.fractionCompleted {
                ProgressView(value: fraction)
            } else {
                ProgressView()
            }
            Button("Cancel", role: .cancel) {
                do { try speech.cancel(record.id) }
                catch { model.alertMessage = error.localizedDescription }
            }
            .disabled(record.status == .cancelling)
        } else if record.status.isRetryable {
            Text(record.status == .cancelled ? "Transcription cancelled." :
                record.error ?? "Transcription could not finish.")
                .font(.footnote).foregroundStyle(.secondary)
            Button("Retry", systemImage: "arrow.clockwise") {
                Task {
                    do { try await speech.retry(record, language: language) }
                    catch { model.alertMessage = error.localizedDescription }
                }
            }
            .disabled(!speech.modelAvailable || speech.persistenceError != nil)
        } else if record.status == .unrecoverable {
            Text(record.error ?? "This saved job could not be restored. You can start a new transcription.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func time(_ value: MediaTime) -> String {
        let seconds = CMTimeGetSeconds(value.cmTime)
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "—" }
        return String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}
