import InkribeCore
import InkribeExport
import MacAppFoundation
import SwiftUI

@MainActor
struct InkribeMainColumn: View {
    let appState: InkribeAppState
    @Bindable var state: InkribeShellState
    let purchaseManager: PurchaseManager
    let onOpenPlan: () -> Void

    @Environment(\.macAppTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            titlebar

            InkribeShellContentView(
                appState: appState,
                state: state
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            statusBar
        }
        .background(theme.canvas)
        .accessibilityIdentifier("Inkribe.MainColumn")
    }

    private var titlebar: some View {
        HStack(spacing: 12) {
            Text(state.route.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 12)

            if let transcriptID = state.activeTranscriptID {
                transcriptExportMenu(transcriptID)
            }

            ProPlanButton(
                purchaseManager: purchaseManager,
                onUpgrade: onOpenPlan,
                onManagePlan: onOpenPlan
            )
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .frame(height: InkribeShellMetrics.titlebarHeight)
        .background {
            MacAppWindowDragRegion(
                trafficLightReserve: 0,
                background: theme.canvas
            )
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.separator)
                .frame(height: 1)
        }
        .accessibilityIdentifier("Inkribe.MainTitlebar")
    }

    private func transcriptExportMenu(_ transcriptID: TranscriptID) -> some View {
        Menu {
            Button("Copy Edited Transcript") {
                copyTranscript(transcriptID, source: .edited)
            }

            Button("Copy Raw Transcript") {
                copyTranscript(transcriptID, source: .raw)
            }

            Divider()

            Menu("Export Plain Text") {
                Button("Edited…") {
                    exportTranscript(
                        transcriptID,
                        format: .plainText,
                        source: .edited
                    )
                }
                Button("Raw…") {
                    exportTranscript(
                        transcriptID,
                        format: .plainText,
                        source: .raw
                    )
                }
            }

            Menu("Export Markdown") {
                Button("Edited…") {
                    exportTranscript(
                        transcriptID,
                        format: .markdown,
                        source: .edited
                    )
                }
                Button("Raw…") {
                    exportTranscript(
                        transcriptID,
                        format: .markdown,
                        source: .raw
                    )
                }
            }

            Button("Export SRT Subtitles…") {
                exportTranscript(transcriptID, format: .srt)
            }

            Button("Export WebVTT Subtitles…") {
                exportTranscript(transcriptID, format: .vtt)
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
                .frame(width: 20, height: 20)
        }
        .menuStyle(.borderlessButton)
        .help("Copy or export transcript")
        .accessibilityLabel("Transcript export actions")
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Label("Local only", systemImage: "lock.fill")
                .labelStyle(.titleAndIcon)

            Spacer(minLength: 12)

            Text(queueStatusText)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(theme.textMuted)
        .padding(.horizontal, 12)
        .frame(height: InkribeShellMetrics.statusBarHeight)
        .background(theme.surface)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.separator)
                .frame(height: 1)
        }
        .accessibilityIdentifier("Inkribe.MainStatusBar")
    }

    private var queueStatusText: String {
        if appState.startupIssue != nil
            || appState.transcriptionQueue?.persistenceIssueDescription != nil {
            return "Needs attention"
        }
        guard let queue = appState.transcriptionQueue else { return "Ready" }
        if queue.isPaused { return "Queue paused" }
        if queue.activeCount > 0 {
            return queue.activeCount == 1
                ? "Transcribing"
                : "Transcribing \(queue.activeCount)"
        }
        return "Ready"
    }

    private func copyTranscript(
        _ transcriptID: TranscriptID,
        source: TranscriptTextSource
    ) {
        Task { @MainActor in
            do {
                try await TranscriptExportCoordinator.copyTranscript(
                    id: transcriptID,
                    source: source,
                    appState: appState
                )
            } catch {
                TranscriptExportCoordinator.presentFailure(error, operation: "Copy Failed")
            }
        }
    }

    private func exportTranscript(
        _ transcriptID: TranscriptID,
        format: TranscriptExportFormat,
        source: TranscriptTextSource = .edited
    ) {
        Task { @MainActor in
            do {
                _ = try await TranscriptExportCoordinator.exportTranscript(
                    id: transcriptID,
                    format: format,
                    textSource: source,
                    appState: appState
                )
            } catch {
                TranscriptExportCoordinator.presentFailure(error, operation: "Export Failed")
            }
        }
    }
}
