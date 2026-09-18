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
    @Environment(\.openWindow) private var openWindow

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
                onUpgrade: openPaywall
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

    private func openPaywall() {
        openWindow(id: InkribeWindowID.proPaywall)
    }
}
