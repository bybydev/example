import Foundation

public struct TranscriptID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        self.rawValue = UUID()
    }
}

public enum TranscriptLanguage: Codable, Equatable, Hashable, Sendable {
    case automatic
    case languageCode(String)
}

public struct TranscriptSpeaker: Identifiable, Codable, Equatable, Sendable {
    public let id: Int
    public var name: String

    public init(id: Int, name: String? = nil) {
        let normalizedID = max(0, id)
        let normalizedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.id = normalizedID
        self.name = normalizedName.isEmpty ? "Speaker \(normalizedID + 1)" : normalizedName
    }
}

public struct TranscriptSegment: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var text: String
    public var speakerID: Int?

    public init(
        id: UUID = UUID(),
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String,
        speakerID: Int? = nil
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.speakerID = speakerID
    }
}

public enum DerivedDocumentKind: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case summary
    case notes
    case actionItems
    case cleanedCopy
    case polishedCopy
}

public struct DerivedDocument: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let kind: DerivedDocumentKind
    public var content: String
    public let createdAt: Date
    public let sourceRevision: Int

    public init(
        id: UUID = UUID(),
        kind: DerivedDocumentKind,
        content: String,
        createdAt: Date = .now,
        sourceRevision: Int
    ) {
        self.id = id
        self.kind = kind
        self.content = content
        self.createdAt = createdAt
        self.sourceRevision = sourceRevision
    }
}

public struct Transcript: Identifiable, Codable, Equatable, Sendable {
    public var id: TranscriptID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var sourceMediaRelativePath: String?
    public var languageCode: String?
    public var duration: TimeInterval
    public var rawText: String
    public var editedText: String
    public var revision: Int
    public var segments: [TranscriptSegment]
    public var speakers: [TranscriptSpeaker]
    public var derivedDocuments: [DerivedDocument]

    public init(
        id: TranscriptID = TranscriptID(),
        title: String,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        sourceMediaRelativePath: String? = nil,
        languageCode: String? = nil,
        duration: TimeInterval = 0,
        rawText: String = "",
        editedText: String = "",
        revision: Int = 0,
        segments: [TranscriptSegment] = [],
        speakers: [TranscriptSpeaker] = [],
        derivedDocuments: [DerivedDocument] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sourceMediaRelativePath = sourceMediaRelativePath
        self.languageCode = languageCode
        self.duration = duration
        self.rawText = rawText
        self.editedText = editedText
        self.revision = revision
        self.segments = segments
        self.speakers = speakers
        self.derivedDocuments = derivedDocuments
    }

    public func speakerName(for speakerID: Int) -> String {
        speakers.first(where: { $0.id == speakerID })?.name
            ?? "Speaker \(speakerID + 1)"
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case createdAt
        case updatedAt
        case sourceMediaRelativePath
        case languageCode
        case duration
        case rawText
        case editedText
        case revision
        case segments
        case speakers
        case derivedDocuments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(TranscriptID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        sourceMediaRelativePath = try container.decodeIfPresent(
            String.self,
            forKey: .sourceMediaRelativePath
        )
        languageCode = try container.decodeIfPresent(String.self, forKey: .languageCode)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        rawText = try container.decode(String.self, forKey: .rawText)
        editedText = try container.decode(String.self, forKey: .editedText)
        revision = try container.decode(Int.self, forKey: .revision)
        segments = try container.decodeIfPresent(
            [TranscriptSegment].self,
            forKey: .segments
        ) ?? []
        speakers = try container.decodeIfPresent(
            [TranscriptSpeaker].self,
            forKey: .speakers
        ) ?? []
        derivedDocuments = try container.decodeIfPresent(
            [DerivedDocument].self,
            forKey: .derivedDocuments
        ) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(sourceMediaRelativePath, forKey: .sourceMediaRelativePath)
        try container.encodeIfPresent(languageCode, forKey: .languageCode)
        try container.encode(duration, forKey: .duration)
        try container.encode(rawText, forKey: .rawText)
        try container.encode(editedText, forKey: .editedText)
        try container.encode(revision, forKey: .revision)
        try container.encode(segments, forKey: .segments)
        try container.encode(speakers, forKey: .speakers)
        try container.encode(derivedDocuments, forKey: .derivedDocuments)
    }
}
