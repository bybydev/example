import CoreMedia
import Foundation

struct IOSCaptionAllowance: Sendable {
    let used: Int
    let reserved: Int
    let resetsAt: Date
    var remaining: Int { max(0, IOSCommerce.weeklySeconds - used - reserved) }
    var summary: String { "\(used / 60)m \(used % 60)s of 5 min used this week" }
}

/// Owned exclusively by IOSProjectRepository. Reservations protect queued work;
/// only a recognition published in the document becomes charged usage.
struct IOSCaptionAllowanceLedger: Codable, Equatable {
    struct Reservation: Codable, Equatable {
        let jobID: UUID
        let projectID: UUID
        let revision: UInt64
        let weekStart: Date
        let seconds: Int
    }
    var version = 1
    var weekStart: Date
    var used = 0
    var charged: Set<UUID> = []
    var reservations: [Reservation] = []

    static func week(containing date: Date) -> Date {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.dateInterval(of: .weekOfYear, for: date)!.start
    }

    mutating func advance(at now: Date) {
        let start = Self.week(containing: now)
        guard start > weekStart else { return }
        weekStart = start; used = 0; charged.removeAll()
        // Previously authorized work remains valid across a weekly reset.
    }

    var snapshot: IOSCaptionAllowance {
        .init(used: used,
            reserved: reservations.filter { $0.weekStart == weekStart }.reduce(0) { $0 + $1.seconds },
            resetsAt: weekStart.addingTimeInterval(7 * 24 * 60 * 60))
    }

    mutating func finish(_ id: UUID) {
        guard let reservation = reservations.first(where: { $0.jobID == id }) else { return }
        if reservation.weekStart == weekStart, !charged.contains(id) {
            used += reservation.seconds
            charged.insert(id)
        }
        reservations.removeAll { $0.jobID == id }
    }

    func validate() throws {
        guard version == 1, weekStart.timeIntervalSince1970.isFinite,
              weekStart == Self.week(containing: weekStart), (0...IOSCommerce.weeklySeconds).contains(used),
              charged.count <= IOSCommerce.weeklySeconds,
              Set(reservations.map(\.jobID)).count == reservations.count,
              reservations.allSatisfy({ (1...IOSCommerce.weeklySeconds).contains($0.seconds)
                  && $0.revision > 0 && !charged.contains($0.jobID)
                  && $0.weekStart.timeIntervalSince1970.isFinite
                  && $0.weekStart == Self.week(containing: $0.weekStart) && $0.weekStart <= weekStart }),
              snapshot.reserved <= IOSCommerce.weeklySeconds - used else { throw IOSProError.allowanceStorage }
    }

    static func seconds(for document: IOSProjectDocument) throws -> Int {
        let audio = Set(document.assets.filter { $0.metadata.audioTrackCount > 0 }.map(\.id))
        let duration = document.clips.filter { audio.contains($0.sourceAssetID) }
            .reduce(0.0) { $0 + CMTimeGetSeconds($1.sourceInterval.duration) }
        guard duration.isFinite, duration > 0 else { throw IOSSpeechError.noAudio }
        guard duration <= Double(IOSCommerce.weeklySeconds) else { throw IOSProError.requiresPro(.captioning) }
        return max(1, Int(ceil(duration)))
    }
}
