import AppFoundation
import SwiftUI
import UIKit

/// Animated clipboard action shared by message, code, diagram and reasoning views.
/// Sizes preserve the tap geometry of each existing surface.
struct CopyButton: View {
  enum Size {
    case regular
    case messageAction
    case compact
    case toolbar

    var width: CGFloat? {
      switch self {
      case .regular: 40
      case .messageAction: 40
      case .compact: 40
      case .toolbar: nil
      }
    }

    var height: CGFloat? {
      switch self {
      case .regular: 40
      case .messageAction: 42
      case .compact: 38
      case .toolbar: nil
      }
    }
  }

  let text: String
  var accessibilityTitle = "Copy"
  var size: Size = .regular
  var alignment: Alignment = .center
  var triggersReviewCheck = true
  var onCopied: (() -> Void)? = nil

  @Environment(\.appFoundationTheme) private var theme
  @Environment(AppModel.self) private var appModel: AppModel?
  @State private var isCopied = false
  @State private var feedbackRevision = 0

  var body: some View {
    Button {
      UIPasteboard.general.string = text
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
      withAnimation(.snappy(duration: 0.2)) {
        isCopied = true
      }
      // Each tap restarts the confirmation interval, even if already copied.
      feedbackRevision += 1
      if triggersReviewCheck {
        appModel?.reviewPrompt.recordAssistantContentCopied()
      }
      onCopied?()
    } label: {
      Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
        .contentTransition(.symbolEffect(.replace))
        .foregroundStyle(
          isCopied ? theme.accentColor :
            (size == .toolbar ? Color.accentColor : theme.secondaryForegroundColor)
        )
        .frame(width: size.width, height: size.height, alignment: alignment)
        .contentShape(Rectangle())
    }
    .disabled(text.isEmpty)
    .opacity(text.isEmpty ? 0.35 : 1)
    .accessibilityLabel(isCopied ? "Copied" : accessibilityTitle)
    .task(id: feedbackRevision) {
      guard isCopied else { return }
      try? await Task.sleep(for: .seconds(1.5))
      guard !Task.isCancelled else { return }
      withAnimation(.snappy(duration: 0.2)) {
        isCopied = false
      }
    }
    .onChange(of: text) { _, _ in
      // Don't show confirmation of a previous version of the content.
      isCopied = false
      feedbackRevision += 1
    }
  }
}
