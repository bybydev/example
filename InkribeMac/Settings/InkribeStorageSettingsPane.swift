import AppKit
import MacAppFoundation
import SwiftUI

struct InkribeStorageSettingsPane: View {
    let appState: InkribeAppState

    @Environment(\.macAppTheme) private var theme
    @State private var snapshot: InkribeStorageSnapshot?
    @State private var isLoading = false
    @State private var isCleaning = false
    @State private var showsCleanupConfirmation = false
    @State private var statusMessage: String?
    @State private var errorDescription: String?

    var body: some View {
        InkribeSettingsSupport.scroll {
            GroupBox("Local Data") {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Source media", value: InkribeSettingsSupport.formattedBytes(snapshot?.sourceMediaBytes ?? 0))
                    LabeledContent("Transcript library", value: InkribeSettingsSupport.formattedBytes(snapshot?.transcriptStoreBytes ?? 0))
                    LabeledContent("Queue state", value: InkribeSettingsSupport.formattedBytes(snapshot?.queueStoreBytes ?? 0))
                    LabeledContent("Transcripts", value: "\(snapshot?.transcriptCount ?? 0)")
                    Divider()
                    LabeledContent("App data total", value: InkribeSettingsSupport.formattedBytes(snapshot?.appDataBytes ?? 0))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            GroupBox("Manage Storage") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Removing finished source media keeps transcript text, timestamps, AI results, and exports, but removes playback for those transcripts. Media needed by unfinished or retryable queue work is skipped.")
                        .foregroundStyle(.secondary)

                    HStack {
                        Button("Show Data Folder") {
                            showDataFolder()
                        }
                        Button("Refresh") {
                            Task { await refresh() }
                        }
                        .disabled(isLoading || isCleaning)
                        Spacer()
                        Button("Remove Finished Source Media…", role: .destructive) {
                            showsCleanupConfirmation = true
                        }
                        .disabled(isLoading || isCleaning || (snapshot?.sourceMediaBytes ?? 0) == 0)
                    }

                    if isLoading || isCleaning {
                        ProgressView()
                            .controlSize(.small)
                    }
                    if let statusMessage {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let errorDescription {
                        Text(errorDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
        }
        .background(theme.canvas)
        .task {
            await refresh()
        }
        .confirmationDialog(
            "Remove source media for finished transcripts?",
            isPresented: $showsCleanupConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove Source Media", role: .destructive) {
                Task { await cleanupFinishedMedia() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Transcript text remains available, but cleaned transcripts will no longer have their original audio or video for playback.")
        }
    }

    private func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        errorDescription = nil
        defer { isLoading = false }
        do {
            snapshot = try await appState.storageSnapshot()
        } catch {
            errorDescription = error.localizedDescription
        }
    }

    private func cleanupFinishedMedia() async {
        guard !isCleaning else { return }
        isCleaning = true
        statusMessage = nil
        errorDescription = nil
        defer { isCleaning = false }

        do {
            let result = try await appState.removeSourceMediaForFinishedTranscripts()
            statusMessage = "Removed media from \(result.removedTranscriptCount) transcript(s), reclaimed \(InkribeSettingsSupport.formattedBytes(result.reclaimedBytes)). \(result.skippedTranscriptCount) transcript(s) were kept for unfinished or retryable work."
            snapshot = try await appState.storageSnapshot()
        } catch {
            errorDescription = error.localizedDescription
        }
    }

    private func showDataFolder() {
        do {
            let directory = try InkribeAppDirectories.applicationSupportDirectory()
            NSWorkspace.shared.activateFileViewerSelecting([directory])
        } catch {
            errorDescription = error.localizedDescription
        }
    }
}
