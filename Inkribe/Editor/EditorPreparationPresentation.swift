import AppFoundation
import SwiftUI

/// The overlay belongs to this editor, never to the application's window.
/// Its Cancel button is outside the disabled/hidden editor subtree.
struct EditorPreparationPresentation: ViewModifier {
    // Temporarily hide editor-loading UI. Restore it here without changing preparation.
    static let showsLoadingIndicators = false

    @Environment(\.appFoundationTheme) private var theme
    let isPreparing: Bool
    let cancel: () -> Void
    @State private var showsIndicator = false

    func body(content: Content) -> some View {
        content
            .blur(radius: isPreparing && showsIndicator ? 8 : 0)
            .overlay {
                if isPreparing && showsIndicator {
                    ZStack {
                        theme.backgroundColor.opacity(0.65).ignoresSafeArea(edges: .bottom)
                        VStack(spacing: 18) {
                            EditorPreparationSpinner().frame(width: 42, height: 42)
                            Text("Preparing project…").font(.headline).multilineTextAlignment(.center)
                            Button("Cancel", action: cancel)
                                .buttonStyle(.bordered).frame(minWidth: 100, minHeight: 44)
                                .accessibilityHint("Stop preparing and go back")
                        }
                        .padding(24)
                        .background(theme.surfaceColor, in: RoundedRectangle(cornerRadius: 20))
                        .padding(20)
                    }
                    .accessibilityElement(children: .contain)
                }
            }
            .task(id: isPreparing) {
                showsIndicator = false
                guard Self.showsLoadingIndicators, isPreparing else { return }
                do { try await Task.sleep(for: .milliseconds(180)) }
                catch { return }
                guard !Task.isCancelled else { return }
                showsIndicator = true
            }
    }
}

private struct EditorPreparationSpinner: View {
    @Environment(\.appFoundationTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            ZStack {
                Circle().stroke(theme.accentColor.opacity(0.15), lineWidth: 4)
                Circle().trim(from: 0, to: 0.72)
                    .stroke(theme.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(reduceMotion ? -90 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360))
            }
        }
        .accessibilityHidden(true)
    }
}
