import Foundation
import PDFKitAudio

nonisolated enum ProjectSchema {
    static let currentVersion = 1
    static let packageExtension = "readaloud"
}

nonisolated enum ProjectSourceType: String, Codable, Sendable, CaseIterable {
    case epub
    case pdf
    case document
    case paste
    case article
}

nonisolated struct ProjectSource: Codable, Equatable, Sendable {
    let id: UUID
    let type: ProjectSourceType
    let originalFileName: String
    let relativePath: String
    let sourceRevision: String
    // These optional additions decode as nil for existing schema-v1 projects.
    let originalURL: URL?
    let siteName: String?
    let language: String?
    let publishedTime: String?

    init(
        id: UUID = UUID(),
        type: ProjectSourceType,
        originalFileName: String,
        relativePath: String,
        sourceRevision: String,
        originalURL: URL? = nil,
        siteName: String? = nil,
        language: String? = nil,
        publishedTime: String? = nil
    ) {
        self.id = id
        self.type = type
        self.originalFileName = originalFileName
        self.relativePath = relativePath
        self.sourceRevision = sourceRevision
        self.originalURL = originalURL
        self.siteName = siteName
        self.language = language
        self.publishedTime = publishedTime
    }
}

nonisolated struct ProjectArtwork: Codable, Equatable, Sendable {
    let relativePath: String
}

nonisolated struct ProjectNarrationSettings: Codable, Equatable, Sendable {
    var voiceID: String?
    var speed: Double?

    init(voiceID: String? = nil, speed: Double? = nil) {
        self.voiceID = voiceID
        self.speed = speed
    }
}

nonisolated enum ItemSettingMode: String, Codable, Sendable {
    case inherit
    case custom
}

nonisolated struct ItemVoiceSetting: Codable, Equatable, Sendable {
    var mode: ItemSettingMode
    var customValue: String?

    init(mode: ItemSettingMode = .inherit, customValue: String? = nil) {
        self.mode = mode
        self.customValue = customValue
    }
}

nonisolated struct ItemSpeedSetting: Codable, Equatable, Sendable {
    var mode: ItemSettingMode
    var customValue: Double?

    init(mode: ItemSettingMode = .inherit, customValue: Double? = nil) {
        self.mode = mode
        self.customValue = customValue
    }
}

nonisolated struct ItemNarrationSettings: Codable, Equatable, Sendable {
    var voice: ItemVoiceSetting
    var speed: ItemSpeedSetting

    init(
        voice: ItemVoiceSetting = ItemVoiceSetting(),
        speed: ItemSpeedSetting = ItemSpeedSetting()
    ) {
        self.voice = voice
        self.speed = speed
    }
}

nonisolated struct ProjectContentBookmark: Codable, Equatable, Sendable {
    var contentRevision: String
    var textOffsetUTF16: Int
}

nonisolated struct ProjectAudioPosition: Codable, Equatable, Sendable {
    var generationKey: String
    var audioRevision: String
    var positionSeconds: Double
}

nonisolated struct ProjectPlaybackState: Codable, Equatable, Sendable {
    var currentItemID: UUID?
    var contentBookmark: ProjectContentBookmark?
    var audioPosition: ProjectAudioPosition?
    var projectProgress: Double
    var lastPlayedAt: Date?

    init(
        currentItemID: UUID? = nil,
        contentBookmark: ProjectContentBookmark? = nil,
        audioPosition: ProjectAudioPosition? = nil,
        projectProgress: Double = 0,
        lastPlayedAt: Date? = nil
    ) {
        self.currentItemID = currentItemID
        self.contentBookmark = contentBookmark
        self.audioPosition = audioPosition
        self.projectProgress = projectProgress
        self.lastPlayedAt = lastPlayedAt
    }
}

nonisolated struct ProjectDocument: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let id: UUID
    var title: String
    var author: String?
    var source: ProjectSource
    var artwork: ProjectArtwork?
    var settings: ProjectNarrationSettings
    /// Durable selection for this PDF; irrelevant for other source types.
    var pdfReadingPolicy: PdfReadingPolicy?
    var playback: ProjectPlaybackState?
    let createdAt: Date
    var updatedAt: Date

    init(
        schemaVersion: Int = ProjectSchema.currentVersion,
        id: UUID = UUID(),
        title: String,
        author: String? = nil,
        source: ProjectSource,
        artwork: ProjectArtwork? = nil,
        settings: ProjectNarrationSettings = ProjectNarrationSettings(),
        pdfReadingPolicy: PdfReadingPolicy? = nil,
        playback: ProjectPlaybackState? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.title = title
        self.author = author
        self.source = source
        self.artwork = artwork
        self.settings = settings
        self.pdfReadingPolicy = pdfReadingPolicy
        self.playback = playback
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

nonisolated struct ContentManifestItem: Codable, Equatable, Sendable {
    let id: UUID
    let order: Int
    let relativePath: String
    let parentID: UUID?

    init(
        id: UUID,
        order: Int,
        relativePath: String,
        parentID: UUID? = nil
    ) {
        self.id = id
        self.order = order
        self.relativePath = relativePath
        self.parentID = parentID
    }
}

nonisolated struct ProjectContentManifest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    var contentRevision: String
    var items: [ContentManifestItem]

    init(
        schemaVersion: Int = ProjectSchema.currentVersion,
        contentRevision: String,
        items: [ContentManifestItem]
    ) {
        self.schemaVersion = schemaVersion
        self.contentRevision = contentRevision
        self.items = items
    }

    static func empty() -> ProjectContentManifest {
        ProjectContentManifest(
            contentRevision: ProjectDigest.sha256("readaloud-content-v1\n"),
            items: []
        )
    }
}

nonisolated enum ProjectSourceLocatorKind: String, Codable, Sendable {
    case epub
    case pdf
    case document
    case paste
    case article
}

nonisolated struct ProjectSourceLocator: Codable, Equatable, Sendable {
    let kind: ProjectSourceLocatorKind
    let value: String
}

nonisolated struct ProjectContentItem: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let id: UUID
    var title: String
    let order: Int
    var text: String
    var contentRevision: String
    var sourceLocator: ProjectSourceLocator
    var settings: ItemNarrationSettings

    init(
        schemaVersion: Int = ProjectSchema.currentVersion,
        id: UUID = UUID(),
        title: String,
        order: Int,
        text: String,
        contentRevision: String,
        sourceLocator: ProjectSourceLocator,
        settings: ItemNarrationSettings = ItemNarrationSettings()
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.title = title
        self.order = order
        self.text = text
        self.contentRevision = contentRevision
        self.sourceLocator = sourceLocator
        self.settings = settings
    }
}

nonisolated struct GenerationKeyInput: Equatable, Sendable {
    let contentRevision: String
    let resolvedVoiceID: String
    let canonicalSpeed: Double
    let kokoroRuntimeRevision: String
    let synthesisConfigVersion: Int

    init(
        contentRevision: String,
        resolvedVoiceID: String,
        canonicalSpeed: Double,
        kokoroRuntimeRevision: String,
        synthesisConfigVersion: Int
    ) {
        self.contentRevision = contentRevision
        self.resolvedVoiceID = resolvedVoiceID
        self.canonicalSpeed = canonicalSpeed
        self.kokoroRuntimeRevision = kokoroRuntimeRevision
        self.synthesisConfigVersion = synthesisConfigVersion
    }
}

nonisolated enum GenerationJobOperation: String, Codable, Sendable {
    case generate
}

nonisolated enum GenerationJobState: String, Codable, Hashable, Sendable {
    case queued
    case generating
    case failed
    case completed
}

nonisolated struct GenerationJobRecord: Codable, Equatable, Sendable {
    let id: UUID
    let projectID: UUID
    let itemID: UUID
    let operation: GenerationJobOperation
    let generationKey: String
    var state: GenerationJobState
    let createdAt: Date
    var updatedAt: Date
    var attempt: Int
    var lastError: String?

    func recoveredForColdLaunch(at date: Date = .now) -> GenerationJobRecord {
        guard state == .generating else { return self }
        var copy = self
        copy.state = .queued
        copy.updatedAt = date
        return copy
    }
}

nonisolated struct ProjectQueueDocument: Codable, Equatable, Sendable {
    let schemaVersion: Int
    var jobs: [GenerationJobRecord]

    init(
        schemaVersion: Int = ProjectSchema.currentVersion,
        jobs: [GenerationJobRecord] = []
    ) {
        self.schemaVersion = schemaVersion
        self.jobs = jobs
    }
}

/// Lightweight summary of the real durable Kokoro generation jobs.
nonisolated struct ProjectGenerationQueueCounts: Equatable, Sendable {
    var queued = 0
    var generating = 0
    var failed = 0

    init() {}

    init(queue: ProjectQueueDocument, runtimeIsActive: Bool) {
        for job in queue.jobs {
            switch job.state {
            case .queued:
                queued += 1
            case .generating:
                // A project not loaded by the TTS runtime cannot still be
                // generating. The persisted in-flight job will be recovered.
                if runtimeIsActive {
                    generating += 1
                } else {
                    queued += 1
                }
            case .failed:
                failed += 1
            case .completed:
                break
            }
        }
    }

    mutating func add(_ other: Self) {
        queued += other.queued
        generating += other.generating
        failed += other.failed
    }
}

nonisolated struct AudioSourceRange: Codable, Equatable, Sendable {
    let startUTF16: Int
    let endUTF16: Int
}

nonisolated struct AudioSegmentMetadata: Codable, Equatable, Sendable {
    let sourceRange: AudioSourceRange
    let startSeconds: Double
    let endSeconds: Double
}

nonisolated struct GeneratedAudioFormat: Codable, Equatable, Sendable {
    let container: String
    let sampleRate: Int
    let channels: Int

    static let wav24kMono = GeneratedAudioFormat(
        container: "wav",
        sampleRate: 24_000,
        channels: 1
    )
}

nonisolated struct GeneratedAudioMetadata: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let itemID: UUID
    let generationKey: String
    let audioRevision: String
    let contentRevision: String
    let voiceID: String
    let speed: Double
    let runtimeRevision: String
    let synthesisConfigVersion: Int
    let format: GeneratedAudioFormat
    let durationSeconds: Double
    let segments: [AudioSegmentMetadata]
    let createdAt: Date

    init(
        schemaVersion: Int = ProjectSchema.currentVersion,
        itemID: UUID,
        generationKey: String,
        audioRevision: String,
        contentRevision: String,
        voiceID: String,
        speed: Double,
        runtimeRevision: String,
        synthesisConfigVersion: Int,
        format: GeneratedAudioFormat = .wav24kMono,
        durationSeconds: Double,
        segments: [AudioSegmentMetadata],
        createdAt: Date = .now
    ) {
        self.schemaVersion = schemaVersion
        self.itemID = itemID
        self.generationKey = generationKey
        self.audioRevision = audioRevision
        self.contentRevision = contentRevision
        self.voiceID = voiceID
        self.speed = speed
        self.runtimeRevision = runtimeRevision
        self.synthesisConfigVersion = synthesisConfigVersion
        self.format = format
        self.durationSeconds = durationSeconds
        self.segments = segments
        self.createdAt = createdAt
    }
}

nonisolated struct ProjectSnapshot: Equatable, Sendable {
    let id: UUID
    let title: String
    let author: String?
    let sourceType: ProjectSourceType
    let originalURL: URL?
    let siteName: String?
    let language: String?
    let publishedTime: String?
    let artworkRelativePath: String?
    let projectProgress: Double
    let lastPlayedAt: Date?
    let createdAt: Date
    let updatedAt: Date

    init(project: ProjectDocument) {
        id = project.id
        title = project.title
        author = project.author
        sourceType = project.source.type
        originalURL = project.source.originalURL
        siteName = project.source.siteName
        language = project.source.language
        publishedTime = project.source.publishedTime
        artworkRelativePath = project.artwork?.relativePath
        projectProgress = project.playback?.projectProgress ?? 0
        lastPlayedAt = project.playback?.lastPlayedAt
        createdAt = project.createdAt
        updatedAt = project.updatedAt
    }
}

nonisolated struct LoadedProject: Equatable, Sendable {
    let project: ProjectDocument
    let manifest: ProjectContentManifest
    let items: [ProjectContentItem]
    let queue: ProjectQueueDocument
}

nonisolated enum ProjectCatalogIssueKind: String, Sendable {
    case corrupt
    case unsupportedSchema
    case invalidPackage
    case unreadable
}

nonisolated struct ProjectCatalogIssue: Equatable, Sendable {
    let packageName: String
    let kind: ProjectCatalogIssueKind
    let message: String
}

nonisolated struct ProjectCatalog: Equatable, Sendable {
    let projects: [ProjectSnapshot]
    let issues: [ProjectCatalogIssue]
}
