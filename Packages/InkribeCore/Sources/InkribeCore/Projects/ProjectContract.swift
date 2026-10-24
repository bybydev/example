import Foundation

/// Document schema and transaction identity are independent of native UI state.
public enum ProjectSchemaContract {
    public static let initialVersion = 1
}

public struct ProjectRevision: Codable, Equatable, Sendable {
    public let projectID: UUID
    public let contentRevision: UInt64

    public init(projectID: UUID, contentRevision: UInt64) {
        self.projectID = projectID
        self.contentRevision = contentRevision
    }
}

/// An editor operation is checked against a revision before it may mutate a document.
/// This is not an editor implementation or a persistent queue entry.
public struct ProjectEditToken: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let expected: ProjectRevision

    public init(operationID: UUID, expected: ProjectRevision) {
        self.operationID = operationID
        self.expected = expected
    }
}

public enum ProjectEditConflict: Error {
    case staleRevision(expected: ProjectRevision, actual: ProjectRevision)
    case differentProject
    case revisionOverflow
}

public protocol ProjectEditApplying: Sendable {
    /// Commits durable state before reporting success; never applies stale work implicitly.
    func apply(_ operation: ProjectEditToken) async throws -> ProjectRevision
}
