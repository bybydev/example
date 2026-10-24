import Foundation
import InkribeCore

/// Adapts iOS edited recognition into the shared, deterministic motion kernel.
enum CaptionMotion {
    static func evaluate(_ presentation: CaptionPresentation, style: CaptionStyle,
                         at time: MediaTime) -> CaptionMotionState {
        let units = presentation.words.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map {
            CaptionMotionUnit(id: $0.id, interval: $0.projectInterval,
                isWordTimed: $0.timingProvenance == "whisper-token-union")
        }
        return CaptionMotionEvaluator.evaluate(units, active: presentation.activeWordIDs, style: style, at: time)
    }
}
