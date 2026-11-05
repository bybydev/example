import Foundation
import InkribeCore

/// Adapts iOS edited recognition into the shared, deterministic motion kernel.
enum CaptionMotion {
    static func isWordTimed(_ unit: CaptionUnit) -> Bool {
        (unit.timingProvenance == "whisper-token-union" || unit.timingProvenance == "authored-style-demo") &&
            CaptionTextMapping.isSingleWord(unit.text)
    }

    static func evaluate(_ presentation: CaptionPresentation, style: CaptionStyle,
                         at time: MediaTime, requireWordTiming: Bool = true,
                         wordTimedIDs: Set<UUID>? = nil) -> CaptionMotionState {
        let units = presentation.words.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map {
            CaptionMotionUnit(id: $0.id, interval: $0.projectInterval,
                isWordTimed: requireWordTiming ? (wordTimedIDs?.contains($0.id) ?? isWordTimed($0)) :
                    $0.timingProvenance == "whisper-token-union")
        }
        return CaptionMotionEvaluator.evaluate(units, active: presentation.activeWordIDs,
            style: style, at: time, requireWordTiming: requireWordTiming)
    }
}
