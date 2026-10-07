import Foundation

nonisolated struct ProjectStorageBreakdown:
    Identifiable,
    Equatable,
    Sendable
{
    let projectID: UUID
    let title: String
    let totalBytes: Int64
    let sourceBytes: Int64
    let generatedAudioBytes: Int64
    let temporaryCacheBytes: Int64
    let artworkBytes: Int64
    let workingBytes: Int64
    let projectDataBytes: Int64

    var id: UUID {
        projectID
    }
}

nonisolated struct ReadAloudStorageSummary:
    Equatable,
    Sendable
{
    let totalBytes: Int64
    let projects:
        [ProjectStorageBreakdown]
    let unattributedBytes: Int64

    static let empty =
        ReadAloudStorageSummary(
            totalBytes: 0,
            projects: [],
            unattributedBytes: 0
        )
}
