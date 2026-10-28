import Foundation

/// Presentation context belongs to the app-owned session, never the saved project.
/// Switching tools neither seeks playback nor creates an edit/undo entry.
enum EditorTool: String, Identifiable, Hashable, Sendable {
    case captions, style, captionEditor, media
    // The selected-caption editor is contextual, never a bottom-bar action.
    static let primaryTools: [Self] = [.captions, .style, .media]
    var id: Self { self }
    var title: String {
        switch self { case .captions: "Captions"; case .style: "Styles"; case .captionEditor: "Edit caption"; case .media: "Media" }
    }
    var symbol: String {
        switch self { case .captions: "captions.bubble"; case .style: "sparkles"; case .captionEditor: "pencil"; case .media: "crop.rotate" }
    }
}

enum EditorSettingsScope: Hashable, Sendable { case project, clip(UUID) }

struct EditorWorkspace: Sendable {
    var settingsScope = EditorSettingsScope.project
    private(set) var tool = EditorTool.captions
    private var anchors: [EditorTool: String] = [:]
    // Timeline navigation/selection is presentation state, never a saved edit.
    var timelineScale = 48.0
    var timelineCueID: UUID?
    var timelineClipID: UUID?
    var expandedPreview = false
    var presetCategory: CaptionPresetCategory?
    var captionDraft: EditorTextDraft?
    var wordDraft: EditorTextDraft?
    var timingDrafts: [UUID: EditorTimingDraft] = [:]
    private(set) var fieldResetGeneration = UUID()
    var trimDraft: EditorTimingDraft?

    mutating func clearFieldDrafts() {
        captionDraft = nil; wordDraft = nil; timingDrafts.removeAll(); trimDraft = nil
        fieldResetGeneration = UUID()
    }
    func anchor(for tool: EditorTool) -> String? { anchors[tool] }
    mutating func setAnchor(_ value: String?, for tool: EditorTool) {
        if let value { anchors[tool] = value }
    }
    var scrollAnchor: String? {
        get { anchors[tool] }
        set { if let newValue { anchors[tool] = newValue } }
    }
    mutating func select(_ next: EditorTool) {
        guard next != tool else { return }
        tool = next
        if anchors[next] == nil { anchors[next] = "tools" }
    }
}

/// Accepted UI text may include whitespace. Keep it while switching tools,
/// but never replay it over a changed canonical/undo value.
struct EditorTextDraft: Sendable {
    let id: UUID
    let text: String
    let canonical: String
    func value(for id: UUID, canonical: String) -> String? {
        self.id == id && self.canonical == canonical ? text : nil
    }
}

struct EditorTimingDraft: Sendable {
    let id: UUID
    let interval: MediaInterval
    var start: String
    var end: String
}
