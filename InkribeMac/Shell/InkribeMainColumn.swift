import InkribeCore
import InkribeExport
import InkribeTranscription
import MacAppFoundation
import SwiftUI

@MainActor
struct InkribeMainColumn: View {
    let appState: InkribeAppState
    @Bindable var state: InkribeShellState
    let purchaseManager: PurchaseManager
    let onOpenPlan: () -> Void
    let onOpenPaywall: () -> Void

    @Environment(\.macAppTheme) private var theme
    @State private var upsellCapability: InkribeProCapability?

    var body: some View {
        VStack(spacing: 0) {
            titlebar

            InkribeShellContentView(
                appState: appState,
                state: state,
                purchaseManager: purchaseManager,
                onOpenPaywall: onOpenPaywall
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            statusBar
        }
        .background(theme.canvas)
        .accessibilityIdentifier("Inkribe.MainColumn")
        .sheet(item: $upsellCapability) { capability in
            InkribeProUpsellView(
                capability: capability,
                onUpgrade: {
                    upsellCapability = nil
                    onOpenPaywall()
                },
                onDismiss: {
                    upsellCapability = nil
                }
            )
        }
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
                onUpgrade: onOpenPaywall,
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
                TranscriptExportActions.copy(
                    id: transcriptID,
                    source: .edited,
                    appState: appState
                )
            }

            Button("Copy Raw Transcript") {
                TranscriptExportActions.copy(
                    id: transcriptID,
                    source: .raw,
                    appState: appState
                )
            }

            Divider()

            Menu("Export Plain Text") {
                Button("Edited…") {
                    TranscriptExportActions.export(
                        id: transcriptID,
                        format: .plainText,
                        textSource: .edited,
                        appState: appState
                    )
                }
                Button("Raw…") {
                    TranscriptExportActions.export(
                        id: transcriptID,
                        format: .plainText,
                        textSource: .raw,
                        appState: appState
                    )
                }
            }

            Menu("Export Markdown") {
                Button("Edited…") {
                    TranscriptExportActions.export(
                        id: transcriptID,
                        format: .markdown,
                        textSource: .edited,
                        appState: appState
                    )
                }
                Button("Raw…") {
                    TranscriptExportActions.export(
                        id: transcriptID,
                        format: .markdown,
                        textSource: .raw,
                        appState: appState
                    )
                }
            }

            Button {
                requestSubtitleExport(.srt, transcriptID: transcriptID)
            } label: {
                HStack {
                    Text("Export SRT Subtitles…")
                    if !purchaseManager.hasPro {
                        ProBadge(style: .icon)
                    }
                }
            }

            Button {
                requestSubtitleExport(.vtt, transcriptID: transcriptID)
            } label: {
                HStack {
                    Text("Export WebVTT Subtitles…")
                    if !purchaseManager.hasPro {
                        ProBadge(style: .icon)
                    }
                }
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
                .frame(width: 20, height: 20)
        }
        .menuStyle(.borderlessButton)
        .help("Copy or export transcript")
        .accessibilityLabel("Transcript export actions")
    }

    private func requestSubtitleExport(
        _ format: TranscriptExportFormat,
        transcriptID: TranscriptID
    ) {
        switch InkribeProCapability.subtitleExport.decision(hasPro: purchaseManager.hasPro) {
        case .allowed:
            TranscriptExportActions.export(
                id: transcriptID,
                format: format,
                appState: appState
            )
        case .requiresPro:
            upsellCapability = .subtitleExport
        }
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
}
