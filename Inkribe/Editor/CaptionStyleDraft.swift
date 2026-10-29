import Foundation
import Observation

/// Local caption appearance and placement for the whole project.
/// No document, history or repository value changes until Done succeeds.
@MainActor @Observable
final class CaptionStyleDraft {
    let projectID: UUID
    let initialProjectStyle: CaptionStyle?
    let initialOverrides: [UUID: CaptionStyleOverrides]
    private(set) var projectStyle: CaptionStyle?
    private(set) var generation = 0
    var error: String?

    init(document: ProjectDocument) {
        projectID = document.id
        initialProjectStyle = document.captionStyle
        projectStyle = document.captionStyle
        initialOverrides = Dictionary(uniqueKeysWithValues: document.clips.map {
            ($0.id, document.settings(for: $0.id).captions)
        })
    }

    var style: CaptionStyle { projectStyle ?? .standard }
    var resetPreset: CaptionPreset? {
        CaptionPreset.definition(for: style.preset) ?? CaptionPreset.matching(style)
    }
    var styleName: String { resetPreset?.name ?? "Custom style" }
    var isModified: Bool { resetPreset.map { !$0.matches(style) } ?? true }
    var hasChanges: Bool {
        projectStyle != initialProjectStyle || initialOverrides.values.contains { $0 != CaptionStyleOverrides() }
    }

    @discardableResult
    func setStyle(_ proposed: CaptionStyle, access: ProAccess) -> Bool {
        error = nil
        var next = proposed
        if next.formatVersion == 1 && (next.hasExtendedValues || [.condensed, .rounded].contains(next.font) ||
            [.emphasis, .underline, .rise].contains(next.effect)) { next.formatVersion = 2 }
        guard !access.isChecking, access.canChangeStyle(from: style, to: next) else { return false }
        do { try next.validate() }
        catch { self.error = error.localizedDescription; return false }
        guard next != style else { return true }
        projectStyle = next
        generation += 1
        return true
    }

    func applying(to document: ProjectDocument, access: ProAccess) throws -> ProjectDocument {
        guard document.id == projectID else { throw CaptionStyleDraftError.stale }
        guard hasChanges else { return document }
        guard !access.isChecking else { throw CaptionStyleDraftError.checkingPurchases }
        let current = Dictionary(uniqueKeysWithValues: document.clips.map {
            ($0.id, document.settings(for: $0.id).captions)
        })
        guard document.captionStyle == initialProjectStyle, current == initialOverrides else { throw CaptionStyleDraftError.stale }
        guard access.canChangeStyle(from: document.effectiveCaptionStyle, to: style) else { throw ProError.requiresPro(.styles) }
        var next = document.usingProjectCaptionStyle()
        next.captionStyle = projectStyle
        next.schemaVersion = ProjectSchema.current
        try next.validate()
        return next
    }
}

enum CaptionStyleDraftError: LocalizedError {
    case stale, checkingPurchases
    var errorDescription: String? {
        switch self {
        case .stale: "The caption settings changed while Style was open. Cancel and reopen Style to use the latest settings."
        case .checkingPurchases: "Purchases are still being checked. Try Done again in a moment."
        }
    }
}
