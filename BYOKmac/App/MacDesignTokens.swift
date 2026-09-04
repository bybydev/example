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
    static let topBarHeight: CGFloat = 52
    static let transcriptMaximumWidth: CGFloat = 820
    static let composerMaximumWidth: CGFloat = 820
    static let composerBottomMargin: CGFloat = 18
    static let composerReservedScrollSpace: CGFloat = 190
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
