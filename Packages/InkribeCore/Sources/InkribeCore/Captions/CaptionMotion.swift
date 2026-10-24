import CoreMedia
import Foundation

public struct CaptionMotionUnit: Sendable {
    public let id: UUID
    public let interval: MediaInterval
    public let isWordTimed: Bool
    public init(id: UUID, interval: MediaInterval, isWordTimed: Bool) {
        self.id = id; self.interval = interval; self.isWordTimed = isWordTimed
    }
}

public struct CaptionMotionState: Sendable {
    public var opacity: Double = 1
    public var scale: Double = 1
    public var verticalOffset: Double = 0
    public var highlighted: Set<UUID> = []
    public var emphasized: Set<UUID> = []
    public var underlined: Set<UUID> = []
    public var karaoke: [UUID: Double] = [:]
    public init() {}
}

/// Actual edited intervals on the original clock. No word subdivision, wall
/// clock or UI animation. Version 1 motion remains frozen for legacy projects.
public enum CaptionMotionEvaluator {
    public static func evaluate(_ units: [CaptionMotionUnit], active: Set<UUID>,
                                style: CaptionStyle, at time: MediaTime) -> CaptionMotionState {
        var state = CaptionMotionState()
        let seconds = CMTimeGetSeconds(time.cmTime)
        switch style.effect {
        case .none: break
        case .highlight: state.highlighted = active
        case .emphasis: state.emphasized = active
        case .underline: state.underlined = active
        case .karaoke:
            for unit in units {
                if style.formatVersion >= 2 && !unit.isWordTimed {
                    // A phrase can be emphasized as one unit, never swept as
                    // though independently timed words had been recognized.
                    if active.contains(unit.id) { state.emphasized.insert(unit.id) }
                    continue
                }
                let start = CMTimeGetSeconds(unit.interval.start.cmTime)
                let duration = CMTimeGetSeconds(unit.interval.duration)
                guard duration.isFinite, duration > 0 else { continue }
                state.karaoke[unit.id] = min(1, max(0, (seconds - start) / duration))
            }
        case .pop:
            if let unit = units.filter({ $0.interval.start <= time }).max(by: { $0.interval.start < $1.interval.start }) {
                let duration = min(0.18, CMTimeGetSeconds(unit.interval.duration))
                guard duration > 0 else { return state }
                let phase = (seconds - CMTimeGetSeconds(unit.interval.start.cmTime)) / duration
                if phase >= 0, phase < 1 { state.scale = 1 + 0.12 * sin(.pi * phase) }
            }
        case .fade, .rise:
            if let first = units.map(\.interval.start).min(), let last = units.map(\.interval.end).max() {
                let start = CMTimeGetSeconds(first.cmTime), end = CMTimeGetSeconds(last.cmTime)
                let ramp = min(0.2, max(0.000_001, (end - start) / 3))
                let entering = min(1, max(0, (seconds - start) / ramp))
                state.opacity = min(entering, max(0, min(1, (end - seconds) / ramp)))
                if style.effect == .rise { state.verticalOffset = -0.3 * (1 - entering) }
            }
        }
        return state
    }
}
