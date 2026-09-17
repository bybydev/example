import MacAppFoundation
import SwiftUI

private extension MacAppSettingsPaneID {
    static let inkribeGeneral: Self = "inkribe.general"
    static let inkribeAbout: Self = "inkribe.about"
}

@MainActor
struct InkribeSettingsView: View {
    let purchaseManager: PurchaseManager
    let themeStore: MacAppThemeStore
    let settingsRouter: MacAppSettingsRouter

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
                subtitle: "Core Inkribe behavior.",
                systemImage: "gearshape"
            ) {
                InkribeGeneralSettingsPane()
            },
            .appearance(themeStore: themeStore),
            .plan(
                purchaseManager: purchaseManager,
                configuration: ProPlanPaneConfiguration(appName: "Inkribe"),
                onUpgrade: purchasePreferredPlan
            ),
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
    @Environment(\.macAppTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Privacy") {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Transcription is designed to run locally on this Mac.", systemImage: "lock.shield")
                        Label("No account or API key is required for the core workflow.", systemImage: "person.crop.circle.badge.xmark")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
            }
            .padding(22)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .background(theme.canvas)
    }
}

private struct InkribeAboutSettingsPane: View {
    @Environment(\.macAppTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Inkribe") {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Product", value: "Offline speech-to-text workspace")
                        LabeledContent("Processing", value: "Local by design")
                        LabeledContent("Platform", value: "macOS")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(22)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .background(theme.canvas)
    }
}
