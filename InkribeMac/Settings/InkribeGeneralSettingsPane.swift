import MacAppFoundation
import SwiftUI

struct InkribeGeneralSettingsPane: View {
    @Bindable var preferences: InkribePreferences
    @Environment(\.macAppTheme) private var theme
    @State private var showsResetConfirmation = false

    var body: some View {
        InkribeSettingsSupport.scroll {
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
