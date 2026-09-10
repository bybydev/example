import AppKit
import Observation
import SwiftUI

enum MacThemeID: String, CaseIterable, Identifiable {
  case system
  case githubDarkDimmed
  case midnight
  case ocean
  case aurora
  case ember
  case graphite
  case porcelain
  case blossom
  case morningMist
  case softSage
  case sunrise
  case githubLight

  var id: String { rawValue }

  var title: String {
    switch self {
    case .system: "System"
    case .githubDarkDimmed: "GitHub Dark Dimmed"
    case .midnight: "Midnight"
    case .ocean: "Ocean"
    case .aurora: "Aurora"
    case .ember: "Ember"
    case .graphite: "Graphite"
    case .porcelain: "Porcelain"
    case .blossom: "Blossom"
    case .morningMist: "Morning Mist"
    case .softSage: "Soft Sage"
    case .sunrise: "Sunrise"
    case .githubLight: "GitHub Light"
    }
  }

  var preferredColorScheme: ColorScheme? {
    switch self {
    case .system: nil
    case .githubDarkDimmed, .midnight, .ocean, .aurora, .ember, .graphite: .dark
    case .porcelain, .blossom, .morningMist, .softSage, .sunrise, .githubLight: .light
    }
  }

  var palette: MacThemePalette {
    switch self {
    case .system:
      MacThemePalette(
        canvas: Color(nsColor: .windowBackgroundColor),
        surface: Color(nsColor: .controlBackgroundColor),
        selection: Color.accentColor.opacity(0.12),
        separator: Color(nsColor: .separatorColor),
        textPrimary: .primary,
        textMuted: .secondary,
        accent: .accentColor,
        accentSoft: Color.accentColor.opacity(0.10),
        codeSurface: Color(nsColor: .textBackgroundColor)
      )
    case .githubDarkDimmed:
      .hex(canvas: 0x22272E, surface: 0x2D333B, selection: 0x373E47, separator: 0x444C56, text: 0xCDD9E5, muted: 0x768390, accent: 0x539BF5, code: 0x2D333B)
    case .midnight:
      .hex(canvas: 0x0B1020, surface: 0x111827, selection: 0x1E293B, separator: 0x334155, text: 0xE5E7EB, muted: 0x94A3B8, accent: 0x818CF8, code: 0x0F172A)
    case .ocean:
      .hex(canvas: 0x061B2B, surface: 0x0B2638, selection: 0x10354B, separator: 0x164E63, text: 0xE0F2FE, muted: 0x7DD3FC, accent: 0x38BDF8, code: 0x082F49)
    case .aurora:
      .hex(canvas: 0x10161F, surface: 0x17202B, selection: 0x253044, separator: 0x374151, text: 0xF3F4F6, muted: 0xA1A1AA, accent: 0xA78BFA, code: 0x18181B)
    case .ember:
      .hex(canvas: 0x1D1412, surface: 0x2A1B17, selection: 0x3A241D, separator: 0x573027, text: 0xFFF7ED, muted: 0xFDBA74, accent: 0xFB923C, code: 0x261713)
    case .graphite:
      .hex(canvas: 0x161616, surface: 0x222222, selection: 0x303030, separator: 0x3F3F46, text: 0xF4F4F5, muted: 0xA1A1AA, accent: 0xD4D4D8, code: 0x1C1C1C)
    case .porcelain:
      .hex(canvas: 0xF7F7F5, surface: 0xFFFFFF, selection: 0xECECF8, separator: 0xDDDDE3, text: 0x202124, muted: 0x71717A, accent: 0x4F46E5, code: 0xF2F2F4)
    case .blossom:
      .hex(canvas: 0xFFF7FA, surface: 0xFFFFFF, selection: 0xFCE7F3, separator: 0xF3D0DF, text: 0x3F1D2E, muted: 0x9D647C, accent: 0xDB2777, code: 0xFFF1F5)
    case .morningMist:
      .hex(canvas: 0xF4F7F8, surface: 0xFFFFFF, selection: 0xE2F0F0, separator: 0xD8E2E5, text: 0x1F2937, muted: 0x64748B, accent: 0x0F766E, code: 0xEEF3F4)
    case .softSage:
      .hex(canvas: 0xF4F7F0, surface: 0xFFFFFF, selection: 0xEAF3DF, separator: 0xD7E2CD, text: 0x26311F, muted: 0x66725D, accent: 0x4D7C0F, code: 0xEFF4E9)
    case .sunrise:
      .hex(canvas: 0xFFF8ED, surface: 0xFFFFFF, selection: 0xFFEDD5, separator: 0xF4D9B8, text: 0x3D2A1C, muted: 0x8A6A50, accent: 0xEA580C, code: 0xFFF3E3)
    case .githubLight:
      .hex(canvas: 0xF6F8FA, surface: 0xFFFFFF, selection: 0xDDF4FF, separator: 0xD0D7DE, text: 0x1F2328, muted: 0x656D76, accent: 0x0969DA, code: 0xF6F8FA)
    }
  }
}

struct MacThemePalette {
  let canvas: Color
  let surface: Color
  let selection: Color
  let separator: Color
  let textPrimary: Color
  let textMuted: Color
  let accent: Color
  let accentSoft: Color
  let codeSurface: Color

  static func hex(
    canvas: UInt32,
    surface: UInt32,
    selection: UInt32,
    separator: UInt32,
    text: UInt32,
    muted: UInt32,
    accent: UInt32,
    code: UInt32
  ) -> Self {
    Self(
      canvas: Color(macHex: canvas),
      surface: Color(macHex: surface),
      selection: Color(macHex: selection),
      separator: Color(macHex: separator),
      textPrimary: Color(macHex: text),
      textMuted: Color(macHex: muted),
      accent: Color(macHex: accent),
      accentSoft: Color(macHex: accent).opacity(0.12),
      codeSurface: Color(macHex: code)
    )
  }
}

enum MacThemeRegistry {
  nonisolated(unsafe) static var selectedID: MacThemeID = {
    guard let raw = UserDefaults.standard.string(forKey: "mac.theme"), let value = MacThemeID(rawValue: raw) else {
      return .system
    }
    return value
  }()
}

@MainActor
@Observable
final class MacThemeModel {
  private let defaults: UserDefaults
  private(set) var revision = 0

  var selectedID: MacThemeID {
    didSet {
      defaults.set(selectedID.rawValue, forKey: "mac.theme")
      MacThemeRegistry.selectedID = selectedID
      revision &+= 1
    }
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let stored = defaults.string(forKey: "mac.theme").flatMap(MacThemeID.init(rawValue:)) ?? .system
    selectedID = stored
    MacThemeRegistry.selectedID = stored
  }

  var preferredColorScheme: ColorScheme? { selectedID.preferredColorScheme }

  /// Do not downgrade the visual state while StoreKit is still checking. Once
  /// entitlement resolution is authoritative, a Free user cannot keep an
  /// actively selected Pro-only theme after expiration or revocation.
  func reconcileProAccess(hasPro: Bool, isChecking: Bool) {
    guard !isChecking else { return }
    let resolvedAccess: MacProEntitlementAccess = hasPro ? .pro : .free
    guard !MacProAccess.canUseTheme(
      selectedID,
      hasPro: hasPro,
      entitlement: resolvedAccess
    ) else { return }
    selectedID = .system
  }
}

private extension Color {
  init(macHex: UInt32) {
    self.init(
      red: Double((macHex >> 16) & 0xFF) / 255.0,
      green: Double((macHex >> 8) & 0xFF) / 255.0,
      blue: Double(macHex & 0xFF) / 255.0
    )
  }
}