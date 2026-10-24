import AppFoundation
import Foundation
import SwiftUI

/// Native iOS settings, following Spokio's AppFoundation-backed sections.
struct SettingsView: View {
    @Environment(ProjectsModel.self) private var model
    @Environment(ThemeManager.self) private var themes
    @Environment(\.appFoundationTheme) private var theme
    let onShowPro: () -> Void
    @State private var sheet: SettingsSheet?

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

            usageSection
                .listRowBackground(theme.surfaceColor)
                .listRowSeparatorTint(theme.borderColor)

            Section("Appearance") {
                ThemePickerView(
                    manager: themes,
                    title: nil,
                    showsCountdown: false,
                    onRequestUpgrade: { sheet = .themes }
                )
                .padding(.vertical, 6)
            }
            .listRowBackground(theme.surfaceColor)
            .listRowSeparatorTint(theme.borderColor)

            Section("Projects & Processing") {
                NavigationLink {
                    ProcessingQueueView()
                } label: {
                    Label("Queue", systemImage: "list.bullet.rectangle")
                }
                Button {
                    sheet = .models
                } label: {
                    Label("Speech Models", systemImage: "cpu")
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
            }
            .listRowBackground(theme.surfaceColor)
            .listRowSeparatorTint(theme.borderColor)

            Section("About") {
                LabeledContent("Transcription", value: "On-device")
                LabeledContent("Version", value: appVersion)
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
        .sheet(item: $sheet) { destination in
            switch destination {
            case .themes: ProUpsell(feature: .themes)
            case .models: SpeechModelsView()
            case .storage: StorageView()
            }
        }
        .task { await model.transcription.refreshAllowance() }
        .onChange(of: model.access.hasPro) { _, _ in
            Task { await model.transcription.refreshAllowance() }
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }

    private var usageSection: some View {
        Section {
            if model.access.hasPro {
                LabeledContent("Captioning", value: "Unlimited")
            } else if let usage = model.transcription.allowance {
                Text(usage.summary)
                ProgressView(
                    value: Double(min(usage.used + usage.reserved, Commerce.weeklySeconds)),
                    total: Double(Commerce.weeklySeconds)
                )
                .accessibilityLabel("Weekly caption allowance")
                .accessibilityValue(usage.summary)
                if usage.reserved > 0 {
                    Text("\(usage.reserved)s reserved for queued work")
                        .font(.caption)
                }
                Text("Resets \(usage.resetsAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if model.transcription.allowanceError == nil && model.transcription.persistenceError == nil {
                ProgressView("Loading allowance…")
            }
            if let issue = model.transcription.persistenceError {
                Text(issue).foregroundStyle(.red).textSelection(.enabled)
                Button("Retry processing storage") { model.transcription.retryStorage() }
            }
            if let error = model.transcription.allowanceError {
                Text(error).foregroundStyle(.red)
                Button("Retry allowance storage") {
                    Task { await model.transcription.refreshAllowance() }
                }
            }
        } header: {
            Text("Usage")
        } footer: {
            Text("Only successful transcription uses your caption allowance. Editing and exporting existing captions do not use more time.")
        }
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
            ]
        )
    }
    #endif
}

private enum SettingsSheet: String, Identifiable {
    case themes, models, storage
    var id: Self { self }
}
