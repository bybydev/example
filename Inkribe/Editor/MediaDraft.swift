import Foundation
import Observation

/// One local transaction across Project and every clip. Legacy defaults are
/// resolved on entry; successful edits store independent clip values without
/// changing the appearance or level of untouched clips.
@MainActor @Observable
final class MediaDraft {
    let projectID: UUID
    let clips: [ProjectClip]
    let assets: [SourceAsset]
    let sourceDuration: MediaTime
    private let initialEdits: MediaEdits?
    private let initialCanvas: ProjectCanvas
    private let initialPreset: CanvasPreset
    private let initialMute: Bool?
    private let initialClipMedia: [UUID: ClipMediaOverrides]
    private let initialClipEdits: [UUID: MediaEdits]
    let originalVideoCanvas: ProjectCanvas?
    private let initialTrimState: ClipTrimState

    var scope = EditorSettingsScope.project
    var canvas: ProjectCanvas
    var preset: CanvasPreset
    var originalAudioMuted: Bool
    private(set) var clipEdits: [UUID: MediaEdits]
    @ObservationIgnored private(set) var isClosed = false

    init(document: ProjectDocument) {
        projectID = document.id; clips = document.orderedClips; assets = document.assets
        sourceDuration = document.sourceDuration
        initialEdits = document.mediaEdits; initialCanvas = document.canvas
        initialPreset = document.preset; initialMute = document.originalAudioMuted
        canvas = document.canvas; preset = document.preset
        originalAudioMuted = document.isOriginalAudioMuted
        initialTrimState = ClipTrimState(document)
        let timeline = OutputTimeline(document)
        let used = Set(document.clips.filter { timeline.retained($0.timelineInterval) != nil }.map(\.sourceAssetID))
        if let source = document.assets.first(where: { used.contains($0.id) && $0.metadata.videoTrackCount > 0 }) {
            originalVideoCanvas = ProjectCanvas(width: source.metadata.displayedWidth, height: source.metadata.displayedHeight)
        } else { originalVideoCanvas = nil }
        let settings = Dictionary(uniqueKeysWithValues: (document.clipSettings ?? []).map { ($0.id, $0) })
        initialClipMedia = Dictionary(uniqueKeysWithValues: document.clips.map { clip in
            (clip.id, settings[clip.id]?.media ?? ClipMediaOverrides())
        })
        let resolved = Dictionary(uniqueKeysWithValues: document.clips.map { clip in
            var value = (settings[clip.id]?.media ?? ClipMediaOverrides()).resolved(over: document.effectiveMediaEdits)
            value.trim = nil
            return (clip.id, value)
        })
        initialClipEdits = resolved; clipEdits = resolved
    }

    var selectedClipID: UUID? {
        if case .clip(let id) = scope { return id }
        return nil
    }
    func media(for id: UUID) -> MediaEdits { clipEdits[id] ?? .standard }
    func setMedia(_ value: MediaEdits, for id: UUID) {
        guard !isClosed, clipEdits[id] != nil else { return }
        var next = value; next.trim = nil
        clipEdits[id] = next
    }
    func resetFraming(for id: UUID) {
        var next = media(for: id)
        next.fit = .fit; next.zoom = 1; next.positionX = 0.5; next.positionY = 0.5
        setMedia(next, for: id)
    }
    func resetVolume(for id: UUID) {
        var next = media(for: id); next.volume = 1
        setMedia(next, for: id)
    }
    func close() { isClosed = true }

    /// Match the source graph and media state only. Unrelated caption publication
    /// and clip renaming can remain in the latest document without being replaced.
    func applying(to document: ProjectDocument) throws -> ProjectDocument {
        guard !isClosed else { throw CancellationError() }
        let currentSettings = Dictionary(uniqueKeysWithValues: (document.clipSettings ?? []).map { ($0.id, $0) })
        guard document.id == projectID, ClipTrimState(document) == initialTrimState, document.orderedClips == clips, document.assets == assets,
              document.mediaEdits == initialEdits, document.canvas == initialCanvas,
              document.preset == initialPreset, document.originalAudioMuted == initialMute,
              Dictionary(uniqueKeysWithValues: document.clips.map {
                  ($0.id, currentSettings[$0.id]?.media ?? ClipMediaOverrides())
              }) == initialClipMedia else { throw MediaDraftError.stale }
        let changed = canvas != initialCanvas || preset != initialPreset ||
            originalAudioMuted != (initialMute ?? false) || clipEdits != initialClipEdits
        guard changed else { return document }

        var next = document
        next.canvas = canvas; next.preset = preset
        next.originalAudioMuted = originalAudioMuted ? true : nil
        // Keep the established project trim clock, with standard values as the
        // compatibility fallback for future clips. Every existing clip is explicit.
        var projectEdits = MediaEdits.standard
        projectEdits.trim = initialEdits?.trim
        next.mediaEdits = projectEdits == .standard ? nil : projectEdits
        next.clipSettings = try clips.map { clip in
            guard let value = clipEdits[clip.id] else { throw MediaDraftError.stale }
            try value.validate(sourceDuration: sourceDuration)
            var settings = currentSettings[clip.id] ?? ClipSettings(id: clip.id)
            settings.media = ClipMediaOverrides(fit: value.fit, zoom: value.zoom,
                positionX: value.positionX, positionY: value.positionY, volume: value.volume)
            return settings
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        next.schemaVersion = ProjectSchema.current
        try next.validate()
        return next
    }
}

enum MediaDraftError: LocalizedError {
    case stale
    var errorDescription: String? {
        "The media settings changed while Media was open. Cancel and reopen Media to use the latest settings."
    }
}
