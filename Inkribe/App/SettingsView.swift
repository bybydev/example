import AppFoundation
import Foundation
import SwiftUI

/// Native iOS settings, following Spokio's AppFoundation-backed sections.
struct SettingsView: View {
    @Environment(ProjectsModel.self) private var model
    @Environment(ThemeManager.self) private var themes
    @Environment(\.appFoundationTheme) private var theme
    @Environment(\.queueProjectNavigation) private var openQueueProject
    let onShowPro: () -> Void
    @State private var sheet: SettingsSheet?
    @State private var pendingQueueRoute: QueueProjectRoute?

    var body: some View {
        List {
            ProPlanSettingsSection(
                purchaseManager: model.access.purchases,
                configuration: ProPlanSettingsConfiguration(
                    sectionTitle: "Plan",
                    activePlanTitle: "Inkribe Pro",
                    unlockTitle: "Unlock Inkribe Pro"
                ),
                onUpgrade: onShowPro
            )
            .listRowBackground(theme.surfaceColor)
            .listRowSeparatorTint(theme.borderColor)

            Section("Appearance") {
                ThemePickerView(
                    manager: themes,
                    title: nil,
                    showsCountdown: true,
                    onRequestUpgrade: { sheet = .themes }
                )
                .padding(.vertical, 6)
            }
            .listRowBackground(theme.surfaceColor)
            .listRowSeparatorTint(theme.borderColor)

            Section("Engine") {
                Button {
                    sheet = .models
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Active speech model")
                            Text(model.transcription.models.activeName)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "cpu")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button {
                    sheet = .storage
                } label: {
                    Label("Storage", systemImage: "internaldrive")
                }
            }
            .listRowBackground(theme.surfaceColor)
            .listRowSeparatorTint(theme.borderColor)

            Section("Support") {
                Link(destination: Commerce.supportURL) {
                    Label("Contact Support", systemImage: "envelope")
                }
                Link(destination: Commerce.privacyURL) {
                    Label("Privacy Policy", systemImage: "lock.shield")
                }
                Link(destination: Commerce.termsURL) {
                    Label("Terms of Use", systemImage: "doc.text")
                }
                LabeledContent {
                    Text(appVersion)
                } label: {
                    Label("Version", systemImage: "info.circle")
                }
            }
            .listRowBackground(theme.surfaceColor)
            .listRowSeparatorTint(theme.borderColor)

            #if DEBUG
            Section("Developer") {
                NavigationLink {
                    FoundationDeveloperView(
                        purchaseManager: model.access.purchases,
                        configuration: developerConfiguration
                    )
                    .themedSurface()
                } label: {
                    Label("Developer Tools", systemImage: "hammer.fill")
                }
                .accessibilityIdentifier("settings.developerTools")
            }
            .listRowBackground(theme.surfaceColor)
            .listRowSeparatorTint(theme.borderColor)
            #endif
        }
        .themedSurface()
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $sheet, onDismiss: finishQueueNavigation) { destination in
            switch destination {
            case .themes: ProUpsell(feature: .themes)
            case .models: SpeechModelsView()
            case .storage: StorageView()
            }
        }
        .environment(\.queueProjectNavigation, QueueProjectNavigation { route in
            guard pendingQueueRoute == nil, !model.exports.hasUserDelivery else { return }
            if sheet != nil {
                pendingQueueRoute = route
                sheet = nil
            } else { openQueueProject(route) }
        })
    }

    private func finishQueueNavigation() {
        guard let route = pendingQueueRoute else { return }
        pendingQueueRoute = nil
        openQueueProject(route)
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }

    #if DEBUG
    private var developerConfiguration: FoundationDeveloperConfiguration {
        FoundationDeveloperConfiguration(
            replays: [
                FoundationDeveloperReplay(
                    id: "paywall",
                    title: "Paywall",
                    systemImage: "crown.fill"
                ) { _ in
                    ProPaywall()
                },
                FoundationDeveloperReplay(
                    id: "celebration",
                    title: "Pro Celebration",
                    systemImage: "sparkles"
                ) { _ in
                    ProCelebration()
                }
            ],
            additionalSections: [
                FoundationDeveloperSection(
                    id: "screenshots",
                    title: "App Store",
                    items: [
                        .destination(FoundationDeveloperDestination(
                            id: "screenshot-studio",
                            title: "Screenshot Studio",
                            systemImage: "camera.viewfinder"
                        ) {
                            InkribeScreenshotStudioView()
                        })
                    ]
                )
            ]
        )
    }
    #endif
}

private enum SettingsSheet: String, Identifiable {
    case themes, models, storage
    var id: Self { self }
}
