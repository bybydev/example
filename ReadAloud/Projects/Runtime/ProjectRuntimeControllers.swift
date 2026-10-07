import Foundation
import Observation

@Observable
@MainActor
final class ProjectQueueController {
    private(set) var queue = ProjectQueueDocument()

    var waitingCount: Int {
        queue.jobs.filter { $0.state == .queued }.count
    }

    var generatingCount: Int {
        queue.jobs.filter { $0.state == .generating }.count
    }

    var failedCount: Int {
        queue.jobs.filter { $0.state == .failed }.count
    }

    var hasExecutingWork: Bool {
        generatingCount > 0
    }

    func publish(_ queue: ProjectQueueDocument) {
        self.queue = queue
    }
}

nonisolated struct ProjectCacheCoordinator: Sendable {
    let packageURL: URL

    var paragraphCacheDirectory: URL {
        ProjectPackagePaths(
            packageURL: packageURL
        ).paragraphCacheDirectory
    }

    var artworkCacheDirectory: URL {
        ProjectPackagePaths(
            packageURL: packageURL
        ).artworkCacheDirectory
    }

    var audioDirectory: URL {
        ProjectPackagePaths(
            packageURL: packageURL
        ).audioDirectory
    }

    var temporaryDirectory: URL {
        ProjectPackagePaths(
            packageURL: packageURL
        ).tempDirectory
    }
}
