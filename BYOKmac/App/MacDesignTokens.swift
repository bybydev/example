import AppKit
import SwiftUI

enum MacDesignTokens {
  enum Spacing {
    static let xSmall: CGFloat = 4
    static let small: CGFloat = 8
    static let compact: CGFloat = 12
    static let standard: CGFloat = 16
    static let medium: CGFloat = 20
    static let large: CGFloat = 24
    static let xLarge: CGFloat = 32
    static let transcriptTop: CGFloat = 48
  }

  enum Radius {
    static let small: CGFloat = 7
    static let medium: CGFloat = 9
    static let large: CGFloat = 14
    static let message: CGFloat = 18
  }

  enum Layout {
    static let sidebarMinimum: CGFloat = 220
    static let sidebarIdeal: CGFloat = 248
    static let sidebarMaximum: CGFloat = 300
    static let transcriptMaximumWidth: CGFloat = 820
    /// Same column as the transcript so the composer's edges align with the
    /// message text above it.
    static let composerMaximumWidth: CGFloat = transcriptMaximumWidth
    static let composerBottomMargin: CGFloat = 18
    static let composerReservedScrollSpace: CGFloat = 120
    static let titlebarHeight: CGFloat = 44
    static let titlebarTrafficLightReserve: CGFloat = 76
  }

  enum Control {
    static let iconButtonSize: CGFloat = 28
    static let compactButtonHeight: CGFloat = 24
    static let compactHorizontalPadding: CGFloat = 10
    static let hoverOpacity: CGFloat = 0.055
    static let pressedOpacity: CGFloat = 0.09
    static let disabledOpacity: CGFloat = 0.5
    static let interactionDuration: Double = 0.12
  }

  enum Colors {
    private static var palette: MacThemePalette { MacThemeRegistry.selectedID.palette }

    static var canvas: Color { palette.canvas }
    static var surface: Color { palette.surface }
    static var selection: Color { palette.selection }
    static var separator: Color { palette.separator }
    static var textPrimary: Color { palette.textPrimary }
    static var textMuted: Color { palette.textMuted }
    static var accent: Color { palette.accent }
    static var accentSoft: Color { palette.accentSoft }
    static var codeSurface: Color { palette.codeSurface }
  }
}

struct MacIconButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    MacIconButtonStyleBody(
      label: configuration.label,
      isPressed: configuration.isPressed
    )
  }
}

private struct MacIconButtonStyleBody<Label: View>: View {
  let label: Label
  let isPressed: Bool

  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovered = false

  var body: some View {
    label
      .frame(
        width: MacDesignTokens.Control.iconButtonSize,
        height: MacDesignTokens.Control.iconButtonSize
      )
      .background(
        Color.primary.opacity(backgroundOpacity),
        in: RoundedRectangle(cornerRadius: MacDesignTokens.Radius.small, style: .continuous)
      )
      .contentShape(
        RoundedRectangle(cornerRadius: MacDesignTokens.Radius.small, style: .continuous)
      )
      .opacity(isEnabled ? 1 : MacDesignTokens.Control.disabledOpacity)
      .focusEffectDisabled(false)
      .onHover { isHovered = $0 }
      .animation(
        .easeOut(duration: MacDesignTokens.Control.interactionDuration),
        value: isHovered
      )
      .animation(
        .easeOut(duration: MacDesignTokens.Control.interactionDuration),
        value: isPressed
      )
  }

  private var backgroundOpacity: CGFloat {
    if isPressed { return MacDesignTokens.Control.pressedOpacity }
    if isHovered { return MacDesignTokens.Control.hoverOpacity }
    return 0
  }
}

struct MacSecondaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    MacCapsuleButtonStyleBody(
      label: configuration.label,
      isPressed: configuration.isPressed,
      emphasis: .secondary
    )
  }
}

struct MacPrimaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    MacCapsuleButtonStyleBody(
      label: configuration.label,
      isPressed: configuration.isPressed,
      emphasis: .primary
    )
  }
}

private struct MacCapsuleButtonStyleBody<Label: View>: View {
  enum Emphasis {
    case secondary
    case primary
  }

  let label: Label
  let isPressed: Bool
  let emphasis: Emphasis

  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovered = false

  var body: some View {
    label
      .padding(.horizontal, MacDesignTokens.Control.compactHorizontalPadding)
      .frame(height: MacDesignTokens.Control.compactButtonHeight)
      .foregroundStyle(foreground)
      .background(background, in: Capsule())
      .overlay {
        Capsule()
          .stroke(border, lineWidth: 0.75)
      }
      .contentShape(Capsule())
      .opacity(isEnabled ? 1 : MacDesignTokens.Control.disabledOpacity)
      .focusEffectDisabled(false)
      .onHover { isHovered = $0 }
      .animation(
        .easeOut(duration: MacDesignTokens.Control.interactionDuration),
        value: isHovered
      )
      .animation(
        .easeOut(duration: MacDesignTokens.Control.interactionDuration),
        value: isPressed
      )
  }

  private var foreground: Color {
    switch emphasis {
    case .secondary:
      MacDesignTokens.Colors.textMuted
    case .primary:
      MacDesignTokens.Colors.accent
    }
  }

  private var background: Color {
    switch emphasis {
    case .secondary:
      Color.primary.opacity(isPressed ? 0.09 : isHovered ? 0.07 : 0.05)
    case .primary:
      MacDesignTokens.Colors.accent.opacity(isPressed ? 0.24 : isHovered ? 0.20 : 0.16)
    }
  }

  private var border: Color {
    switch emphasis {
    case .secondary:
      Color.primary.opacity(isHovered || isPressed ? 0.18 : 0.12)
    case .primary:
      MacDesignTokens.Colors.accent.opacity(isHovered || isPressed ? 0.58 : 0.45)
    }
  }
}
