import AppKit
import Foundation
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
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Group {
      if let toast = center.current {
        card(for: toast)
          .frame(maxWidth: 460)
          .padding(.horizontal, 16)
          .padding(.top, 12)
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

  private func card(for toast: MacToastCenter.Message) -> some View {
    let tint = toast.style == .success ? MacDesignTokens.Colors.accent : toast.style.tint
    return Button {
      center.dismiss()
    } label: {
      HStack(spacing: 10) {
        Image(systemName: toast.style.systemImage)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(tint)
          .frame(width: 26, height: 26)
          .background(tint.opacity(0.14), in: Circle())
          .accessibilityHidden(true)

        Text(toast.text)
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(MacDesignTokens.Colors.textPrimary)
          .multilineTextAlignment(.leading)
          .lineLimit(3)

        Spacer(minLength: 0)
      }
      .padding(.leading, 10)
      .padding(.trailing, 14)
      .padding(.vertical, 9)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(MacDesignTokens.Colors.separator.opacity(0.9), lineWidth: 0.75)
      }
      .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
    }
    .buttonStyle(.plain)
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
  func macToastOverlay(_ center: MacToastCenter) -> some View {
    overlay(alignment: .top) {
      MacToastOverlay(center: center)
    }
    .environment(\.macToastCenter, center)
  }
}
