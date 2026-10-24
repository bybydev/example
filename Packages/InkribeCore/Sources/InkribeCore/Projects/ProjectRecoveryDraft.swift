import Foundation

/// A write-ahead editing draft, never a second canonical project or version history.
/// The proposal may contain an unfinished title; native semantic validation runs
/// before preview/commit. Its valid base retains the exact conflict boundary.
public struct ProjectRecoveryDraft<Document: ProjectPackageDocument>: Codable, Sendable {
    public let version: Int
    public let ownerID: UUID
    public let sequence: UInt64
    public let base: Document
    public let proposed: Document

    public init(ownerID: UUID, sequence: UInt64, base: Document, proposed: Document) {
        version = 1
        self.ownerID = ownerID
        self.sequence = sequence
        self.base = base
        self.proposed = proposed
    }
}
