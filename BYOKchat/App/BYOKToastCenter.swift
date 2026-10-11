import AppFoundation
import SwiftUI
import UIKit

@MainActor
@Observable
final class BYOKToastCenter {
    enum Style: Sendable {
        case success
        case warning
        case error

        var systemImage: String {
            switch self {
            case .success: "checkmark.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .error: "xmark.octagon.fill"
            }
        }

        var tint: Color {
            switch self {
            case .success: .green
            case .warning: .orange
            case .error: .red
            }
        }

        var duration: Duration {
            switch self {
            case .success: .seconds(2)
            case .warning: .seconds(3)
            // Failures carry the longest copy and deserve reading time.
            case .error: .seconds(6)
            }
        }

        var haptic: UINotificationFeedbackGenerator.FeedbackType {
            switch self {
            case .success: .success
            case .warning: .warning
            case .error: .error
            }
        }
    }

    struct Message: Identifiable, Equatable {
        let id = UUID()
        let style: Style
        let text: String

        static func == (lhs: Message, rhs: Message) -> Bool {
            lhs.id == rhs.id
        }
    }

    private(set) var current: Message?
    private var dismissTask: Task<Void, Never>?
    private let hapticGenerator = UINotificationFeedbackGenerator()

    func show(_ style: Style, _ text: String) {
        let message = Message(style: style, text: text)
        dismissTask?.cancel()

        // Toasts now only surface outcomes with no on-screen feedback, so the
        // signal uses a matching haptic and an announcement for VoiceOver.
        hapticGenerator.prepare()
        hapticGenerator.notificationOccurred(style.haptic)
        UIAccessibility.post(notification: .announcement, argument: text)

        withAnimation(.snappy(duration: 0.28)) {
            current = message
        }

        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: style.duration)
            guard !Task.isCancelled else { return }
            self?.dismiss(id: message.id)
        }
    }

    func success(_ text: String) { show(.success, text) }
    func warning(_ text: String) { show(.warning, text) }
    func error(_ text: String) { show(.error, text) }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        withAnimation(.snappy(duration: 0.22)) {
            current = nil
        }
    }

    private func dismiss(id: UUID) {
        guard current?.id == id else { return }
        dismiss()
    }
}

/// Floating glass confirmation adapted from Spokio iOS. Only the card receives
/// touches; scrolling and controls beneath the rest of the overlay stay usable.
struct BYOKToastOverlay: View {
    let center: BYOKToastCenter
    @Environment(\.appFoundationTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let toast = center.current {
                card(for: toast)
                    .frame(maxWidth: 460)
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .transition(
                        reduceMotion ? .opacity :
                            .move(edge: .top).combined(with: .opacity)
                    )
            }
        }
        .animation(
            reduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: 0.28),
            value: center.current
        )
    }

    private func card(for toast: BYOKToastCenter.Message) -> some View {
        let tint = toast.style == .success ? theme.accentColor : toast.style.tint
        return Button {
            center.dismiss()
        } label: {
            HStack(spacing: 11) {
                Image(systemName: toast.style.systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.14), in: Circle())
                    .accessibilityHidden(true)

                Text(toast.text)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.primaryForegroundColor)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)

                Spacer(minLength: 0)
            }
            .padding(.leading, 10)
            .padding(.trailing, 14)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular.interactive(),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .gesture(
            DragGesture(minimumDistance: 10).onEnded { value in
                if abs(value.translation.height) > 36 { center.dismiss() }
            }
        )
        .accessibilityLabel(toast.text)
        .accessibilityHint("Tap or swipe to dismiss")
    }
}

extension View {
    /// Each modal surface can own a center so feedback appears above that
    /// surface, rather than behind its sheet. Descendants inherit its center.
    func byokToastOverlay(_ center: BYOKToastCenter) -> some View {
        overlay(alignment: .top) {
            BYOKToastOverlay(center: center)
        }
        .environment(center)
    }
}
