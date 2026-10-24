import Foundation
import InkribeCore

typealias CaptionStyleOverrides = InkribeCore.CaptionStyleOverrides

/// Clip framing/audio overrides never contain project trim or output dimensions.
struct ClipMediaOverrides: Codable, Equatable, Sendable {
    var fit: MediaFit? = nil
    var zoom: Double? = nil
    var positionX: Double? = nil
    var positionY: Double? = nil
    var volume: Double? = nil
    var isEmpty: Bool { fit == nil && zoom == nil && positionX == nil && positionY == nil && volume == nil }
    func resolved(over defaults: MediaEdits) -> MediaEdits {
        var value = defaults
        if let fit { value.fit = fit }
        if let zoom { value.zoom = zoom }
        if let positionX { value.positionX = positionX }
        if let positionY { value.positionY = positionY }
        if let volume { value.volume = volume }
        return value
    }
    mutating func recordChanges(from before: MediaEdits, to next: MediaEdits) {
        if before.fit != next.fit { fit = next.fit }
        if before.zoom != next.zoom { zoom = next.zoom }
        if before.positionX != next.positionX { positionX = next.positionX }
        if before.positionY != next.positionY { positionY = next.positionY }
        if before.volume != next.volume { volume = next.volume }
    }
}

struct ClipSettings: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    /// A user-facing label only; source names, media paths and clip identity stay fixed.
    var displayName: String? = nil
    var captions: CaptionStyleOverrides = .init()
    var media: ClipMediaOverrides = .init()
    var hasOverrides: Bool { !captions.isEmpty || !media.isEmpty }
    var isEmpty: Bool { displayName == nil && !hasOverrides }
}

extension ProjectDocument {
    var orderedClips: [ProjectClip] {
        clips.sorted { $0.timelineInterval.start < $1.timelineInterval.start }
    }
    func settings(for clipID: UUID) -> ClipSettings {
        clipSettings?.first { $0.id == clipID } ?? ClipSettings(id: clipID)
    }
    mutating func setSettings(_ value: ClipSettings) {
        var settings = clipSettings ?? []
        settings.removeAll { $0.id == value.id }
        if !value.isEmpty { settings.append(value) }
        clipSettings = settings.isEmpty ? nil : settings.sorted { $0.id.uuidString < $1.id.uuidString }
    }
    func captionStyle(for clipID: UUID) -> CaptionStyle {
        settings(for: clipID).captions.resolved(over: effectiveCaptionStyle)
    }
    func mediaEdits(for clipID: UUID) -> MediaEdits {
        settings(for: clipID).media.resolved(over: effectiveMediaEdits)
    }
    func clipName(_ clip: ProjectClip) -> String {
        settings(for: clip.id).displayName ?? originalClipName(clip)
    }
    func originalClipName(_ clip: ProjectClip) -> String {
        assets.first { $0.id == clip.sourceAssetID }?.displayName ?? "Clip"
    }
}

/// Small undo payload; never copies recognition or original media.
struct ProjectSettingsState: Equatable, Sendable {
    let captionStyle: CaptionStyle?
    let mediaEdits: MediaEdits?
    let clipSettings: [ClipSettings]?
    let canvas: ProjectCanvas
    let preset: CanvasPreset
    init(_ document: ProjectDocument) {
        captionStyle = document.captionStyle; mediaEdits = document.mediaEdits
        clipSettings = document.clipSettings; canvas = document.canvas; preset = document.preset
    }
    func applying(to document: ProjectDocument) -> ProjectDocument {
        var value = document
        value.captionStyle = captionStyle; value.mediaEdits = mediaEdits
        value.clipSettings = clipSettings; value.canvas = canvas; value.preset = preset
        return value
    }
    func changesMedia(from other: Self) -> Bool {
        let current = Dictionary(uniqueKeysWithValues: (clipSettings ?? []).filter { !$0.media.isEmpty }.map { ($0.id, $0.media) })
        let previous = Dictionary(uniqueKeysWithValues: (other.clipSettings ?? []).filter { !$0.media.isEmpty }.map { ($0.id, $0.media) })
        return mediaEdits != other.mediaEdits || canvas != other.canvas || preset != other.preset || current != previous
    }
}
