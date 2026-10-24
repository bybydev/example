import AppFoundation
import Foundation
import SwiftUI

struct ProPaywall: View {
    @Environment(ProAccess.self) private var access
    var body: some View {
        AppFoundation.ProPaywallView(purchases: access.purchases, configuration: Commerce.paywall)
    }
}

struct ProCelebration: View {
    var body: some View {
        AppFoundation.ProCelebrationView(configuration: Commerce.celebration)
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
            // Keep the native bar/Back gesture over the continuous themed page.
            // A flat theme.backgroundColor caused the black strip after scrolling.
            .toolbarBackground(.hidden, for: .navigationBar)
    }
}

extension View {
    func themedSurface() -> some View { modifier(ThemedSurface()) }
}
