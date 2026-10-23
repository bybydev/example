import CoreMedia
import Foundation

/// P1 disk format. Deliberately separate from the Mac Transcript schema.
enum ProjectSchema {
    static let current = 5
}

enum ProjectStoreError: LocalizedError, Sendable {
    case unavailableRoot
    case invalidDocument(String)
    case unsupportedSchema(Int)
    case missingProject(UUID)
    case staleRevision(expected: UInt64, actual: UInt64)
    case invalidPath(String)
    case missingOriginal(String)
    case insufficientSpace
    case unsupportedMedia
    case rightsNotConfirmed
    case unsupportedURL
    case oversizedImport
    case duplicateProject(UUID)

    var errorDescription: String? {
        switch self {
        case .unavailableRoot: "The app's local project storage is unavailable."
        case .invalidDocument(let reason): "The project could not be read: \(reason)"
        case .unsupportedSchema(let version): "This project uses a newer document version (\(version)). Update Inkribe to open it."
        case .missingProject: "The project is unavailable."
        case .staleRevision: "The project changed since this edit began. Reload it before saving."
        case .invalidPath: "An unsafe media path was rejected."
        case .missingOriginal: "A required original media file is missing."
        case .insufficientSpace: "Not enough device storage is available for this import."
        case .unsupportedMedia: "This file has no supported audio or video track."
        case .rightsNotConfirmed: "Confirm that you have permission to import this media."
        case .unsupportedURL: "Only HTTPS direct media links are supported."
        case .oversizedImport: "This file exceeds the supported import size."
        case .duplicateProject: "A project with this identity already exists."
        }
    }
}

struct ProjectCanvas: Codable, Equatable, Sendable {
    var width: Int
    var height: Int

    func validate() throws {
        guard (64...8192).contains(width), (64...8192).contains(height),
              Int64(width) * Int64(height) <= 33_554_432 else {
            throw ProjectStoreError.invalidDocument("Invalid canvas dimensions")
        }
    }
}

enum CanvasPreset: String, Codable, CaseIterable, Sendable {
    case original, portrait, square, landscape, tiktok, reels, shorts, stories, custom

    var canvas: ProjectCanvas? {
        switch self {
        case .original, .custom: nil
        case .portrait, .tiktok, .reels, .shorts, .stories: ProjectCanvas(width: 1080, height: 1920)
        case .square: ProjectCanvas(width: 1080, height: 1080)
        case .landscape: ProjectCanvas(width: 1920, height: 1080)
        }
    }
}

enum MediaKind: String, Codable, Sendable {
    case video, audio
}

enum MediaOrigin: String, Codable, Sendable {
    case files, photos, documentProvider, directURL, camera
}

struct MediaMetadata: Codable, Equatable, Sendable {
    let duration: MediaTime
    let naturalWidth: Int
    let naturalHeight: Int
    let displayedWidth: Int
    let displayedHeight: Int
    let rotationDegrees: Int
    let nominalFrameRate: Double?
    let videoTrackCount: Int
    let audioTrackCount: Int

    func validate() throws {
        guard duration > .zero, naturalWidth >= 0, naturalHeight >= 0,
              displayedWidth >= 0, displayedHeight >= 0,
              videoTrackCount >= 0, audioTrackCount >= 0,
              (videoTrackCount > 0 || audioTrackCount > 0),
              (videoTrackCount == 0 ||
               (naturalWidth > 0 && naturalHeight > 0 && displayedWidth > 0 && displayedHeight > 0)),
              (nominalFrameRate == nil ||
               (nominalFrameRate!.isFinite && nominalFrameRate! > 0 && nominalFrameRate! <= 1000)),
              [-270, -180, -90, 0, 90, 180, 270].contains(rotationDegrees) else {
            throw ProjectStoreError.invalidDocument("Invalid media metadata")
        }
    }
}

struct SourceAsset: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    /// Relative to the project directory. Never use an external bookmark as the authority.
    let relativeOriginalPath: String
    let kind: MediaKind
    let origin: MediaOrigin
    let displayName: String
    let byteCount: Int64
    let sha256: String
    let metadata: MediaMetadata

    func validate() throws {
        guard byteCount > 0, sha256.count == 64,
              sha256.allSatisfy({ $0.isHexDigit }),
              !displayName.isEmpty, displayName.count <= 512 else {
            throw ProjectStoreError.invalidDocument("Invalid source asset")
        }
        try OwnedPath.validate(relativeOriginalPath, base: "Originals")
        try metadata.validate()
    }
}

struct ProjectClip: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let sourceAssetID: UUID
    let sourceInterval: MediaInterval
    let timelineInterval: MediaInterval

    func validate(assets: [UUID: SourceAsset]) throws {
        guard let source = assets[sourceAssetID],
              sourceInterval.start >= .zero,
              sourceInterval.end <= source.metadata.duration else {
            throw ProjectStoreError.invalidDocument("Clip refers to absent or out-of-range media")
        }
        let mapping = try IdentityClipMapping(
            clipID: id, sourceAssetID: sourceAssetID,
            sourceInterval: sourceInterval, timelineStart: timelineInterval.start
        )
        guard mapping.timelineInterval == timelineInterval else {
            throw ProjectStoreError.invalidDocument("Invalid identity clip mapping")
        }
    }
}

struct ProjectDocument: Codable, Equatable, Sendable, Identifiable {
    var schemaVersion: Int
    let id: UUID
    var contentRevision: UInt64
    var title: String
    let createdAt: Date
    var updatedAt: Date
    var preset: CanvasPreset
    var canvas: ProjectCanvas
    var assets: [SourceAsset]
    var clips: [ProjectClip]
    var recognition: Recognition? = nil
    var captionStyle: CaptionStyle? = nil
    var mediaEdits: MediaEdits? = nil

    var effectiveCaptionStyle: CaptionStyle { captionStyle ?? .standard }
    var effectiveMediaEdits: MediaEdits { mediaEdits ?? .standard }
    var sourceDuration: MediaTime { clips.map(\.timelineInterval.end).max() ?? .zero }
    var outputDuration: MediaTime { OutputTimeline(self).duration }

    func validate() throws {
        guard schemaVersion <= ProjectSchema.current else {
            throw ProjectStoreError.unsupportedSchema(schemaVersion)
        }
        guard (1...ProjectSchema.current).contains(schemaVersion),
              (schemaVersion >= 2 || recognition == nil), contentRevision > 0,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.count <= 256, updatedAt >= createdAt,
              !assets.isEmpty, !clips.isEmpty else {
            throw ProjectStoreError.invalidDocument("Invalid project header or empty media graph")
        }
        try canvas.validate()
        guard schemaVersion >= 4 || captionStyle == nil else {
            throw ProjectStoreError.invalidDocument("Caption styles require schema v4")
        }
        try captionStyle?.validate()
        guard schemaVersion >= 5 || mediaEdits == nil else {
            throw ProjectStoreError.invalidDocument("Media edits require schema v5")
        }
        try mediaEdits?.validate(sourceDuration: sourceDuration)
        guard outputDuration > .zero else { throw MediaEditError.invalidSettings }
        if let dimensions = preset.canvas, dimensions != canvas {
            throw ProjectStoreError.invalidDocument("Preset does not match canvas")
        }
        guard Set(assets.map(\.id)).count == assets.count,
              Set(clips.map(\.id)).count == clips.count else {
            throw ProjectStoreError.invalidDocument("Duplicate asset or clip ID")
        }
        for asset in assets { try asset.validate() }
        let index = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        for clip in clips { try clip.validate(assets: index) }
        guard schemaVersion >= 3 || recognition?.words.allSatisfy({ $0.adjustedSourceInterval == nil &&
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) != false else {
            throw ProjectStoreError.invalidDocument("Manual captions require schema v3")
        }
        try recognition?.validate(clips: clips, assets: assets)
        let ordered = clips.sorted { $0.timelineInterval.start < $1.timelineInterval.start }
        for pair in zip(ordered, ordered.dropFirst()) {
            guard pair.0.timelineInterval.end <= pair.1.timelineInterval.start else {
                throw ProjectStoreError.invalidDocument("P1 clips must not overlap")
            }
        }
    }
}

/// Use fixed, UUID-based media names; validate on read *and* before every disk access.
enum OwnedPath {
    static func validate(_ path: String, base: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2, components[0] == Substring(base),
              !components[1].isEmpty, components[1] != ".", components[1] != "..",
              !components[1].contains("\\"), !components[1].contains(":"),
              !components[1].contains("%"), !components[1].contains("\u{0}") else {
            throw ProjectStoreError.invalidPath(path)
        }
    }

    static func secureURL(for relativePath: String, base: String, in project: URL) throws -> URL {
        try validate(relativePath, base: base)
        let root = project.resolvingSymlinksInPath().standardizedFileURL
        let candidate = project.appendingPathComponent(relativePath).standardizedFileURL
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(root.path + "/"),
              candidate.path.hasPrefix(project.standardizedFileURL.path + "/") else {
            throw ProjectStoreError.invalidPath(relativePath)
        }
        return candidate
    }
}

struct ProjectSummary: Identifiable, Sendable {
    let id: UUID
    let title: String
    let updatedAt: Date
    let duration: MediaTime
    let mediaKind: MediaKind
    let available: Bool
    let thumbnailURL: URL?
    let contentRevision: UInt64
    let captionState: ProjectCaptionState
}

/// Derived library metadata only; never persisted into the project schema.
enum ProjectCaptionState: Sendable {
    case needsTranscription, emptyResult, saved, noAudio
}

enum LibrarySort: String, Hashable, Sendable {
    case recent, oldest, title
}

enum LibraryFilter: String, Hashable, Sendable {
    case all, video, audio, missingMedia
}

struct LibraryIssue: Identifiable, Sendable {
    let id: UUID
    let description: String
}

struct LibrarySnapshot: Sendable {
    let projects: [ProjectSummary]
    let issues: [LibraryIssue]
}
