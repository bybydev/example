import MacAppFoundation
import SwiftUI

struct InkribeRootView: View {
    let appState: InkribeAppState

    var body: some View {
        VStack(spacing: 12) {
            Text("Inkribe")
                .font(.title2.weight(.semibold))

            if let startupIssue = appState.startupIssue {
                ContentUnavailableView(
                    "Inkribe couldn't start",
                    systemImage: "exclamationmark.triangle",
                    description: Text(startupIssue)
                )
            } else {
                Text("Private offline transcription")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}
