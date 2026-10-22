import Foundation

/// Metadata/transaction boundary only; P1 owns the first persisted project schema.
enum ProjectSchemaContract {
    static let initialVersion = 1
}

struct ProjectRevision: Codable, Equatable, Sendable {
    let projectID: UUID
    let contentRevision: UInt64
}

/// An editor operation is checked against a revision before it may mutate a document.
/// This is not an editor implementation or a persistent queue entry.
struct ProjectEditToken: Codable, Equatable, Sendable {
    let operationID: UUID
    let expected: ProjectRevision
}

enum ProjectEditConflict: Error {
    case staleRevision(expected: ProjectRevision, actual: ProjectRevision)
    case differentProject
    case revisionOverflow
}

protocol ProjectEditApplying: Sendable {
    /// Commits durable state before reporting success; never applies stale work implicitly.
    func apply(_ operation: ProjectEditToken) async throws -> ProjectRevision
}

/// P1 will own the single repository. P3 will implement editor session and inverse commands.
/// Playback, selection and scroll positions are ephemeral and never bump contentRevision.
