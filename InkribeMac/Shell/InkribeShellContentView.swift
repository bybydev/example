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
            ContentUnavailableView {
                Label("No Transcripts Yet", systemImage: "doc.text.magnifyingglass")
            } description: {
                Text("Record audio or import a file to create your first local transcript.")
            } actions: {
                HStack {
                    Button("Record Audio") { state.select(.record) }
                    Button("Import File") { state.select(.import) }
                }
            }

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
            InkribeTranscriptSurfacePlaceholder(transcriptID: transcriptID)
        }
    }
}

private struct InkribeTranscriptSurfacePlaceholder: View {
    let transcriptID: TranscriptID

    var body: some View {
        ContentUnavailableView(
            "Transcript",
            systemImage: "doc.text",
            description: Text("Transcript \(transcriptID.rawValue.uuidString.prefix(8)) is ready for editing.")
        )
    }
}
