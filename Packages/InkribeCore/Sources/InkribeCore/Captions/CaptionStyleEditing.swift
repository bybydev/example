import Foundation

public enum CaptionStyleReset: Sendable { case typography, colors, backdrop, layout, placement, motion }

extension CaptionStyle {
    /// A reset is an ordinary resolved-value edit, never a catalog refresh.
    public func resetting(_ section: CaptionStyleReset, to base: Self) -> Self {
        var next = self
        switch section {
        case .typography: next.font = base.font; next.fontSize = base.fontSize; next.weight = base.weight; next.tracking = base.tracking
        case .colors: next.textColor = base.textColor; next.accentColor = base.accentColor
        case .backdrop:
            next.outlineWidth = base.outlineWidth; next.outlineColor = base.outlineColor
            next.backgroundEnabled = base.backgroundEnabled; next.backgroundColor = base.backgroundColor
            next.backgroundMode = base.backgroundMode; next.backgroundPadding = base.backgroundPadding; next.backgroundRadius = base.backgroundRadius
            next.shadowEnabled = base.shadowEnabled; next.shadowColor = base.shadowColor
            next.shadowBlur = base.shadowBlur; next.shadowOffsetX = base.shadowOffsetX; next.shadowOffsetY = base.shadowOffsetY
        case .layout:
            next.alignment = base.alignment; next.lineWidth = base.lineWidth; next.lineSpacing = base.lineSpacing
            next.maximumLines = base.maximumLines; next.minimumScale = base.minimumScale
        case .placement: next.positionX = base.positionX; next.positionY = base.positionY
        case .motion: next.effect = base.effect
        }
        if next.formatVersion == 1 && (next.hasExtendedValues || base.formatVersion == 2) { next.formatVersion = 2 }
        return next
    }
}

/// The existing free font/effect policy plus new premium capabilities. Retained
/// premium fields and reverting to Basic remain usable after expiry. Existing
/// free colors/size/position/outline/background controls keep their policy.
public enum CaptionStyleAccess {
    public static func canChange(from before: CaptionStyle, to next: CaptionStyle, hasPro: Bool) -> Bool {
        if hasPro { return true }
        let basic = CaptionStyle.standard
        return (next.font == .modern || next.font == before.font)
            && (next.effect == .none || next.effect == before.effect)
            && (next.weight == basic.weight || next.weight == before.weight)
            && (next.tracking == basic.tracking || next.tracking == before.tracking)
            && (next.lineWidth == basic.lineWidth || next.lineWidth == before.lineWidth)
            && (next.lineSpacing == basic.lineSpacing || next.lineSpacing == before.lineSpacing)
            && (next.maximumLines == basic.maximumLines || next.maximumLines == before.maximumLines)
            && (next.alignment == basic.alignment || next.alignment == before.alignment)
            && (next.minimumScale == basic.minimumScale || next.minimumScale == before.minimumScale)
            && (next.backgroundMode == basic.backgroundMode || next.backgroundMode == before.backgroundMode)
            && (next.backgroundPadding == basic.backgroundPadding || next.backgroundPadding == before.backgroundPadding)
            && (next.backgroundRadius == basic.backgroundRadius || next.backgroundRadius == before.backgroundRadius)
            && (!next.shadowEnabled || before.shadowEnabled)
            && (next.shadowBlur == basic.shadowBlur || next.shadowBlur == before.shadowBlur)
            && (next.shadowOffsetX == basic.shadowOffsetX || next.shadowOffsetX == before.shadowOffsetX)
            && (next.shadowOffsetY == basic.shadowOffsetY || next.shadowOffsetY == before.shadowOffsetY)
    }
}
