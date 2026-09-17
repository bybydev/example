import AppKit
import InkribeAudio
import InkribeTranscription
import MacAppFoundation
import SwiftUI

private extension MacAppSettingsPaneID {
    static let inkribeGeneral: Self = "inkribe.general"
    static let inkribeTranscription: Self = "inkribe.transcription"
    static let inkribeAI: Self = "inkribe.ai"
    static let inkribeStorage: Self = "inkribe.storage"
    static let inkribeDiagnostics: Self = "inkribe.diagnostics"
    static let inkribeAbout: Self = "inkribe.about"
}

@MainActor
struct InkribeSettingsView: View {
    let purchaseManager: PurchaseManager
    let themeStore: MacAppThemeStore
    let settingsRouter: MacAppSettingsRouter
    let appState: InkribeAppState

    @State private var preferences = InkribePreferences.shared

    var body: some View {
        MacAppSettingsView(
            panes: panes,
            initialSelection: .inkribeGeneral,
            router: settingsRouter
        )
    }

    private var panes: [MacAppSettingsPane] {
        [
            MacAppSettingsPane(
                id: .inkribeGeneral,
                title: "General",
                subtitle: "Privacy and workflow defaults.",
                systemImage: "gearshape"
            ) {
                InkribeGeneralSettingsPane(preferences: preferences)
            },
            MacAppSettingsPane(
                id: .inkribeTranscription,
                title: "Transcription",
                subtitle: "Recording and language defaults.",
                systemImage: "waveform"
            ) {
                InkribeTranscriptionSettingsPane(
                    recorder: appState.microphoneRecorder,
                    preferences: preferences
                )
            },
            MacAppSettingsPane(
                id: .inkribeAI,
                title: "AI Cleanup",
                subtitle: "Local AI memory behavior.",
                systemImage: "sparkles"
            ) {
                InkribeAISettingsPane(preferences: preferences)
            },
            MacAppSettingsPane(
                id: .inkribeStorage,
                title: "Storage",
                subtitle: "Local data usage and cleanup.",
                systemImage: "internaldrive"
            ) {
                InkribeStorageSettingsPane(appState: appState)
            },
            .appearance(themeStore: themeStore),
            .plan(
                purchaseManager: purchaseManager,
                configuration: ProPlanPaneConfiguration(appName: "Inkribe"),
                onUpgrade: purchasePreferredPlan
            ),
            MacAppSettingsPane(
                id: .inkribeDiagnostics,
                title: "Diagnostics",
                subtitle: "Local runtime and model status.",
                systemImage: "stethoscope"
            ) {
                InkribeDiagnosticsSettingsPane(appState: appState)
            },
            MacAppSettingsPane(
                id: .inkribeAbout,
                title: "About",
                subtitle: "About Inkribe and local processing.",
                systemImage: "info.circle"
            ) {
                InkribeAboutSettingsPane()
            }
        ]
    }

    private func purchasePreferredPlan() {
        Task { @MainActor in
            await purchaseManager.prepare()
            guard let product = purchaseManager.preferredEntitlementProduct else { return }
            _ = await purchaseManager.purchase(product)
        }
    }
}

private struct InkribeGeneralSettingsPane: View {
    @Bindable var preferences: InkribePreferences
    @Environment(\.macAppTheme) private var theme
    @State private var showsResetConfirmation = false

    var body: some View {
        settingsScroll {
            GroupBox("Privacy") {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Transcription and AI processing run locally on this Mac.", systemImage: "lock.shield")
                    Label("No account or API key is required for the core workflow.", systemImage: "person.crop.circle.badge.xmark")
                    Label("Transcript, prompt, and generated content are not written to diagnostics by default.", systemImage: "doc.text.magnifyingglass")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            GroupBox("Workflow Defaults") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Transcription and AI panes contain the defaults used when new work starts. Individual recordings and imports can still override language before queueing.")
                        .foregroundStyle(.secondary)
                    Button("Reset Workflow Defaults…", role: .destructive) {
                        showsResetConfirmation = true
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
        }
        .background(theme.canvas)
        .confirmationDialog(
            "Reset workflow defaults?",
            isPresented: $showsResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset Defaults", role: .destructive) {
                preferences.resetWorkflowDefaults()
                Task { await TranscriptLocalAIController.shared.unloadModel() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This resets default language, microphone selection, and local AI model retention. Existing transcripts are unchanged.")
        }
    }
}

private struct InkribeTranscriptionSettingsPane: View {
    let recorder: MicrophoneRecorder
    @Bindable var preferences: InkribePreferences
    @Environment(\.macAppTheme) private var theme

    private var savedMicrophoneIsUnavailable: Bool {
        guard let saved = preferences.defaultMicrophoneDeviceID else { return false }
        return !recorder.availableDevices.contains(where: { $0.id == saved })
    }

    var body: some View {
        settingsScroll {
            GroupBox("Defaults") {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Language", selection: $preferences.defaultTranscriptionLanguage) {
                        ForEach(TranscriptionLanguageCatalog.options) { option in
                            Text(option.displayName).tag(option.code)
                        }
                    }
                    .frame(maxWidth: 320)

                    Picker("Microphone", selection: $preferences.defaultMicrophoneDeviceID) {
                        Text("System Default")
                            .tag(Optional<String>.none)

                        if let saved = preferences.defaultMicrophoneDeviceID,
                           savedMicrophoneIsUnavailable {
                            Text("Saved Microphone — Unavailable")
                                .tag(Optional(saved))
                        }

                        ForEach(recorder.availableDevices) { device in
                            Text(device.isDefault ? "\(device.name) — Current System Default" : device.name)
                                .tag(Optional(device.id))
                        }
                    }
                    .frame(maxWidth: 420)

                    HStack {
                        Text("System Default follows the current macOS input device. A specifically selected microphone is remembered by device ID.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Refresh") {
                            recorder.refreshInputDevices()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            GroupBox("Performance") {
                Text("Inkribe selects its transcription backend and worker count automatically for the current Mac. Low-level GPU and thread controls are intentionally not exposed as user settings.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
        }
        .background(theme.canvas)
        .task {
            recorder.refreshInputDevices()
        }
    }
}

private struct InkribeAISettingsPane: View {
    @Bindable var preferences: InkribePreferences
    @Environment(\.macAppTheme) private var theme

    var body: some View {
        settingsScroll {
            GroupBox("Model Memory") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(
                        "Keep local AI model loaded between actions",
                        isOn: $preferences.keepAIModelLoaded
                    )
                    Text(
                        preferences.keepAIModelLoaded
                            ? "Repeated Clean, Polish, Summary, Notes, and Action Items operations start faster, but Inkribe uses more memory while idle."
                            : "Inkribe releases the local AI model after every completed, cancelled, or failed action to reduce idle memory use."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            GroupBox("Privacy") {
                Label("AI cleanup always uses the bundled local runtime; this setting never enables a network provider.", systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
        }
        .background(theme.canvas)
        .onChange(of: preferences.keepAIModelLoaded) { _, keepLoaded in
            guard !keepLoaded else { return }
            Task { await TranscriptLocalAIController.shared.unloadModel() }
        }
    }
}

private struct InkribeStorageSettingsPane: View {
    let appState: InkribeAppState

    @Environment(\.macAppTheme) private var theme
    @State private var snapshot: InkribeStorageSnapshot?
    @State private var isLoading = false
    @State private var isCleaning = false
    @State private var showsCleanupConfirmation = false
    @State private var statusMessage: String?
    @State private var errorDescription: String?

    var body: some View {
        settingsScroll {
            GroupBox("Local Data") {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Source media", value: formattedBytes(snapshot?.sourceMediaBytes ?? 0))
                    LabeledContent("Transcript library", value: formattedBytes(snapshot?.transcriptStoreBytes ?? 0))
                    LabeledContent("Queue state", value: formattedBytes(snapshot?.queueStoreBytes ?? 0))
                    LabeledContent("Transcripts", value: "\(snapshot?.transcriptCount ?? 0)")
                    Divider()
                    LabeledContent("App data total", value: formattedBytes(snapshot?.appDataBytes ?? 0))
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
            statusMessage = "Removed media from \(result.removedTranscriptCount) transcript(s), reclaimed \(formattedBytes(result.reclaimedBytes)). \(result.skippedTranscriptCount) transcript(s) were kept for unfinished or retryable work."
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

private struct InkribeDiagnosticsSettingsPane: View {
    let appState: InkribeAppState

    @Environment(\.macAppTheme) private var theme
    @State private var snapshot = InkribeRuntimeDiagnosticsSnapshot.capture()

    var body: some View {
        settingsScroll {
            GroupBox("System") {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Architecture", value: snapshot.architecture)
                    LabeledContent("CPU workers", value: "\(snapshot.processorCount)")
                    LabeledContent("Physical memory", value: formattedBytes(Int64(snapshot.physicalMemoryBytes)))
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
                            Text("Runtime \(model.runtimeVersion) (\(model.runtimeBuild)) · model \(String(model.revision.prefix(10)))… · \(formattedBytes(model.expectedByteCount)) · \(model.license)")
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

                    Button("Refresh Diagnostics") {
                        snapshot = .capture()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
        }
        .background(theme.canvas)
    }
}

private struct InkribeAboutSettingsPane: View {
    @Environment(\.macAppTheme) private var theme

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    var body: some View {
        settingsScroll {
            GroupBox("Inkribe") {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Product", value: "Offline speech-to-text workspace")
                    LabeledContent("Processing", value: "Local by design")
                    LabeledContent("Platform", value: "macOS")
                    LabeledContent("Version", value: "\(version) (\(build))")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
        }
        .background(theme.canvas)
    }
}

@ViewBuilder
private func settingsScroll<Content: View>(
    @ViewBuilder content: () -> Content
) -> some View {
    ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            content()
        }
        .padding(22)
        .frame(maxWidth: 760, alignment: .leading)
    }
}

private func formattedBytes(_ value: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: max(0, value), countStyle: .file)
}
