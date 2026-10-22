import AppFoundation
import Foundation
import SwiftUI

struct ProPaywall: View {
    @Environment(ProAccess.self) private var access
    var body: some View {
        FoundationPaywallView(purchases: access.purchases, configuration: Commerce.paywall)
    }
}

struct ProUpsell: View {
    @Environment(ProjectsModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let feature: ProFeature
    var body: some View {
        LimitReachedUpsellFlow(configuration: configuration) { ProPaywall() }
            .onChange(of: model.access.hasPro) { _, hasPro in if hasPro { dismiss() } }
    }
    private var configuration: LimitReachedUpsellConfiguration {
        let message: String
        switch feature {
        case .captioning:
            let usage = model.transcription.allowance
            let reset = usage?.resetsAt.formatted(date: .abbreviated, time: .shortened) ?? "the next weekly reset"
            message = "Free includes 5 minutes of captioning each week. This video needs more time than is available. Your allowance resets \(reset). Existing captions and editing stay available."
        case .styles:
            message = "Unlock every caption font, template and animation. Basic styling and all your existing captions stay available."
        case .fullHD:
            message = "Export captioned videos in 1080p with Pro. You can keep exporting in 720p and saving SRT subtitles for free."
        case .themes:
            message = "Unlock every premium app theme. Your default theme stays free."
        }
        return .init(navigationTitle: feature.title, title: feature.title, message: message,
            symbolName: "crown.fill", rows: Commerce.comparison)
    }
}

struct AppearanceView: View {
    @Environment(ThemeManager.self) private var themes
    @Environment(\.dismiss) private var dismiss
    @State private var upsell = false
    var body: some View {
        NavigationStack {
            ScrollView {
                ThemePickerView(manager: themes, showsCountdown: false, onRequestUpgrade: { upsell = true })
                    .padding(20)
            }
            .themedSurface()
            .navigationTitle("Appearance")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $upsell) { ProUpsell(feature: .themes) }
        }
    }
}

struct PlanView: View {
    @Environment(ProjectsModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showPaywall = false
    @State private var restoreMessage: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Your plan") {
                    LabeledContent("Plan", value: model.access.hasPro ? "Inkribe Pro" : "Free")
                    Button(model.access.hasPro ? "View Pro plans" : "Unlock Inkribe Pro", systemImage: "crown.fill") { showPaywall = true }
                    Button("Restore Purchases") {
                        Task {
                            switch await model.access.purchases.restorePurchases() {
                            case .restored: restoreMessage = "Inkribe Pro restored."
                            case .nothingToRestore: restoreMessage = "No active Inkribe Pro purchase was found."
                            case .failed(let error): restoreMessage = error.localizedDescription
                            }
                        }
                    }
                    .disabled(model.access.purchases.isBusy)
                    Link("Manage Subscription", destination: URL(string: "https://apps.apple.com/account/subscriptions")!)
                }
                if !model.access.hasPro {
                    Section("Caption allowance") {
                        if let usage = model.transcription.allowance {
                            Text(usage.summary)
                            ProgressView(value: Double(usage.used + usage.reserved), total: Double(Commerce.weeklySeconds))
                            if usage.reserved > 0 { Text("\(usage.reserved)s reserved for queued work").font(.caption) }
                            Text("Resets \(usage.resetsAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        } else { ProgressView("Loading allowance…") }
                        if let error = model.transcription.allowanceError {
                            Text(error).foregroundStyle(.red)
                            Button("Retry allowance storage") { Task { await model.transcription.refreshAllowance() } }
                        }
                        Text("Only successful transcription uses the allowance. Editing and exporting existing captions do not use more time.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .themedSurface()
            .navigationTitle("Inkribe Pro")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showPaywall) { ProPaywall() }
            .task { await model.transcription.refreshAllowance() }
            .alert("Restore Purchases", isPresented: Binding(get: { restoreMessage != nil }, set: { if !$0 { restoreMessage = nil } })) {
                Button("OK", role: .cancel) { restoreMessage = nil }
            } message: { Text(restoreMessage ?? "") }
        }
    }
}

/// AF supplies theme state, tokens, picker and purchase access. This adapter
/// paints app surfaces; footage and caption artwork retain their own colors.
private struct ThemedSurface: ViewModifier {
    @Environment(\.appFoundationTheme) private var theme
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background { AppThemeBackground(theme: theme) }
            .foregroundStyle(theme.primaryForegroundColor)
            .tint(theme.accentColor)
            .toolbarBackground(theme.backgroundColor, for: .navigationBar)
    }
}

extension View {
    func themedSurface() -> some View { modifier(ThemedSurface()) }
}
