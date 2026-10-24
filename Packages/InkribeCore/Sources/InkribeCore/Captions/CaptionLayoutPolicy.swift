import Foundation

/// Shared normalized constraints; Core Text measurement/drawing remains native.
/// Six measurements at most: requested, minimum, four bounded refinements.
public enum CaptionLayoutPolicy {
    public static let maximumUTF16Count = 16_384
    public static let refinementCount = 4
    public static func minimumFontFraction(for style: CaptionStyle) -> Double {
        max(0.025, style.fontSize * style.minimumScale)
    }
    public static func maximumScale(for style: CaptionStyle) -> Double { style.effect == .pop ? 1.12 : 1 }
    public static func outerInsetInFontUnits(for style: CaptionStyle) -> Double {
        let motion: Double
        switch style.effect {
        case .rise: motion = 0.35
        case .underline: motion = 0.14
        case .highlight: motion = style.formatVersion >= 2 ? 0.08 : 0
        default: motion = 0
        }
        let shadow = style.shadowEnabled ? style.shadowBlur * 2 + max(abs(style.shadowOffsetX), abs(style.shadowOffsetY)) : 0
        return shadow + motion
    }
}
