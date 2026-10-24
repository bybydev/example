import Foundation

public enum CaptionPresetCategory: String, CaseIterable, Hashable, Sendable {
    case essential = "Essential", creator = "Creator", podcast = "Podcast", cinematic = "Cinematic", education = "Education", editorial = "Editorial"
}

/// Definitions are immutable by (id, version). A catalog update adds a revision;
/// opening a project NEVER resolves its saved style against current defaults.
public struct CaptionPreset: Identifiable, Sendable {
    public let id: String
    public let version: Int
    public let name: String
    public let category: CaptionPresetCategory
    public let detail: String
    public let style: CaptionStyle
    public var reference: CaptionPresetReference { .init(id: id, version: version) }
    public static let catalogVersion = 2
    public static let basic = Self(id: "basic", version: 1, name: "Basic", category: .essential,
        detail: "Clear centered captions in a quiet box", style: .standard)

    private static let legacy: [Self] = [basic] + CaptionTemplate.allCases.map {
        Self(id: $0.rawValue, version: 1, name: $0.name, category: .creator,
            detail: "Original \($0.name) look", style: $0.style)
    }

    public static let catalog: [Self] = [basic] + CaptionTemplate.allCases.map {
        var style = $0.style
        style.formatVersion = 2
        return Self(id: $0.rawValue, version: 2, name: $0.name,
            category: $0 == .softFade ? .cinematic : .creator,
            detail: legacyDetail($0), style: style)
    } + additions

    public static func definition(for reference: CaptionPresetReference?) -> Self? {
        guard let reference else { return nil }
        return (catalog + legacy).first { $0.id == reference.id && $0.version == reference.version }
    }

    public func preservingPosition(of current: CaptionStyle) -> CaptionStyle {
        var next = style
        next.positionX = current.positionX; next.positionY = current.positionY
        next.preset = reference
        return next
    }

    /// Value matching is only a visual hint for untagged legacy projects; it
    /// never invents persisted ancestry or upgrades the style on reopen.
    public static func matching(_ style: CaptionStyle) -> Self? {
        if let saved = definition(for: style.preset), saved.matches(style) { return saved }
        guard style.preset == nil else { return nil }
        return (catalog + legacy).first { $0.matches(style) }
    }
    public func matches(_ current: CaptionStyle) -> Bool {
        preservingPosition(of: current).withoutPreset == current.withoutPreset
    }
    public var resolved: CaptionStyle {
        var value = style; value.preset = reference; return value
    }

    private static func legacyDetail(_ template: CaptionTemplate) -> String {
        switch template {
        case .spotlight: "Bold active-unit highlight without a box"
        case .karaoke: "Mint progress for word-timed captions; phrase emphasis otherwise"
        case .pop: "Expressive pink captions with a timed pulse"
        case .softFade: "Warm serif captions with gentle entrance and exit"
        }
    }
    private static let additions: [Self] = {
        func make(_ id: String, _ name: String, _ category: CaptionPresetCategory,
                  _ detail: String, _ configure: (inout CaptionStyle) -> Void) -> Self {
            var style = CaptionStyle.standard
            style.formatVersion = 2
            style.minimumScale = 0.65
            configure(&style)
            return Self(id: id, version: 1, name: name, category: category, detail: detail, style: style)
        }
        return [
            make("punch", "Punch", .creator, "Heavy condensed headlines, two lines and a confident pulse") {
                $0.font = .condensed; $0.weight = .heavy; $0.fontSize = 0.09
                $0.backgroundEnabled = false; $0.outlineWidth = 0.075; $0.effect = .pop
                $0.maximumLines = 2; $0.lineWidth = 0.9; $0.lineSpacing = 0.05; $0.positionY = 0.7
            },
            make("podcast", "Podcast", .podcast, "Rounded speech with individual line pills and active color") {
                $0.font = .rounded; $0.fontSize = 0.065; $0.effect = .emphasis
                $0.accentColor = .mint; $0.outlineWidth = 0; $0.maximumLines = 3; $0.lineWidth = 0.85
                $0.backgroundMode = .lines; $0.backgroundPadding = 0.18; $0.backgroundRadius = 0.5
                $0.lineSpacing = 0.45; $0.backgroundColor = CaptionColor(red: 0.025, green: 0.04, blue: 0.06, alpha: 0.88)
            },
            make("cinema", "Cinema", .cinematic, "Quiet regular serif, open frame and soft text shadow") {
                $0.font = .serif; $0.weight = .regular; $0.fontSize = 0.05; $0.effect = .fade
                $0.backgroundEnabled = false; $0.outlineWidth = 0; $0.shadowEnabled = true
                $0.shadowBlur = 0.3; $0.shadowOffsetY = 0.1; $0.lineWidth = 0.78
                $0.maximumLines = 3; $0.lineSpacing = 0.22; $0.positionY = 0.87
            },
            make("classroom", "Classroom", .education, "Leading mono notes with an active-unit underline") {
                $0.font = .mono; $0.weight = .medium; $0.fontSize = 0.055; $0.effect = .underline
                $0.textColor = CaptionColor(red: 0.08, green: 0.1, blue: 0.15); $0.accentColor = CaptionColor(red: 0.12, green: 0.32, blue: 0.85)
                $0.backgroundColor = CaptionColor(red: 0.97, green: 0.96, blue: 0.9, alpha: 0.96)
                $0.outlineWidth = 0; $0.backgroundRadius = 0.08; $0.backgroundPadding = 0.4
                $0.maximumLines = 4; $0.lineWidth = 0.84; $0.lineSpacing = 0.3; $0.alignment = .leading
                $0.positionY = 0.22
            },
            make("editorial", "Editorial", .editorial, "Leading bold title, generous spacing and a subtle rise") {
                $0.font = .bold; $0.weight = .heavy; $0.fontSize = 0.075; $0.effect = .rise
                $0.backgroundEnabled = false; $0.outlineWidth = 0.02; $0.shadowEnabled = true
                $0.shadowBlur = 0.16; $0.shadowOffsetY = 0.08; $0.tracking = 0.015
                $0.lineWidth = 0.7; $0.maximumLines = 3; $0.lineSpacing = 0.25; $0.alignment = .leading
                $0.positionY = 0.35
            }
        ]
    }()
}
