import CoreMedia
import Foundation

struct CaptionAllowance: Sendable {
    let used: Int
    let reserved: Int
    let resetsAt: Date
    var remaining: Int { max(0, Commerce.weeklyVideoLimit - used - reserved) }
    var summary: String { "\(used) of \(Commerce.weeklyVideoLimit) free videos used this week" }
    var remainingDescription: String {
        switch remaining {
        case 0: "No free videos left this week"
        case 1: "1 free video left this week"
        default: "\(remaining) free videos left this week"
        }
    }
}

/// Owned exclusively by ProjectRepository. Reservations protect queued work;
/// only a complete recognition published in the document becomes counted usage.
struct CaptionAllowanceLedger: Codable, Equatable {
    struct CountedVideo: Codable, Equatable {
        let projectID: UUID
        let recognitionID: UUID
        let weekStart: Date
    }
    struct Reservation: Codable, Equatable {
        let jobID: UUID
        let projectID: UUID
        let revision: UInt64
        let weekStart: Date
    }
    static let currentVersion = 2
    var version = CaptionAllowanceLedger.currentVersion
    var weekStart: Date
    var countedVideos: [CountedVideo] = []
    var reservations: [Reservation] = []

    static func week(containing date: Date) -> Date {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.dateInterval(of: .weekOfYear, for: date)!.start
    }

    mutating func advance(at now: Date) {
        let start = Self.week(containing: now)
        guard start > weekStart else { return }
        weekStart = start
        // Counted videos are retained so retranscribing a project never charges
        // again. Weekly usage is derived from each entry's original week.
    }

    var snapshot: CaptionAllowance {
        let countedProjects = Set(countedVideos.map(\.projectID))
        let reserved = Set(reservations.filter {
            $0.weekStart == weekStart && !countedProjects.contains($0.projectID)
        }.map(\.projectID)).count
        return .init(used: countedVideos.filter { $0.weekStart == weekStart }.count,
            reserved: reserved,
            resetsAt: weekStart.addingTimeInterval(7 * 24 * 60 * 60))
    }

    mutating func finish(_ id: UUID) {
        guard let reservation = reservations.first(where: { $0.jobID == id }) else { return }
        if !countedVideos.contains(where: { $0.projectID == reservation.projectID }) {
            countedVideos.append(.init(projectID: reservation.projectID,
                recognitionID: reservation.jobID, weekStart: reservation.weekStart))
        }
        reservations.removeAll { $0.jobID == id }
    }

    func validate() throws {
        let used = countedVideos.filter { $0.weekStart == weekStart }.count
        guard version == Self.currentVersion, weekStart.timeIntervalSince1970.isFinite,
              weekStart == Self.week(containing: weekStart),
              Set(countedVideos.map(\.projectID)).count == countedVideos.count,
              Set(countedVideos.map(\.recognitionID)).count == countedVideos.count,
              countedVideos.allSatisfy({ $0.weekStart.timeIntervalSince1970.isFinite
                  && $0.weekStart == Self.week(containing: $0.weekStart)
                  && $0.weekStart <= weekStart }),
              used <= Commerce.weeklyVideoLimit,
              Set(reservations.map(\.jobID)).count == reservations.count,
              reservations.allSatisfy({ $0.revision > 0
                  && $0.weekStart.timeIntervalSince1970.isFinite
                  && $0.weekStart == Self.week(containing: $0.weekStart)
                  && $0.weekStart <= weekStart }),
              snapshot.reserved <= Commerce.weeklyVideoLimit - used else { throw ProError.allowanceStorage }
    }

    /// Free videos must be strictly shorter than the documented maximum.
    static func requireFreeEligibility(_ document: ProjectDocument) throws {
        let plan = try SpeechCheckpoint.plan(clips: document.clips, assets: document.assets)
        let duration = plan.reduce(0.0) { $0 + CMTimeGetSeconds($1.core.duration) }
        guard duration.isFinite, duration > 0 else { throw SpeechError.noAudio }
        guard duration < Double(Commerce.maximumFreeVideoSeconds) else {
            throw ProError.requiresPro(.captioning)
        }
    }
}
