import CoreMedia
import Foundation

/// Rational, non-negative media timestamp. Values are never stored as Double seconds.
public struct MediaTime: Codable, Comparable, Sendable {
    public let value: Int64
    public let timescale: Int32

    public static let zero = MediaTime(uncheckedValue: 0, timescale: 1)

    public init(value: Int64, timescale: Int32) throws {
        guard value >= 0, timescale > 0 else { throw MediaTimeError.invalidTimestamp }
        self.value = value
        self.timescale = timescale
    }

    public init(validating time: CMTime) throws {
        guard time.isNumeric, time.value >= 0, time.timescale > 0 else {
            throw MediaTimeError.invalidTimestamp
        }
        try self.init(value: time.value, timescale: time.timescale)
    }

    private init(uncheckedValue value: Int64, timescale: Int32) {
        self.value = value
        self.timescale = timescale
    }

    public var cmTime: CMTime { CMTime(value: value, timescale: timescale) }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        CMTimeCompare(lhs.cmTime, rhs.cmTime) == 0
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        CMTimeCompare(lhs.cmTime, rhs.cmTime) < 0
    }

    private enum CodingKeys: String, CodingKey { case value, timescale }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decode(Int64.self, forKey: .value)
        let timescale = try container.decode(Int32.self, forKey: .timescale)
        try self.init(value: value, timescale: timescale)
    }
}

public enum MediaTimeError: Error {
    case invalidTimestamp
    case invalidInterval
    case invalidClipMapping
}

/// All media intervals are half-open: [start, end).
public struct MediaInterval: Codable, Equatable, Sendable {
    public let start: MediaTime
    public let end: MediaTime

    public init(start: MediaTime, end: MediaTime) throws {
        guard start < end else { throw MediaTimeError.invalidInterval }
        self.start = start
        self.end = end
    }

    public func contains(_ time: MediaTime) -> Bool {
        start <= time && time < end
    }

    public var duration: CMTime {
        CMTimeSubtract(end.cmTime, start.cmTime)
    }

    private enum CodingKeys: String, CodingKey { case start, end }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            start: container.decode(MediaTime.self, forKey: .start),
            end: container.decode(MediaTime.self, forKey: .end)
        )
    }
}

/// Canonical clips have identity speed. V1 media edits derive retained output
/// without adding reverse, freeze frames or speed ramps.
public struct IdentityClipMapping: Codable, Equatable, Sendable {
    public let clipID: UUID
    public let sourceAssetID: UUID
    public let sourceInterval: MediaInterval
    public let timelineInterval: MediaInterval

    public init(
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

    public init(from decoder: Decoder) throws {
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
    public func sourceTime(at projectTime: MediaTime) -> MediaTime? {
        guard timelineInterval.contains(projectTime) else { return nil }
        let elapsed = CMTimeSubtract(projectTime.cmTime, timelineInterval.start.cmTime)
        return try? MediaTime(validating: CMTimeAdd(sourceInterval.start.cmTime, elapsed))
    }
}
