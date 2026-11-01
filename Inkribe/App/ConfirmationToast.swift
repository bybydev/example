import SwiftUI
import UIKit

/// A fresh identity restarts dismissal even when successive confirmations match.
struct ConfirmationToast: Identifiable, Equatable {
    let id = UUID()
    let text: String
}

/// Spokio iOS's success-toast presentation, owned by the visible sheet so it
/// appears above its navigation and scrolling content rather than behind it.
@MainActor
private struct ConfirmationToastPresentation: ViewModifier {
    @Binding var toast: ConfirmationToast?

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            VStack(spacing: 0) {
                if let toast {
                    card(for: toast)
                        .padding(.horizontal, 14)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.28), value: toast?.id)
        }
        .task(id: toast?.id) {
            guard let message = toast else { return }
            let haptic = UINotificationFeedbackGenerator()
            haptic.prepare()
            haptic.notificationOccurred(.success)
            UIAccessibility.post(notification: .announcement, argument: message.text)

            do { try await Task.sleep(for: .seconds(2)) }
            catch { return }
            guard !Task.isCancelled, toast?.id == message.id else { return }
            toast = nil
        }
        .onDisappear { toast = nil }
    }

    private func card(for message: ConfirmationToast) -> some View {
        Button { toast = nil } label: {
            HStack(spacing: 11) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
                    .frame(width: 30, height: 30)
                    .background(Color.green.opacity(0.14), in: Circle())
                Text(message.text)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                Spacer(minLength: 0)
            }
            .padding(.leading, 10)
            .padding(.trailing, 14)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .gesture(
            DragGesture(minimumDistance: 10).onEnded { value in
                if abs(value.translation.height) > 36 { toast = nil }
            }
        )
        .accessibilityLabel(message.text)
        .accessibilityHint("Tap or swipe to dismiss")
    }
}

extension View {
    @MainActor
    func confirmationToast(_ toast: Binding<ConfirmationToast?>) -> some View {
        modifier(ConfirmationToastPresentation(toast: toast))
    }
}
