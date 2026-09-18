import MacAppFoundation
import SwiftUI

struct InkribeAISettingsPane: View {
    @Bindable var preferences: InkribePreferences
    @Environment(\.macAppTheme) private var theme

    var body: some View {
        InkribeSettingsSupport.scroll {
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
