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

public struct TranscriptSegment: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var text: String

    public init(id: UUID = UUID(), startTime: TimeInterval, endTime: TimeInterval, text: String) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
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
        self.derivedDocuments = derivedDocuments
    }
}
