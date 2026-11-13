import Foundation

/// Codable field names are the existing iOS JobQueue payload contract.
public struct TranscriptionRequest: Codable, Sendable {
    public let projectID: UUID
    public let expectedRevision: UInt64
    public let languageCode: String?
    public var modelID: String?
    public var requiresAllowance: Bool?
    public var windowIndices: [Int]?
    public var projectTitle: String?
    public var replacingRecognitionID: UUID?

    public init(projectID: UUID, expectedRevision: UInt64, languageCode: String?,
                modelID: String? = nil, requiresAllowance: Bool? = nil, windowIndices: [Int]? = nil,
                projectTitle: String? = nil, replacingRecognitionID: UUID? = nil) {
        self.projectID = projectID
        self.expectedRevision = expectedRevision
        self.languageCode = languageCode
        self.modelID = modelID
        self.requiresAllowance = requiresAllowance
        self.windowIndices = windowIndices
        self.projectTitle = projectTitle
        self.replacingRecognitionID = replacingRecognitionID
    }
}

public enum ExportFormat: String, Codable, CaseIterable, Sendable {
    case mp4, srt
}

public enum ExportResolution: Int, Codable, CaseIterable, Sendable {
    case hd = 720, fullHD = 1080
}

public enum ExportFrameRate: Int, Codable, CaseIterable, Hashable, Sendable {
    case fps24 = 24, fps25 = 25, fps30 = 30, fps60 = 60
}

public struct ExportProfile: Codable, Equatable, Sendable {
    public var format: ExportFormat
    public var resolution: ExportResolution
    public var frameRate: ExportFrameRate
    public init(format: ExportFormat = .mp4, resolution: ExportResolution = .hd,
                frameRate: ExportFrameRate = .fps30) {
        self.format = format
        self.resolution = resolution
        self.frameRate = frameRate
    }

    private enum CodingKeys: String, CodingKey {
        case format, resolution, frameRate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decode(ExportFormat.self, forKey: .format)
        resolution = try container.decode(ExportResolution.self, forKey: .resolution)
        frameRate = try container.decodeIfPresent(ExportFrameRate.self, forKey: .frameRate) ?? .fps30
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(format, forKey: .format)
        try container.encode(resolution, forKey: .resolution)
        try container.encode(frameRate, forKey: .frameRate)
    }
}

public struct ExportRequest: Codable, Sendable {
    public let projectID: UUID
    public let profile: ExportProfile
    public init(projectID: UUID, profile: ExportProfile) {
        self.projectID = projectID
        self.profile = profile
    }
}

/// Independent from the queue files; JobQueue 1.0 does not persist user pause.
public struct ProcessingControlState: Codable, Sendable {
    public let version: Int
    public var userPaused: Bool
    public init(userPaused: Bool = false) {
        version = 1
        self.userPaused = userPaused
    }
}
