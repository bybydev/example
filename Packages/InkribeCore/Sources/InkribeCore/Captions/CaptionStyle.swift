import CoreGraphics
import Foundation

public struct CaptionColor: Codable, Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double = 1

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }

    public static let white = Self(red: 1, green: 1, blue: 1)
    public static let black = Self(red: 0, green: 0, blue: 0)
    public static let yellow = Self(red: 1, green: 0.8, blue: 0.12)
    public static let mint = Self(red: 0.25, green: 1, blue: 0.65)
    public static let pink = Self(red: 1, green: 0.32, blue: 0.75)

    public var cgColor: CGColor {
        CGColor(srgbRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
    }
    public var contrastText: Self { red * 0.2126 + green * 0.7152 + blue * 0.0722 > 0.55 ? .black : .white }
    public func validate() throws {
        guard [red, green, blue, alpha].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw ProjectStoreError.invalidDocument("Invalid caption color")
        }
    }
}

public enum CaptionFont: String, Codable, CaseIterable, Hashable, Sendable {
    case modern, bold, serif, mono, condensed, rounded
    public var name: String {
        switch self {
        case .modern: "Modern"
        case .bold: "Bold"
        case .serif: "Serif"
        case .mono: "Mono"
        case .condensed: "Condensed"
        case .rounded: "Rounded"
        }
    }
    public var postScriptName: String {
        switch self {
        case .modern: "AvenirNext-DemiBold"
        case .bold: "HelveticaNeue-Bold"
        case .serif: "Georgia-Bold"
        case .mono: "Menlo-Bold"
        case .condensed: "AvenirNextCondensed-DemiBold"
        case .rounded: "ArialRoundedMTBold"
        }
    }
}

public enum CaptionEffect: String, Codable, CaseIterable, Hashable, Sendable {
    case none, highlight, karaoke, pop, fade, emphasis, underline, rise
    public var name: String {
        switch self {
        case .none: "None"
        case .highlight: "Highlight"
        case .karaoke: "Karaoke"
        case .pop: "Pop"
        case .fade: "Fade"
        case .emphasis: "Active color"
        case .underline: "Underline"
        case .rise: "Rise"
        }
    }
}

/// Project-wide style. Size is a fraction of the shorter canvas edge; position
/// is a normalized center in top-left output coordinates, never phone points.
public struct CaptionStyle: Codable, Equatable, Sendable {
    public var font: CaptionFont = .modern
    public var fontSize: Double = 0.06
    public var textColor: CaptionColor = .white
    public var accentColor: CaptionColor = .yellow
    public var outlineColor: CaptionColor = .black
    /// Fraction of the font size; zero disables the outline.
    public var outlineWidth: Double = 0.045
    public var backgroundEnabled = true
    public var backgroundColor = CaptionColor(red: 0, green: 0, blue: 0, alpha: 0.6)
    public var positionX: Double = 0.5
    public var positionY: Double = 0.82
    public var effect: CaptionEffect = .none

    // Format 1 is the frozen legacy appearance; format 2 enables extended layout.
    public var formatVersion: Int = 1
    public var weight: CaptionFontWeight = .original
    public var tracking: Double = 0
    public var lineWidth: Double = 1
    public var lineSpacing: Double = 0.1
    public var maximumLines: Int = 8
    public var alignment: CaptionAlignment = .center
    public var minimumScale: Double = 1
    public var backgroundMode: CaptionBackgroundMode = .block
    public var backgroundPadding: Double = 0.28
    public var backgroundRadius: Double = 0.22
    public var shadowEnabled: Bool = false
    public var shadowColor: CaptionColor = .black
    public var shadowBlur: Double = 0.18
    public var shadowOffsetX: Double = 0
    public var shadowOffsetY: Double = 0.08
    public var preset: CaptionPresetReference? = nil

    public init() {}

    public static let standard = Self()

    private enum CodingKeys: String, CodingKey {
        case font, fontSize, textColor, accentColor, outlineColor, outlineWidth
        case backgroundEnabled, backgroundColor, positionX, positionY, effect
        case formatVersion, weight, tracking, lineWidth, lineSpacing, maximumLines, alignment, minimumScale
        case backgroundMode, backgroundPadding, backgroundRadius
        case shadowEnabled, shadowColor, shadowBlur, shadowOffsetX, shadowOffsetY, preset
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        guard formatVersion <= 2 else { throw ProjectStoreError.unsupportedCaptionStyle(formatVersion) }
        let extended = formatVersion == 2
        func resolved<T: Decodable>(_ type: T.Type, forKey key: CodingKeys, legacyDefault: T) throws -> T {
            // Only historical payloads may omit extension fields. New resolved
            // styles must not silently change appearance after partial corruption.
            if extended { return try c.decode(type, forKey: key) }
            return try c.decodeIfPresent(type, forKey: key) ?? legacyDefault
        }
        font = try c.decode(CaptionFont.self, forKey: .font)
        fontSize = try c.decode(Double.self, forKey: .fontSize)
        textColor = try c.decode(CaptionColor.self, forKey: .textColor)
        accentColor = try c.decode(CaptionColor.self, forKey: .accentColor)
        outlineColor = try c.decode(CaptionColor.self, forKey: .outlineColor)
        outlineWidth = try c.decode(Double.self, forKey: .outlineWidth)
        backgroundEnabled = try c.decode(Bool.self, forKey: .backgroundEnabled)
        backgroundColor = try c.decode(CaptionColor.self, forKey: .backgroundColor)
        positionX = try c.decode(Double.self, forKey: .positionX)
        positionY = try c.decode(Double.self, forKey: .positionY)
        effect = try c.decode(CaptionEffect.self, forKey: .effect)
        weight = try resolved(CaptionFontWeight.self, forKey: .weight, legacyDefault: .original)
        tracking = try resolved(Double.self, forKey: .tracking, legacyDefault: 0)
        lineWidth = try resolved(Double.self, forKey: .lineWidth, legacyDefault: 1)
        lineSpacing = try resolved(Double.self, forKey: .lineSpacing, legacyDefault: 0.1)
        maximumLines = try resolved(Int.self, forKey: .maximumLines, legacyDefault: 8)
        alignment = try resolved(CaptionAlignment.self, forKey: .alignment, legacyDefault: .center)
        minimumScale = try resolved(Double.self, forKey: .minimumScale, legacyDefault: 1)
        backgroundMode = try resolved(CaptionBackgroundMode.self, forKey: .backgroundMode, legacyDefault: .block)
        backgroundPadding = try resolved(Double.self, forKey: .backgroundPadding, legacyDefault: 0.28)
        backgroundRadius = try resolved(Double.self, forKey: .backgroundRadius, legacyDefault: 0.22)
        shadowEnabled = try resolved(Bool.self, forKey: .shadowEnabled, legacyDefault: false)
        shadowColor = try resolved(CaptionColor.self, forKey: .shadowColor, legacyDefault: .black)
        shadowBlur = try resolved(Double.self, forKey: .shadowBlur, legacyDefault: 0.18)
        shadowOffsetX = try resolved(Double.self, forKey: .shadowOffsetX, legacyDefault: 0)
        shadowOffsetY = try resolved(Double.self, forKey: .shadowOffsetY, legacyDefault: 0.08)
        preset = try c.decodeIfPresent(CaptionPresetReference.self, forKey: .preset)
        try validate()
    }

    public var requiresSchema8: Bool {
        formatVersion > 1 || preset != nil || font == .condensed || font == .rounded ||
            effect == .emphasis || effect == .underline || effect == .rise
    }
    public var withoutPreset: Self { var copy = self; copy.preset = nil; return copy }
    public var hasExtendedValues: Bool {
        let legacy = Self.standard
        return weight != legacy.weight ||
            tracking != legacy.tracking ||
            lineWidth != legacy.lineWidth ||
            lineSpacing != legacy.lineSpacing ||
            maximumLines != legacy.maximumLines ||
            alignment != legacy.alignment ||
            minimumScale != legacy.minimumScale ||
            backgroundMode != legacy.backgroundMode ||
            backgroundPadding != legacy.backgroundPadding ||
            backgroundRadius != legacy.backgroundRadius ||
            shadowEnabled != legacy.shadowEnabled ||
            shadowColor != legacy.shadowColor ||
            shadowBlur != legacy.shadowBlur ||
            shadowOffsetX != legacy.shadowOffsetX ||
            shadowOffsetY != legacy.shadowOffsetY
    }

    public func validate() throws {
        guard formatVersion <= 2 else { throw ProjectStoreError.unsupportedCaptionStyle(formatVersion) }
        guard fontSize.isFinite, (0.025...0.12).contains(fontSize),
              outlineWidth.isFinite, (0...0.12).contains(outlineWidth),
              positionX.isFinite, (0...1).contains(positionX),
              positionY.isFinite, (0...1).contains(positionY) else {
            throw ProjectStoreError.invalidDocument("Invalid caption style or position")
        }
        guard (1...2).contains(formatVersion), formatVersion == 2 || !hasExtendedValues,
              tracking.isFinite, (-0.02...0.1).contains(tracking),
              lineWidth.isFinite, (0.4...1).contains(lineWidth),
              lineSpacing.isFinite, (0...0.8).contains(lineSpacing), (1...8).contains(maximumLines),
              minimumScale.isFinite, (0.5...1).contains(minimumScale),
              backgroundPadding.isFinite, (0...0.6).contains(backgroundPadding),
              backgroundRadius.isFinite, (0...1).contains(backgroundRadius),
              shadowBlur.isFinite, (0...1).contains(shadowBlur),
              shadowOffsetX.isFinite, (-1...1).contains(shadowOffsetX),
              shadowOffsetY.isFinite, (-1...1).contains(shadowOffsetY) else {
            throw ProjectStoreError.invalidDocument("Unsupported or invalid caption layout")
        }
        try shadowColor.validate()
        try preset?.validate()
        try textColor.validate(); try accentColor.validate()
        try outlineColor.validate(); try backgroundColor.validate()
    }
}

/// Presets are ordinary editable style values, without marketplace/download IDs.
public enum CaptionTemplate: String, CaseIterable, Identifiable, Hashable, Sendable {
    case spotlight, karaoke, pop, softFade
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .spotlight: "Spotlight"
        case .karaoke: "Karaoke"
        case .pop: "Pop"
        case .softFade: "Soft Fade"
        }
    }
    public var style: CaptionStyle {
        var style = CaptionStyle.standard
        switch self {
        case .spotlight:
            style.font = .bold; style.effect = .highlight
            style.backgroundEnabled = false
        case .karaoke:
            style.font = .bold; style.effect = .karaoke; style.accentColor = .mint
        case .pop:
            style.effect = .pop; style.textColor = .pink; style.backgroundEnabled = false
            style.fontSize = 0.075; style.outlineWidth = 0.06
        case .softFade:
            style.font = .serif; style.effect = .fade; style.fontSize = 0.055
            style.outlineWidth = 0; style.backgroundColor.alpha = 0.5
        }
        return style
    }
}

/// Identifies continuous control edits for a single undo group.
public enum CaptionStyleControl: Hashable, Sendable {
    case font, size, textColor, accentColor, outlineColor, outlineWidth
    case background, backgroundColor, horizontalPosition, verticalPosition, effect
    case tracking, lineWidth, lineSpacing, minimumScale, backgroundPadding, backgroundRadius
    case shadowColor, shadowBlur, shadowX, shadowY
}

public enum CaptionFontWeight: String, Codable, CaseIterable, Hashable, Sendable {
    case original, regular, medium, heavy
    public var name: String { self == .original ? "Font default" : rawValue.capitalized }
    public var trait: Double? {
        switch self { case .original: nil; case .regular: 0; case .medium: 0.23; case .heavy: 0.56 }
    }
}

public enum CaptionAlignment: String, Codable, CaseIterable, Hashable, Sendable {
    case center, leading, trailing
    public var name: String { rawValue.capitalized }
}

public enum CaptionBackgroundMode: String, Codable, CaseIterable, Hashable, Sendable {
    case block, lines
    public var name: String { self == .block ? "Caption box" : "Per line" }
}

/// Identity is provenance, never an instruction to resolve defaults on open.
/// The complete saved style always remains the rendering authority.
public struct CaptionPresetReference: Codable, Equatable, Sendable {
    public let id: String
    public let version: Int
    public init(id: String, version: Int) { self.id = id; self.version = version }
    public func validate() throws {
        guard !id.isEmpty, id.utf8.count <= 64, version > 0,
              id.utf8.allSatisfy({ (97...122).contains($0) || (65...90).contains($0) || (48...57).contains($0) || $0 == 45 }) else {
            throw ProjectStoreError.invalidDocument("Invalid preset identity")
        }
    }
}
