import Foundation

/// Only present fields override a project default. No catalog lookup occurs on read.
/// Missing fields always inherit, including after project defaults change.
public struct CaptionStyleOverrides: Codable, Equatable, Sendable {
    public var font: CaptionFont? = nil
    public var fontSize: Double? = nil
    public var textColor: CaptionColor? = nil
    public var accentColor: CaptionColor? = nil
    public var outlineColor: CaptionColor? = nil
    public var outlineWidth: Double? = nil
    public var backgroundEnabled: Bool? = nil
    public var backgroundColor: CaptionColor? = nil
    public var positionX: Double? = nil
    public var positionY: Double? = nil
    public var effect: CaptionEffect? = nil
    /// Rendering provenance for an explicitly chosen animation/preset.
    public var formatVersion: Int? = nil
    public var weight: CaptionFontWeight? = nil
    public var tracking: Double? = nil
    public var lineWidth: Double? = nil
    public var lineSpacing: Double? = nil
    public var maximumLines: Int? = nil
    public var alignment: CaptionAlignment? = nil
    public var minimumScale: Double? = nil
    public var backgroundMode: CaptionBackgroundMode? = nil
    public var backgroundPadding: Double? = nil
    public var backgroundRadius: Double? = nil
    public var shadowEnabled: Bool? = nil
    public var shadowColor: CaptionColor? = nil
    public var shadowBlur: Double? = nil
    public var shadowOffsetX: Double? = nil
    public var shadowOffsetY: Double? = nil
    public var preset: CaptionPresetReference? = nil
    public init() {}
    public var isEmpty: Bool {
        font == nil &&
        fontSize == nil &&
        textColor == nil &&
        accentColor == nil &&
        outlineColor == nil &&
        outlineWidth == nil &&
        backgroundEnabled == nil &&
        backgroundColor == nil &&
        positionX == nil &&
        positionY == nil &&
        effect == nil &&
        weight == nil &&
        tracking == nil &&
        lineWidth == nil &&
        lineSpacing == nil &&
        maximumLines == nil &&
        alignment == nil &&
        minimumScale == nil &&
        backgroundMode == nil &&
        backgroundPadding == nil &&
        backgroundRadius == nil &&
        shadowEnabled == nil &&
        shadowColor == nil &&
        shadowBlur == nil &&
        shadowOffsetX == nil &&
        shadowOffsetY == nil
    }
    public func resolved(over defaults: CaptionStyle) -> CaptionStyle {
        var value = defaults
        if let formatVersion { value.formatVersion = formatVersion }
        // Keep unsupported provenance visible to validation; never normalize a
        // future format into a supported one because another field needs v2.
        guard (1...2).contains(value.formatVersion) else { return value }
        if let font { value.font = font }
        if let fontSize { value.fontSize = fontSize }
        if let textColor { value.textColor = textColor }
        if let accentColor { value.accentColor = accentColor }
        if let outlineColor { value.outlineColor = outlineColor }
        if let outlineWidth { value.outlineWidth = outlineWidth }
        if let backgroundEnabled { value.backgroundEnabled = backgroundEnabled }
        if let backgroundColor { value.backgroundColor = backgroundColor }
        if let positionX { value.positionX = positionX }
        if let positionY { value.positionY = positionY }
        if let effect { value.effect = effect }
        if let weight { value.weight = weight }
        if let tracking { value.tracking = tracking }
        if let lineWidth { value.lineWidth = lineWidth }
        if let lineSpacing { value.lineSpacing = lineSpacing }
        if let maximumLines { value.maximumLines = maximumLines }
        if let alignment { value.alignment = alignment }
        if let minimumScale { value.minimumScale = minimumScale }
        if let backgroundMode { value.backgroundMode = backgroundMode }
        if let backgroundPadding { value.backgroundPadding = backgroundPadding }
        if let backgroundRadius { value.backgroundRadius = backgroundRadius }
        if let shadowEnabled { value.shadowEnabled = shadowEnabled }
        if let shadowColor { value.shadowColor = shadowColor }
        if let shadowBlur { value.shadowBlur = shadowBlur }
        if let shadowOffsetX { value.shadowOffsetX = shadowOffsetX }
        if let shadowOffsetY { value.shadowOffsetY = shadowOffsetY }
        if let preset { value.preset = preset }
        // Legacy defaults cannot disable an explicitly customized modern field.
        if value.hasExtendedValues || [.condensed, .rounded].contains(value.font) ||
            [.emphasis, .underline, .rise].contains(value.effect) || preset != nil { value.formatVersion = 2 }
        return value
    }
    /// Keep previous overrides, record only fields the user actually changed.
    public mutating func recordChanges(from before: CaptionStyle, to next: CaptionStyle) {
        if before.formatVersion != next.formatVersion { formatVersion = next.formatVersion }
        if before.font != next.font { font = next.font }
        if before.fontSize != next.fontSize { fontSize = next.fontSize }
        if before.textColor != next.textColor { textColor = next.textColor }
        if before.accentColor != next.accentColor { accentColor = next.accentColor }
        if before.outlineColor != next.outlineColor { outlineColor = next.outlineColor }
        if before.outlineWidth != next.outlineWidth { outlineWidth = next.outlineWidth }
        if before.backgroundEnabled != next.backgroundEnabled { backgroundEnabled = next.backgroundEnabled }
        if before.backgroundColor != next.backgroundColor { backgroundColor = next.backgroundColor }
        if before.positionX != next.positionX { positionX = next.positionX }
        if before.positionY != next.positionY { positionY = next.positionY }
        if before.effect != next.effect { effect = next.effect }
        if before.weight != next.weight { weight = next.weight }
        if before.tracking != next.tracking { tracking = next.tracking }
        if before.lineWidth != next.lineWidth { lineWidth = next.lineWidth }
        if before.lineSpacing != next.lineSpacing { lineSpacing = next.lineSpacing }
        if before.maximumLines != next.maximumLines { maximumLines = next.maximumLines }
        if before.alignment != next.alignment { alignment = next.alignment }
        if before.minimumScale != next.minimumScale { minimumScale = next.minimumScale }
        if before.backgroundMode != next.backgroundMode { backgroundMode = next.backgroundMode }
        if before.backgroundPadding != next.backgroundPadding { backgroundPadding = next.backgroundPadding }
        if before.backgroundRadius != next.backgroundRadius { backgroundRadius = next.backgroundRadius }
        if before.shadowEnabled != next.shadowEnabled { shadowEnabled = next.shadowEnabled }
        if before.shadowColor != next.shadowColor { shadowColor = next.shadowColor }
        if before.shadowBlur != next.shadowBlur { shadowBlur = next.shadowBlur }
        if before.shadowOffsetX != next.shadowOffsetX { shadowOffsetX = next.shadowOffsetX }
        if before.shadowOffsetY != next.shadowOffsetY { shadowOffsetY = next.shadowOffsetY }
        if before.preset != next.preset { preset = next.preset }
    }
    /// Applying a preset intentionally overrides its styling, while placement can inherit.
    public mutating func applyPreset(_ value: CaptionStyle, preservingPlacement: Bool = true) {
        formatVersion = value.formatVersion
        font = value.font
        fontSize = value.fontSize
        textColor = value.textColor
        accentColor = value.accentColor
        outlineColor = value.outlineColor
        outlineWidth = value.outlineWidth
        backgroundEnabled = value.backgroundEnabled
        backgroundColor = value.backgroundColor
        effect = value.effect
        weight = value.weight
        tracking = value.tracking
        lineWidth = value.lineWidth
        lineSpacing = value.lineSpacing
        maximumLines = value.maximumLines
        alignment = value.alignment
        minimumScale = value.minimumScale
        backgroundMode = value.backgroundMode
        backgroundPadding = value.backgroundPadding
        backgroundRadius = value.backgroundRadius
        shadowEnabled = value.shadowEnabled
        shadowColor = value.shadowColor
        shadowBlur = value.shadowBlur
        shadowOffsetX = value.shadowOffsetX
        shadowOffsetY = value.shadowOffsetY
        if !preservingPlacement { positionX = value.positionX; positionY = value.positionY }
        preset = value.preset
    }
    public mutating func reset(_ section: CaptionStyleReset) {
        switch section {
        case .typography: font = nil; fontSize = nil; weight = nil; tracking = nil
        case .colors: textColor = nil; accentColor = nil
        case .backdrop: outlineColor = nil; outlineWidth = nil; backgroundEnabled = nil; backgroundColor = nil; backgroundMode = nil; backgroundPadding = nil; backgroundRadius = nil; shadowEnabled = nil; shadowColor = nil; shadowBlur = nil; shadowOffsetX = nil; shadowOffsetY = nil
        case .layout: lineWidth = nil; lineSpacing = nil; maximumLines = nil; alignment = nil; minimumScale = nil
        case .placement: positionX = nil; positionY = nil
        case .motion: effect = nil
        }
        preset = nil
        if effect == nil { formatVersion = nil }
    }
    public func isCustomized(_ section: CaptionStyleReset) -> Bool {
        switch section {
        case .typography: font != nil || fontSize != nil || weight != nil || tracking != nil
        case .colors: textColor != nil || accentColor != nil
        case .backdrop: outlineColor != nil || outlineWidth != nil || backgroundEnabled != nil || backgroundColor != nil || backgroundMode != nil || backgroundPadding != nil || backgroundRadius != nil || shadowEnabled != nil || shadowColor != nil || shadowBlur != nil || shadowOffsetX != nil || shadowOffsetY != nil
        case .layout: lineWidth != nil || lineSpacing != nil || maximumLines != nil || alignment != nil || minimumScale != nil
        case .placement: positionX != nil || positionY != nil
        case .motion: effect != nil
        }
    }
}
