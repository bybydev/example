import CoreMedia
import Foundation

/// P1 disk format. Deliberately separate from the Mac Transcript schema.
enum IOSProjectSchema {
    static let current = 3
}

enum IOSProjectStoreError: LocalizedError, Sendable {
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

struct IOSCanvas: Codable, Equatable, Sendable {
    var width: Int
    var height: Int

    func validate() throws {
        guard (64...8192).contains(width), (64...8192).contains(height),
              Int64(width) * Int64(height) <= 33_554_432 else {
            throw IOSProjectStoreError.invalidDocument("Invalid canvas dimensions")
        }
    }
}

enum IOSCanvasPreset: String, Codable, CaseIterable, Sendable {
    case original, portrait, square, landscape, tiktok, reels, shorts, stories, custom

    var canvas: IOSCanvas? {
        switch self {
        case .original, .custom: nil
        case .portrait, .tiktok, .reels, .shorts, .stories: IOSCanvas(width: 1080, height: 1920)
        case .square: IOSCanvas(width: 1080, height: 1080)
        case .landscape: IOSCanvas(width: 1920, height: 1080)
        }
    }
}

enum IOSMediaKind: String, Codable, Sendable {
    case video, audio
}

enum IOSMediaOrigin: String, Codable, Sendable {
    case files, photos, documentProvider, directURL, camera
}

struct IOSMediaMetadata: Codable, Equatable, Sendable {
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
              videoTrackCount + audioTrackCount > 0,
              (videoTrackCount == 0 ||
               (naturalWidth > 0 && naturalHeight > 0 && displayedWidth > 0 && displayedHeight > 0)),
              (nominalFrameRate == nil ||
               (nominalFrameRate!.isFinite && nominalFrameRate! > 0 && nominalFrameRate! <= 1000)),
              [-270, -180, -90, 0, 90, 180, 270].contains(rotationDegrees) else {
            throw IOSProjectStoreError.invalidDocument("Invalid media metadata")
        }
    }
}

struct IOSSourceAsset: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    /// Relative to the project directory. Never use an external bookmark as the authority.
    let relativeOriginalPath: String
    let kind: IOSMediaKind
    let origin: IOSMediaOrigin
    let displayName: String
    let byteCount: Int64
    let sha256: String
    let metadata: IOSMediaMetadata

    func validate() throws {
        guard byteCount > 0, sha256.count == 64,
              sha256.allSatisfy({ $0.isHexDigit }),
              !displayName.isEmpty, displayName.count <= 512 else {
            throw IOSProjectStoreError.invalidDocument("Invalid source asset")
        }
        try IOSOwnedPath.validate(relativeOriginalPath, base: "Originals")
        try metadata.validate()
    }
}

struct IOSProjectClip: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let sourceAssetID: UUID
    let sourceInterval: MediaInterval
    let timelineInterval: MediaInterval

    func validate(assets: [UUID: IOSSourceAsset]) throws {
        guard let source = assets[sourceAssetID],
              sourceInterval.start >= .zero,
              sourceInterval.end <= source.metadata.duration else {
            throw IOSProjectStoreError.invalidDocument("Clip refers to absent or out-of-range media")
        }
        let mapping = try IdentityClipMapping(
            clipID: id, sourceAssetID: sourceAssetID,
            sourceInterval: sourceInterval, timelineStart: timelineInterval.start
        )
        guard mapping.timelineInterval == timelineInterval else {
            throw IOSProjectStoreError.invalidDocument("Invalid identity clip mapping")
        }
    }
}

struct IOSProjectDocument: Codable, Equatable, Sendable, Identifiable {
    var schemaVersion: Int
    let id: UUID
    var contentRevision: UInt64
    var title: String
    let createdAt: Date
    var updatedAt: Date
    var preset: IOSCanvasPreset
    var canvas: IOSCanvas
    var assets: [IOSSourceAsset]
    var clips: [IOSProjectClip]
    var recognition: IOSRecognition? = nil

    func validate() throws {
        guard schemaVersion <= IOSProjectSchema.current else {
            throw IOSProjectStoreError.unsupportedSchema(schemaVersion)
        }
        guard (1...IOSProjectSchema.current).contains(schemaVersion),
              (schemaVersion >= 2 || recognition == nil), contentRevision > 0,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.count <= 256, updatedAt >= createdAt,
              !assets.isEmpty, !clips.isEmpty else {
            throw IOSProjectStoreError.invalidDocument("Invalid project header or empty media graph")
        }
        try canvas.validate()
        if let dimensions = preset.canvas, dimensions != canvas {
            throw IOSProjectStoreError.invalidDocument("Preset does not match canvas")
        }
        guard Set(assets.map(\.id)).count == assets.count,
              Set(clips.map(\.id)).count == clips.count else {
            throw IOSProjectStoreError.invalidDocument("Duplicate asset or clip ID")
        }
        for asset in assets { try asset.validate() }
        let index = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        for clip in clips { try clip.validate(assets: index) }
        guard schemaVersion >= 3 || recognition?.words.allSatisfy({ $0.adjustedSourceInterval == nil &&
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) != false else {
            throw IOSProjectStoreError.invalidDocument("Manual captions require schema v3")
        }
        try recognition?.validate(clips: clips, assets: assets)
        let ordered = clips.sorted { $0.timelineInterval.start < $1.timelineInterval.start }
        for pair in zip(ordered, ordered.dropFirst()) {
            guard pair.0.timelineInterval.end <= pair.1.timelineInterval.start else {
                throw IOSProjectStoreError.invalidDocument("P1 clips must not overlap")
            }
        }
    }
}

/// Use fixed, UUID-based media names; validate on read *and* before every disk access.
enum IOSOwnedPath {
    static func validate(_ path: String, base: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2, components[0] == Substring(base),
              !components[1].isEmpty, components[1] != ".", components[1] != "..",
              !components[1].contains("\\"), !components[1].contains(":"),
              !components[1].contains("%"), !components[1].contains("\u{0}") else {
            throw IOSProjectStoreError.invalidPath(path)
        }
    }

    static func secureURL(for relativePath: String, base: String, in project: URL) throws -> URL {
        try validate(relativePath, base: base)
        let root = project.resolvingSymlinksInPath().standardizedFileURL
        let candidate = project.appendingPathComponent(relativePath).standardizedFileURL
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(root.path + "/"),
              candidate.path.hasPrefix(project.standardizedFileURL.path + "/") else {
            throw IOSProjectStoreError.invalidPath(relativePath)
        }
        return candidate
    }
}

struct IOSProjectSummary: Identifiable, Sendable {
    let id: UUID
    let title: String
    let updatedAt: Date
    let duration: MediaTime
    let mediaKind: IOSMediaKind
    let available: Bool
    let thumbnailURL: URL?
}

enum IOSLibrarySort: String, Hashable, Sendable {
    case recent, oldest, title
}

enum IOSLibraryFilter: String, Hashable, Sendable {
    case all, video, audio, missingMedia
}

struct IOSLibraryIssue: Identifiable, Sendable {
    let id: UUID
    let description: String
}

struct IOSLibrarySnapshot: Sendable {
    let projects: [IOSProjectSummary]
    let issues: [IOSLibraryIssue]
}
