import CoreMedia
import Foundation

struct IOSCaptionMotionState {
    var opacity: Double = 1
    var scale: Double = 1
    var highlighted: Set<UUID> = []
    var karaoke: [UUID: Double] = [:]
}

/// Content motion is a pure function of the saved style and actual edited word
/// intervals. No implicit SwiftUI animations or display/wall-clock timers.
enum IOSCaptionMotion {
    static func evaluate(_ presentation: IOSCaptionPresentation, style: IOSCaptionStyle,
                         at time: MediaTime) -> IOSCaptionMotionState {
        var state = IOSCaptionMotionState()
        let words = presentation.words.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let seconds = IOSEditorTime.seconds(time)
        switch style.effect {
        case .none: break
        case .highlight:
            state.highlighted = presentation.activeWordIDs
        case .karaoke:
            for word in words {
                let start = IOSEditorTime.seconds(word.projectInterval.start)
                let duration = CMTimeGetSeconds(word.projectInterval.duration)
                state.karaoke[word.id] = min(1, max(0, (seconds - start) / duration))
            }
        case .pop:
            if let word = words.filter({ $0.projectInterval.start <= time })
                .max(by: { $0.projectInterval.start < $1.projectInterval.start }) {
                let duration = min(0.18, CMTimeGetSeconds(word.projectInterval.duration))
                let phase = (seconds - IOSEditorTime.seconds(word.projectInterval.start)) / duration
                if phase >= 0, phase < 1 { state.scale = 1 + 0.12 * sin(.pi * phase) }
            }
        case .fade:
            if let first = words.map(\.projectInterval.start).min(), let last = words.map(\.projectInterval.end).max() {
                let start = IOSEditorTime.seconds(first)
                let end = IOSEditorTime.seconds(last)
                let ramp = min(0.2, max(0.000_001, (end - start) / 3))
                state.opacity = min(1, max(0, min((seconds - start) / ramp, (end - seconds) / ramp)))
            }
        }
        return state
    }
}
