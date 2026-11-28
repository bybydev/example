import AppKit
import Foundation
import MacAppFoundation
import Observation
import SwiftUI

@MainActor
@Observable
final class MacToastCenter {
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
      case .success: .seconds(2.4)
      case .warning: .seconds(4.0)
      case .error: .seconds(6.0)
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

  func show(_ style: Style, _ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    let message = Message(style: style, text: trimmed)
    dismissTask?.cancel()

    if let app = NSApp {
      NSAccessibility.post(
        element: app,
        notification: .announcementRequested,
        userInfo: [.announcement: trimmed]
      )
    }

    withAnimation(.snappy(duration: 0.24)) {
      current = message
    }

    dismissTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: style.duration)
      guard !Task.isCancelled else { return }
      self?.dismiss(id: message.id)
    }
  }

  func showStatus(_ text: String) {
    let lowercased = text.lowercased()
    let style: Style =
      (lowercased.contains("failed") || lowercased.contains("warning") || lowercased.contains("could not"))
      ? .warning
      : .success
    show(style, text)
  }

  func success(_ text: String) { show(.success, text) }
  func warning(_ text: String) { show(.warning, text) }
  func error(_ text: String) { show(.error, text) }

  func dismiss() {
    dismissTask?.cancel()
    dismissTask = nil
    withAnimation(.snappy(duration: 0.18)) {
      current = nil
    }
  }

  private func dismiss(id: UUID) {
    guard current?.id == id else { return }
    dismiss()
  }
}

struct MacToastOverlay: View {
  let center: MacToastCenter
  var topInset: CGFloat = MacDesignTokens.Layout.titlebarHeight + 12

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Group {
      if let toast = center.current {
        MacToastCard(toast: toast) {
          center.dismiss()
        }
        .frame(maxWidth: 380, alignment: .trailing)
        .padding(.top, topInset)
        .padding(.trailing, 16)
        .padding(.leading, 16)
        .transition(
          reduceMotion
            ? .opacity
            : .move(edge: .top).combined(with: .opacity)
        )
      }
    }
    .animation(
      reduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: 0.24),
      value: center.current
    )
  }
}

private struct MacToastCard: View {
  let toast: MacToastCenter.Message
  let dismiss: () -> Void

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.macAppTheme) private var theme
  @State private var isHovered = false

  private var isDark: Bool { colorScheme == .dark }

  var body: some View {
    let tint = toast.style.tint
    let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    Button(action: dismiss) {
      HStack(spacing: 10) {
        Image(systemName: toast.style.systemImage)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(tint)
          .frame(width: 24, height: 24)
          .background(tint.opacity(isDark ? 0.22 : 0.14), in: Circle())
          .accessibilityHidden(true)

        Text(toast.text)
          .font(.system(size: 12.5, weight: .medium))
          .foregroundStyle(theme.textPrimary)
          .multilineTextAlignment(.leading)
          .lineLimit(3)
          .fixedSize(horizontal: false, vertical: true)

        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(isHovered ? theme.textPrimary : theme.textMuted.opacity(0.75))
          .padding(.leading, 2)
          .accessibilityHidden(true)
      }
      .padding(.leading, 13)
      .padding(.trailing, 12)
      .padding(.vertical, 9)
      .background {
        ZStack {
          theme.surfaceRaised
          tint.opacity(isDark ? 0.14 : 0.09)
        }
      }
      .overlay(alignment: .leading) {
        Rectangle()
          .fill(tint.opacity(isDark ? 0.90 : 0.85))
          .frame(width: 3)
      }
      .clipShape(shape)
      .overlay {
        shape
          .strokeBorder(
            tint.opacity(isHovered ? (isDark ? 0.52 : 0.44) : (isDark ? 0.36 : 0.30)),
            lineWidth: 1
          )
      }
      .shadow(color: .black.opacity(isDark ? 0.42 : 0.14), radius: 14, y: 6)
      .shadow(color: .black.opacity(isDark ? 0.24 : 0.06), radius: 2, y: 1)
      .contentShape(shape)
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .animation(
      .easeOut(duration: MacDesignTokens.Control.interactionDuration),
      value: isHovered
    )
    .accessibilityLabel(toast.text)
    .accessibilityHint("Click to dismiss")
  }
}

private struct MacToastCenterEnvironmentKey: EnvironmentKey {
  static let defaultValue: MacToastCenter? = nil
}

extension EnvironmentValues {
  var macToastCenter: MacToastCenter? {
    get { self[MacToastCenterEnvironmentKey.self] }
    set { self[MacToastCenterEnvironmentKey.self] = newValue }
  }
}

extension View {
  func macToastOverlay(
    _ center: MacToastCenter,
    topInset: CGFloat = MacDesignTokens.Layout.titlebarHeight + 12
  ) -> some View {
    overlay(alignment: .topTrailing) {
      MacToastOverlay(center: center, topInset: topInset)
    }
    .environment(\.macToastCenter, center)
  }
}
