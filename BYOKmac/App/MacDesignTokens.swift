import AppKit
import MacAppFoundation
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
    static let titlebarHeight: CGFloat = 52
    static let titlebarTrafficLightReserve: CGFloat = 76
  }

  enum Control {
    static let iconButtonSize: CGFloat = 28
    static let sheetCloseButtonSize: CGFloat = 30
    static let compactButtonHeight: CGFloat = 24
    static let compactHorizontalPadding: CGFloat = 10
    static let actionButtonHeight: CGFloat = 30
    static let actionButtonSmallHeight: CGFloat = 26
    static let actionHorizontalPadding: CGFloat = 12
    static let actionSmallHorizontalPadding: CGFloat = 10
    static let hoverOpacity: CGFloat = 0.055
    static let pressedOpacity: CGFloat = 0.09
    static let sheetCloseHoverOpacity: CGFloat = 0.10
    static let sheetClosePressedOpacity: CGFloat = 0.16
    static let disabledOpacity: CGFloat = 0.5
    static let interactionDuration: Double = 0.12
  }

  @MainActor
  enum Colors {
    private static var palette: MacAppThemePalette {
      MacThemeFoundation.store
        .currentTheme(hasPro: MacPurchaseStore.manager.hasPro)
        .palette
    }

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

/// Consistent icon label for borderless `Menu` triggers so ellipsis menus match
/// `MacIconButtonStyle` across macOS versions without system bezel drift.
struct MacIconMenuLabel: View {
  let systemImage: String

  @State private var isHovered = false

  var body: some View {
    Image(systemName: systemImage)
      .foregroundStyle(
        isHovered
          ? MacDesignTokens.Colors.textPrimary
          : MacDesignTokens.Colors.textMuted
      )
      .frame(
        width: MacDesignTokens.Control.iconButtonSize,
        height: MacDesignTokens.Control.iconButtonSize
      )
      .background(
        Color.primary.opacity(isHovered ? MacDesignTokens.Control.hoverOpacity : 0),
        in: RoundedRectangle(cornerRadius: MacDesignTokens.Radius.small, style: .continuous)
      )
      .contentShape(
        RoundedRectangle(cornerRadius: MacDesignTokens.Radius.small, style: .continuous)
      )
      .onHover { isHovered = $0 }
      .animation(
        .easeOut(duration: MacDesignTokens.Control.interactionDuration),
        value: isHovered
      )
  }
}

struct MacSheetCloseButton: View {
  let accessibilityLabel: String
  let action: () -> Void

  init(
    accessibilityLabel: String = "Close",
    action: @escaping () -> Void
  ) {
    self.accessibilityLabel = accessibilityLabel
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      Image(systemName: "xmark")
        .font(.system(size: 12, weight: .semibold))
    }
    .buttonStyle(MacSheetCloseButtonStyle())
    .keyboardShortcut(.cancelAction)
    .help("Close")
    .accessibilityLabel(accessibilityLabel)
  }
}

struct MacSheetCloseButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    MacSheetCloseButtonStyleBody(
      label: configuration.label,
      isPressed: configuration.isPressed
    )
  }
}

private struct MacSheetCloseButtonStyleBody<Label: View>: View {
  let label: Label
  let isPressed: Bool

  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovered = false

  var body: some View {
    label
      .foregroundStyle(
        isHovered || isPressed
          ? MacDesignTokens.Colors.textPrimary
          : MacDesignTokens.Colors.textMuted
      )
      .frame(
        width: MacDesignTokens.Control.sheetCloseButtonSize,
        height: MacDesignTokens.Control.sheetCloseButtonSize
      )
      .background(
        Color.primary.opacity(backgroundOpacity),
        in: Circle()
      )
      .overlay {
        Circle()
          .stroke(Color.primary.opacity(borderOpacity), lineWidth: 0.75)
      }
      .scaleEffect(isPressed ? 0.94 : 1)
      .contentShape(Rectangle())
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
    if isPressed { return MacDesignTokens.Control.sheetClosePressedOpacity }
    if isHovered { return MacDesignTokens.Control.sheetCloseHoverOpacity }
    return 0
  }

  private var borderOpacity: CGFloat {
    if isPressed { return 0.16 }
    if isHovered { return 0.11 }
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

/// Version-independent macOS action button style so primary, secondary, subtle,
/// and destructive controls render identically across macOS 15 and newer releases.
struct MacActionButtonStyle: ButtonStyle {
  enum Variant: Sendable {
    case primary
    case secondary
    case subtle
    case destructive
  }

  enum Size: Sendable {
    case regular
    case small
  }

  let variant: Variant
  let size: Size

  init(_ variant: Variant = .secondary, size: Size = .regular) {
    self.variant = variant
    self.size = size
  }

  func makeBody(configuration: Configuration) -> some View {
    MacActionButtonStyleBody(
      label: configuration.label,
      isPressed: configuration.isPressed,
      variant: variant,
      size: size
    )
  }
}

private struct MacActionButtonStyleBody<Label: View>: View {
  let label: Label
  let isPressed: Bool
  let variant: MacActionButtonStyle.Variant
  let size: MacActionButtonStyle.Size

  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovered = false

  private var activeHover: Bool { isEnabled && isHovered }
  private var activePress: Bool { isEnabled && isPressed }

  private var height: CGFloat {
    switch size {
    case .regular: MacDesignTokens.Control.actionButtonHeight
    case .small: MacDesignTokens.Control.actionButtonSmallHeight
    }
  }

  private var horizontalPadding: CGFloat {
    switch size {
    case .regular: MacDesignTokens.Control.actionHorizontalPadding
    case .small: MacDesignTokens.Control.actionSmallHorizontalPadding
    }
  }

  private var cornerRadius: CGFloat {
    switch size {
    case .regular: 8
    case .small: MacDesignTokens.Radius.small
    }
  }

  private var labelFont: Font {
    switch size {
    case .regular:
      .system(size: 13, weight: variant == .primary ? .semibold : .medium)
    case .small:
      .system(size: 12, weight: variant == .primary ? .semibold : .medium)
    }
  }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    label
      .font(labelFont)
      .lineLimit(1)
      .padding(.horizontal, horizontalPadding)
      .frame(height: height)
      .foregroundStyle(foreground)
      .background(background, in: shape)
      .overlay {
        if let border {
          shape.stroke(border, lineWidth: 0.75)
        }
      }
      .scaleEffect(activePress ? 0.98 : 1)
      .contentShape(shape)
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
    switch variant {
    case .primary:
      Color.white
    case .secondary, .subtle:
      MacDesignTokens.Colors.textPrimary
    case .destructive:
      Color.red
    }
  }

  private var background: Color {
    switch variant {
    case .primary:
      MacDesignTokens.Colors.accent.opacity(activePress ? 0.82 : activeHover ? 0.90 : 1.0)
    case .secondary:
      Color.primary.opacity(activePress ? 0.11 : activeHover ? 0.075 : 0.045)
    case .subtle:
      Color.primary.opacity(activePress ? 0.095 : activeHover ? 0.055 : 0)
    case .destructive:
      Color.red.opacity(activePress ? 0.18 : activeHover ? 0.13 : 0.08)
    }
  }

  private var border: Color? {
    switch variant {
    case .primary:
      Color.white.opacity(activePress ? 0.10 : 0.16)
    case .secondary:
      Color.primary.opacity(activePress || activeHover ? 0.18 : 0.12)
    case .subtle:
      nil
    case .destructive:
      Color.red.opacity(activePress || activeHover ? 0.42 : 0.28)
    }
  }
}

/// Interactive card button style with consistent hover, press, and selection
/// chrome across macOS versions.
struct MacCardButtonStyle: ButtonStyle {
  var cornerRadius: CGFloat = 10
  var isSelected: Bool = false
  var surfaceColor: Color? = nil

  func makeBody(configuration: Configuration) -> some View {
    MacCardButtonStyleBody(
      label: configuration.label,
      isPressed: configuration.isPressed,
      cornerRadius: cornerRadius,
      isSelected: isSelected,
      surfaceColor: surfaceColor
    )
  }
}

private struct MacCardButtonStyleBody<Label: View>: View {
  let label: Label
  let isPressed: Bool
  let cornerRadius: CGFloat
  let isSelected: Bool
  let surfaceColor: Color?

  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovered = false

  private var activeHover: Bool { isEnabled && isHovered }
  private var activePress: Bool { isEnabled && isPressed }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    let resolvedSurface = surfaceColor ?? MacDesignTokens.Colors.surface
    label
      .background(resolvedSurface, in: shape)
      .overlay {
        shape.fill(Color.primary.opacity(activePress ? 0.06 : activeHover ? 0.03 : 0))
      }
      .overlay {
        shape.stroke(borderColor, lineWidth: isSelected ? 1.15 : 0.75)
      }
      .scaleEffect(activePress ? 0.99 : 1)
      .contentShape(shape)
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

  private var borderColor: Color {
    if isSelected {
      return MacDesignTokens.Colors.accent.opacity(0.65)
    }
    if activeHover || activePress {
      return MacDesignTokens.Colors.accent.opacity(0.35)
    }
    return MacDesignTokens.Colors.separator.opacity(0.75)
  }
}
