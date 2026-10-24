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

    public init(projectID: UUID, expectedRevision: UInt64, languageCode: String?,
                modelID: String? = nil, requiresAllowance: Bool? = nil, windowIndices: [Int]? = nil, projectTitle: String? = nil) {
        self.projectID = projectID
        self.expectedRevision = expectedRevision
        self.languageCode = languageCode
        self.modelID = modelID
        self.requiresAllowance = requiresAllowance
        self.windowIndices = windowIndices
        self.projectTitle = projectTitle
    }
}

public enum ExportFormat: String, Codable, CaseIterable, Sendable {
    case mp4, srt
}

public enum ExportResolution: Int, Codable, CaseIterable, Sendable {
    case hd = 720, fullHD = 1080
}

public struct ExportProfile: Codable, Equatable, Sendable {
    public var format: ExportFormat
    public var resolution: ExportResolution
    public init(format: ExportFormat = .mp4, resolution: ExportResolution = .hd) {
        self.format = format
        self.resolution = resolution
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
