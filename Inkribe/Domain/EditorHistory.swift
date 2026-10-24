import Foundation

/// Value-only undo payloads, independent of SwiftUI, focus, gestures and AVPlayer.
struct EditorSelection: Sendable { let cue: UUID?; let word: UUID? }
struct EditorHistoryEntry: Sendable {
    var change: EditorHistoryChange
    let selectionBefore: EditorSelection
    var selectionAfter: EditorSelection
}
enum EditorHistoryChange: Sendable {
    case caption(CaptionEditPatch)
    case style(before: CaptionStyle?, after: CaptionStyle?)
    case media(before: MediaEditState, after: MediaEditState)

    var changesMedia: Bool { if case .media = self { true } else { false } }

    /// Compare the expected edited state before applying; stale history must not
    /// overwrite new speech publication, another revision or a newer correction.
    func applying(to document: ProjectDocument, forward: Bool) throws -> ProjectDocument {
        var project = document
        switch self {
        case .caption(let patch):
            guard let result = project.recognition else { throw CaptionEditError.missingCaption }
            let state = try patch.applying(to: CaptionEditState(result), forward: forward)
            project.recognition = state.applying(to: result)
        case .style(let before, let after):
            guard project.captionStyle == (forward ? before : after) else { throw CaptionEditError.missingCaption }
            project.captionStyle = forward ? after : before
        case .media(let before, let after):
            guard MediaEditState(project) == (forward ? before : after) else { throw MediaEditError.invalidSettings }
            project = (forward ? after : before).applying(to: project)
        }
        project.schemaVersion = ProjectSchema.current
        try project.validate()
        return project
    }

    var estimatedBytes: Int {
        switch self {
        case .caption(let patch): patch.estimatedBytes
        case .style: MemoryLayout<CaptionStyle>.stride * 2
        case .media: MemoryLayout<MediaEditState>.stride * 2
        }
    }
    mutating func coalesceText(_ next: CaptionEditPatch) -> Bool {
        guard case .caption(var patch) = self, patch.coalesceText(next) else { return false }
        self = .caption(patch)
        return true
    }
    mutating func coalesceStyle(from previous: CaptionStyle?, to next: CaptionStyle) -> Bool {
        guard case .style(let before, let after) = self, after == previous else { return false }
        self = .style(before: before, after: next)
        return true
    }
    mutating func coalesceMedia(from previous: MediaEditState, to next: MediaEditState) -> Bool {
        guard case .media(let before, let after) = self, after == previous else { return false }
        self = .media(before: before, after: next)
        return true
    }
}

/// Retains the existing command/payload budget. One oversized operation remains
/// undoable; a new accepted edit invalidates redo. Native/UI ownership stays out.
struct EditorHistory: Sendable {
    var past: [EditorHistoryEntry] = []
    var future: [EditorHistoryEntry] = []
    mutating func reset() { past.removeAll(); future.removeAll() }
    mutating func finishEdit() {
        while past.count > 1 && (past.count > 50 || past.reduce(0, { $0 + $1.change.estimatedBytes }) > 8 * 1_024 * 1_024) {
            past.removeFirst()
        }
        future.removeAll()
    }
}
