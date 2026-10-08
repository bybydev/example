import AppFoundation
import SwiftUI

private struct ReadAloudThemeSurface: ViewModifier {
    @Environment(\.appFoundationTheme) private var theme

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .foregroundStyle(theme.primaryForegroundColor)
            .background(theme.backgroundColor.ignoresSafeArea())
            .toolbarBackground(theme.backgroundColor, for: .navigationBar)
    }
}

extension View {
    func readAloudThemeSurface() -> some View {
        modifier(ReadAloudThemeSurface())
    }
}

/// Shares the theme's grouped-row surfaces across Library, Settings,
/// project details, and their information sheets.
struct ReadAloudThemedList<Content: View>: View {
    @Environment(\.appFoundationTheme) private var theme
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        List {
            Group {
                content
            }
            .listRowBackground(theme.surfaceColor)
        }
        .readAloudThemeSurface()
    }
}
