import Foundation

/// Presentation context belongs to the app-owned session, never the saved project.
/// Switching tools neither seeks playback nor creates an edit/undo entry.
enum EditorTool: String, CaseIterable, Identifiable, Sendable {
    case captions, style, timing, media
    var id: Self { self }
    var title: String {
        switch self { case .captions: "Captions"; case .style: "Style"; case .timing: "Timing"; case .media: "Media" }
    }
    var symbol: String {
        switch self { case .captions: "captions.bubble"; case .style: "textformat"; case .timing: "timer"; case .media: "crop.rotate" }
    }
}

struct EditorWorkspace: Sendable {
    private(set) var tool = EditorTool.captions
    private var anchors: [EditorTool: String] = [:]
    var followsPlayback = false
    var expandedPreview = false
    var presetCategory: CaptionPresetCategory?
    var captionDraft: EditorTextDraft?
    var wordDraft: EditorTextDraft?
    var expandedCaptionTiming: UUID?
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
