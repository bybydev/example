import MacAppFoundation
import SwiftUI

struct InkribeDiagnosticsSettingsPane: View {
    let appState: InkribeAppState

    @Environment(\.macAppTheme) private var theme
    @State private var snapshot = InkribeRuntimeDiagnosticsSnapshot.capture()
    @State private var queueRecoveryMessage: String?
    @State private var queueRecoveryError: String?
    @State private var showsQueueResetConfirmation = false

    var body: some View {
        InkribeSettingsSupport.scroll {
            GroupBox("System") {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Architecture", value: snapshot.architecture)
                    LabeledContent("CPU workers", value: "\(snapshot.processorCount)")
                    LabeledContent("Physical memory", value: InkribeSettingsSupport.formattedBytes(Int64(snapshot.physicalMemoryBytes)))
                    LabeledContent("Metal device", value: snapshot.metalDeviceName ?? "Unavailable")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            GroupBox("Runtime Policy") {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent(
                        "Transcription",
                        value: "\(snapshot.transcriptionBackend) · \(snapshot.transcriptionThreadCount) threads"
                    )
                    LabeledContent(
                        "Local AI",
                        value: "\(snapshot.aiBackend) · \(snapshot.aiThreadCount) threads · \(snapshot.aiContextSize) context"
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            GroupBox("Bundled Models") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(snapshot.models) { model in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Label(
                                    model.displayName,
                                    systemImage: model.isPresent ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                                )
                                Spacer()
                                Text(model.isPresent ? "Present" : "Missing")
                                    .foregroundStyle(.secondary)
                            }
                            Text("Runtime \(model.runtimeVersion) (\(model.runtimeBuild)) · model \(String(model.revision.prefix(10)))… · \(InkribeSettingsSupport.formattedBytes(model.expectedByteCount)) · \(model.license)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    Text("Presence is a lightweight check. The runtime performs the pinned size/SHA-256 integrity check before first model load.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            GroupBox("Processing Queue") {
                VStack(alignment: .leading, spacing: 8) {
                    if let queue = appState.transcriptionQueue {
                        LabeledContent("State", value: queue.isPaused ? "Paused" : "Ready")
                        LabeledContent("Active", value: "\(queue.activeCount)")
                        LabeledContent("Records", value: "\(queue.items.count)")
                        if let issue = queue.persistenceIssueDescription {
                            Label(issue, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)

                            HStack {
                                Button("Retry Queue Storage") {
                                    retryQueuePersistence()
                                }
                                Button("Reset Queue Storage…", role: .destructive) {
                                    showsQueueResetConfirmation = true
                                }
                            }
                        }
                    } else {
                        Text("Transcription queue unavailable.")
                            .foregroundStyle(.secondary)
                    }

                    if let startupIssue = appState.startupIssue {
                        Label(startupIssue, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if let queueRecoveryMessage {
                        Text(queueRecoveryMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let queueRecoveryError {
                        Text(queueRecoveryError)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    Button("Refresh Diagnostics") {
                        snapshot = .capture()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
        }
        .background(theme.canvas)
        .confirmationDialog(
            "Reset transcription queue storage?",
            isPresented: $showsQueueResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset Queue Storage", role: .destructive) {
                resetQueuePersistence()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes persisted transcription queue records so Inkribe can recover from damaged queue storage. Transcript documents and saved AI results are not deleted, but unfinished jobs will no longer be queued.")
        }
    }

    private func retryQueuePersistence() {
        queueRecoveryMessage = nil
        queueRecoveryError = nil
        do {
            try appState.retryQueuePersistence()
            queueRecoveryMessage = "Queue storage recovered."
        } catch {
            queueRecoveryError = error.localizedDescription
        }
    }

    private func resetQueuePersistence() {
        queueRecoveryMessage = nil
        queueRecoveryError = nil
        do {
            try appState.resetQueuePersistence()
            queueRecoveryMessage = "Queue storage reset. Existing transcript documents were kept."
        } catch {
            queueRecoveryError = error.localizedDescription
        }
    }
}
