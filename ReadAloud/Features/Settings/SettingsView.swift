import AppFoundation
import SwiftUI

struct SettingsView: View {
    @Environment(PurchaseManager.self) private var purchases
    @Environment(ThemeManager.self) private var themes

    private var version: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        let build = Bundle.main.object(
            forInfoDictionaryKey: kCFBundleVersionKey as String
        ) as? String
        return "\(version ?? "—") (\(build ?? "—"))"
    }

    #if DEBUG
    private var developerConfiguration: FoundationDeveloperConfiguration {
        FoundationDeveloperConfiguration(
            additionalSections: [
                FoundationDeveloperSection(
                    title: "ReadAloud",
                    items: [
                        .destination(
                            FoundationDeveloperDestination(
                                title: "Kokoro Prototype",
                                systemImage: "waveform"
                            ) {
                                ReaderView()
                            }
                        )
                    ]
                )
            ]
        )
    }
    #endif

    var body: some View {
        List {
            Section("Appearance") {
                ThemePickerView(
                    manager: themes,
                    title: nil,
                    showsCountdown: false,
                    onRequestUpgrade: {}
                )
                .padding(.vertical, 6)
            }

            Section("About") {
                LabeledContent("Synthesis", value: "On-device")
                LabeledContent("Version", value: version)
            }

            #if DEBUG
            Section("Developer") {
                NavigationLink {
                    FoundationDeveloperView(
                        purchaseManager: purchases,
                        configuration: developerConfiguration
                    )
                } label: {
                    Label("Developer Tools", systemImage: "hammer.fill")
                }
            }
            #endif
        }
        .navigationTitle("Settings")
    }
}
