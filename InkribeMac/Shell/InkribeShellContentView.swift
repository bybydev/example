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
            ContentUnavailableView(
                "Record Audio",
                systemImage: "waveform.circle",
                description: Text("Capture speech locally and turn it into an editable transcript.")
            )

        case .import:
            ContentUnavailableView(
                "Import Audio or Video",
                systemImage: "square.and.arrow.down",
                description: Text("Bring in audio or video files for private local transcription.")
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
