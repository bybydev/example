import InkribeCore
import SwiftUI

@MainActor
struct InkribeShellContentView: View {
    let appState: InkribeAppState
    @Bindable var state: InkribeShellState

    var body: some View {
        Group {
            if let startupIssue = appState.startupIssue {
                ContentUnavailableView(
                    "Inkribe couldn't start",
                    systemImage: "exclamationmark.triangle",
                    description: Text(startupIssue)
                )
            } else {
                content
            }
        }
        .accessibilityIdentifier("Inkribe.MainContent")
    }

    @ViewBuilder
    private var content: some View {
        switch state.route {
        case .library:
            LibraryView(
                appState: appState,
                onOpenTranscript: state.openTranscript,
                onRecord: { state.select(.record) },
                onImport: { state.select(.import) }
            )

        case .record:
            RecordView(
                appState: appState,
                onOpenTranscript: state.openTranscript
            )

        case .import:
            ImportView(
                appState: appState,
                onOpenTranscript: state.openTranscript
            )

        case .transcript(let transcriptID):
            TranscriptEditorView(
                transcriptID: transcriptID,
                appState: appState
            )
        }
    }
}
