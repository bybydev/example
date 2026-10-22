import CoreGraphics
import Foundation

struct IOSCaptionColor: Codable, Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    static let white = Self(red: 1, green: 1, blue: 1)
    static let black = Self(red: 0, green: 0, blue: 0)
    static let yellow = Self(red: 1, green: 0.8, blue: 0.12)
    static let mint = Self(red: 0.25, green: 1, blue: 0.65)
    static let pink = Self(red: 1, green: 0.32, blue: 0.75)

    var cgColor: CGColor {
        CGColor(srgbRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
    }
    var contrastText: Self { red * 0.2126 + green * 0.7152 + blue * 0.0722 > 0.55 ? .black : .white }
    func validate() throws {
        guard [red, green, blue, alpha].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw IOSProjectStoreError.invalidDocument("Invalid caption color")
        }
    }
}

enum IOSCaptionFont: String, Codable, CaseIterable, Hashable, Sendable {
    case modern, bold, serif, mono
    var name: String {
        switch self {
        case .modern: "Modern"
        case .bold: "Bold"
        case .serif: "Serif"
        case .mono: "Mono"
        }
    }
    var postScriptName: String {
        switch self {
        case .modern: "AvenirNext-DemiBold"
        case .bold: "HelveticaNeue-Bold"
        case .serif: "Georgia-Bold"
        case .mono: "Menlo-Bold"
        }
    }
}

enum IOSCaptionEffect: String, Codable, CaseIterable, Hashable, Sendable {
    case none, highlight, karaoke, pop, fade
    var name: String {
        switch self {
        case .none: "None"
        case .highlight: "Highlight"
        case .karaoke: "Karaoke"
        case .pop: "Pop"
        case .fade: "Fade"
        }
    }
}

/// Project-wide style. Size is a fraction of the shorter canvas edge; position
/// is a normalized center in top-left output coordinates, never phone points.
struct IOSCaptionStyle: Codable, Equatable, Sendable {
    var font: IOSCaptionFont = .modern
    var fontSize: Double = 0.06
    var textColor: IOSCaptionColor = .white
    var accentColor: IOSCaptionColor = .yellow
    var outlineColor: IOSCaptionColor = .black
    /// Fraction of the font size; zero disables the outline.
    var outlineWidth: Double = 0.045
    var backgroundEnabled = true
    var backgroundColor = IOSCaptionColor(red: 0, green: 0, blue: 0, alpha: 0.6)
    var positionX: Double = 0.5
    var positionY: Double = 0.82
    var effect: IOSCaptionEffect = .none

    static let standard = Self()

    func validate() throws {
        guard fontSize.isFinite, (0.025...0.12).contains(fontSize),
              outlineWidth.isFinite, (0...0.12).contains(outlineWidth),
              positionX.isFinite, (0...1).contains(positionX),
              positionY.isFinite, (0...1).contains(positionY) else {
            throw IOSProjectStoreError.invalidDocument("Invalid caption style or position")
        }
        try textColor.validate(); try accentColor.validate()
        try outlineColor.validate(); try backgroundColor.validate()
    }
}

/// Presets are ordinary editable style values, without marketplace/download IDs.
enum IOSCaptionTemplate: String, CaseIterable, Identifiable, Sendable {
    case spotlight, karaoke, pop, softFade
    var id: String { rawValue }
    var name: String {
        switch self {
        case .spotlight: "Spotlight"
        case .karaoke: "Karaoke"
        case .pop: "Pop"
        case .softFade: "Soft Fade"
        }
    }
    var style: IOSCaptionStyle {
        var style = IOSCaptionStyle.standard
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
enum IOSCaptionStyleControl: Hashable, Sendable {
    case font, size, textColor, accentColor, outlineColor, outlineWidth
    case background, backgroundColor, horizontalPosition, verticalPosition, effect
}
