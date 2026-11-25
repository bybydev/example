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

/// Consistent secondary-styled label for borderless text `Menu` triggers so
/// dropdown buttons match `MacActionButtonStyle(.secondary)` across macOS versions.
struct MacMenuButtonLabel: View {
  let title: String
  var systemImage: String? = nil
  var size: MacActionButtonStyle.Size = .regular
  var showsChevron: Bool = true
  var isAccentIcon: Bool = false

  @State private var isHovered = false

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

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    HStack(spacing: 5) {
      if let systemImage {
        Image(systemName: systemImage)
          .font(.system(size: size == .regular ? 12 : 11, weight: .medium))
          .foregroundStyle(
            isAccentIcon ? MacDesignTokens.Colors.accent : MacDesignTokens.Colors.textMuted
          )
      }
      Text(title)
        .font(.system(size: size == .regular ? 13 : 12, weight: .medium))
        .foregroundStyle(MacDesignTokens.Colors.textPrimary)
        .lineLimit(1)
      if showsChevron {
        Image(systemName: "chevron.down")
          .font(.system(size: 9.5, weight: .semibold))
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
      }
    }
    .padding(.horizontal, horizontalPadding)
    .frame(height: height)
    .background(Color.primary.opacity(isHovered ? 0.075 : 0.045), in: shape)
    .overlay {
      shape.stroke(Color.primary.opacity(isHovered ? 0.18 : 0.12), lineWidth: 0.75)
    }
    .contentShape(shape)
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
  let tint: Color?

  init(_ variant: Variant = .secondary, size: Size = .regular, tint: Color? = nil) {
    self.variant = variant
    self.size = size
    self.tint = tint
  }

  func makeBody(configuration: Configuration) -> some View {
    MacActionButtonStyleBody(
      label: configuration.label,
      isPressed: configuration.isPressed,
      variant: variant,
      size: size,
      tint: tint
    )
  }
}

private struct MacActionButtonStyleBody<Label: View>: View {
  let label: Label
  let isPressed: Bool
  let variant: MacActionButtonStyle.Variant
  let size: MacActionButtonStyle.Size
  let tint: Color?

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
      (tint ?? MacDesignTokens.Colors.accent).opacity(activePress ? 0.82 : activeHover ? 0.90 : 1.0)
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

/// Version-independent segmented control so tab and filter bars render identically
/// across macOS 15 and newer macOS releases.
struct MacSegmentedControl<Option: Hashable>: View {
  let options: [Option]
  @Binding var selection: Option
  var equalWidth: Bool = true
  let title: (Option) -> String

  init(
    options: [Option],
    selection: Binding<Option>,
    equalWidth: Bool = true,
    title: @escaping (Option) -> String
  ) {
    self.options = options
    self._selection = selection
    self.equalWidth = equalWidth
    self.title = title
  }

  var body: some View {
    HStack(spacing: 4) {
      ForEach(options, id: \.self) { option in
        MacSegmentedControlItem(
          title: title(option),
          isSelected: selection == option,
          equalWidth: equalWidth
        ) {
          withAnimation(.easeOut(duration: MacDesignTokens.Control.interactionDuration)) {
            selection = option
          }
        }
      }
    }
    .padding(3)
    .background(
      Color.primary.opacity(0.05),
      in: RoundedRectangle(cornerRadius: 9, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .stroke(MacDesignTokens.Colors.separator.opacity(0.55), lineWidth: 0.5)
    }
  }
}

private struct MacSegmentedControlItem: View {
  let title: String
  let isSelected: Bool
  let equalWidth: Bool
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
    Button(action: action) {
      Text(title)
        .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
        .lineLimit(1)
        .foregroundStyle(
          isSelected
            ? MacDesignTokens.Colors.textPrimary
            : (isHovered ? MacDesignTokens.Colors.textPrimary : MacDesignTokens.Colors.textMuted)
        )
        .padding(.horizontal, equalWidth ? 10 : 12)
        .frame(maxWidth: equalWidth ? .infinity : nil)
        .frame(height: 26)
        .background(background, in: shape)
        .overlay {
          if isSelected {
            shape.stroke(MacDesignTokens.Colors.separator.opacity(0.8), lineWidth: 0.75)
          }
        }
        .contentShape(shape)
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    .onHover { isHovered = $0 }
    .animation(
      .easeOut(duration: MacDesignTokens.Control.interactionDuration),
      value: isHovered
    )
  }

  private var background: Color {
    if isSelected { return MacDesignTokens.Colors.surface }
    if isHovered { return Color.primary.opacity(0.04) }
    return .clear
  }
}
