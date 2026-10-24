import Foundation

/// Format identity is independent of the editable document schema. Existing
/// document bytes and asset-relative paths survive adoption into a package.
public enum ProjectPackageLayout {
    public static let packageExtension = "inkribe"
    public static let formatVersion = 1
    public static let manifestName = "package.json"
    public static let documentName = "document.json"
    public static let previousDocumentName = "document.previous.json"
    public static let originalsName = "Originals"
    public static let checkpointName = "speech-checkpoint.json"
    public static let recoveryDraftName = "editor-draft.json"

    public static func name(for id: UUID) -> String {
        id.uuidString + "." + packageExtension
    }

    public static func identity(of url: URL) -> UUID? {
        if url.pathExtension.lowercased() == packageExtension {
            return UUID(uuidString: url.deletingPathExtension().lastPathComponent)
        }
        return UUID(uuidString: url.lastPathComponent)
    }
}

public struct ProjectPackageIdentity: Equatable, Sendable {
    public let id: UUID
    public let schemaVersion: Int
    public let revision: UInt64

    public init(id: UUID, schemaVersion: Int, revision: UInt64) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.revision = revision
    }
}

public struct ProjectPackageSource: Equatable, Sendable {
    public let relativePath: String
    public let byteCount: Int64

    public init(relativePath: String, byteCount: Int64) {
        self.relativePath = relativePath
        self.byteCount = byteCount
    }
}

/// Native app validation owns recognition/runtime semantics. The shared store
/// owns package identity, filesystem transactions and version-safe JSON reads.
public protocol ProjectPackageDocument: Codable, Sendable {
    static var supportedPackageDocumentSchema: Int { get }
    var packageIdentity: ProjectPackageIdentity { get }
    var packageSources: [ProjectPackageSource] { get }
    func validatePackageDocument() throws
}

public enum ProjectPackageLocation: String, Equatable, Sendable {
    case projects = "Projects"
    case trash = "Trash"
}

public struct ProjectPackageManifest: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let projectID: UUID

    public init(projectID: UUID) {
        self.formatVersion = ProjectPackageLayout.formatVersion
        self.projectID = projectID
    }
}

public struct ProjectPackageStorage: Sendable {
    public let sources: Int64
    public let durableData: Int64
    public let derivedCache: Int64
    public let temporaryWork: Int64
    public var total: Int64 { sources + durableData + derivedCache + temporaryWork }

    public init(sources: Int64, durableData: Int64, derivedCache: Int64, temporaryWork: Int64) {
        self.sources = sources
        self.durableData = durableData
        self.derivedCache = derivedCache
        self.temporaryWork = temporaryWork
    }
}
