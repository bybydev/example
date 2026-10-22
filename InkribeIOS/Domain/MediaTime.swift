import CoreMedia
import Foundation

/// Rational, non-negative media timestamp. Values are never stored as Double seconds.
struct MediaTime: Codable, Comparable, Sendable {
    let value: Int64
    let timescale: Int32

    static let zero = MediaTime(uncheckedValue: 0, timescale: 1)

    init(value: Int64, timescale: Int32) throws {
        guard value >= 0, timescale > 0 else { throw MediaTimeError.invalidTimestamp }
        self.value = value
        self.timescale = timescale
    }

    init(validating time: CMTime) throws {
        guard time.isNumeric, time.value >= 0, time.timescale > 0 else {
            throw MediaTimeError.invalidTimestamp
        }
        try self.init(value: time.value, timescale: time.timescale)
    }

    private init(uncheckedValue value: Int64, timescale: Int32) {
        self.value = value
        self.timescale = timescale
    }

    var cmTime: CMTime { CMTime(value: value, timescale: timescale) }

    static func == (lhs: Self, rhs: Self) -> Bool {
        CMTimeCompare(lhs.cmTime, rhs.cmTime) == 0
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        CMTimeCompare(lhs.cmTime, rhs.cmTime) < 0
    }

    private enum CodingKeys: String, CodingKey { case value, timescale }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decode(Int64.self, forKey: .value)
        let timescale = try container.decode(Int32.self, forKey: .timescale)
        try self.init(value: value, timescale: timescale)
    }
}

enum MediaTimeError: Error {
    case invalidTimestamp
    case invalidInterval
    case invalidClipMapping
}

/// All media intervals are half-open: [start, end).
struct MediaInterval: Codable, Equatable, Sendable {
    let start: MediaTime
    let end: MediaTime

    init(start: MediaTime, end: MediaTime) throws {
        guard start < end else { throw MediaTimeError.invalidInterval }
        self.start = start
        self.end = end
    }

    func contains(_ time: MediaTime) -> Bool {
        start <= time && time < end
    }

    var duration: CMTime {
        CMTimeSubtract(end.cmTime, start.cmTime)
    }

    private enum CodingKeys: String, CodingKey { case start, end }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            start: container.decode(MediaTime.self, forKey: .start),
            end: container.decode(MediaTime.self, forKey: .end)
        )
    }
}

/// P0 supports one identity-speed clip. P6 owns reverse, freeze and speed ramps.
struct IdentityClipMapping: Codable, Equatable, Sendable {
    let clipID: UUID
    let sourceAssetID: UUID
    let sourceInterval: MediaInterval
    let timelineInterval: MediaInterval

    init(
        clipID: UUID = UUID(),
        sourceAssetID: UUID,
        sourceInterval: MediaInterval,
        timelineStart: MediaTime
    ) throws {
        let end = CMTimeAdd(timelineStart.cmTime, sourceInterval.duration)
        let timelineEnd = try MediaTime(validating: end)
        self.clipID = clipID
        self.sourceAssetID = sourceAssetID
        self.sourceInterval = sourceInterval
        self.timelineInterval = try MediaInterval(start: timelineStart, end: timelineEnd)
    }

    private enum CodingKeys: String, CodingKey {
        case clipID, sourceAssetID, sourceInterval, timelineInterval
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let interval = try container.decode(MediaInterval.self, forKey: .sourceInterval)
        let timeline = try container.decode(MediaInterval.self, forKey: .timelineInterval)
        try self.init(
            clipID: container.decode(UUID.self, forKey: .clipID),
            sourceAssetID: container.decode(UUID.self, forKey: .sourceAssetID),
            sourceInterval: interval,
            timelineStart: timeline.start
        )
        guard self.timelineInterval == timeline else {
            throw MediaTimeError.invalidClipMapping
        }
    }

    /// Caller must supply the decoded source frame for this exact source timestamp.
    func sourceTime(at projectTime: MediaTime) -> MediaTime? {
        guard timelineInterval.contains(projectTime) else { return nil }
        let elapsed = CMTimeSubtract(projectTime.cmTime, timelineInterval.start.cmTime)
        return try? MediaTime(validating: CMTimeAdd(sourceInterval.start.cmTime, elapsed))
    }
}
