import CoreMedia
import Foundation
import XCTest
@testable import InkribeCore

/// Regression source for issue #63. Not executed under the source-only rules.
final class CaptionWordEffectTests: XCTestCase {
    func testWordReplacementsKeepSeparateExistingSlots() {
        let units = units(["One ", "two ", "three"])
        let result = CaptionTextMapping.correctedText("Red green blue", units: units)
        XCTAssertEqual(texts(result, units), ["Red ", "green ", "blue"])
    }

    func testUnchangedInteriorWordsKeepTheirSlot() {
        let units = units(["A ", "cat ", "sleeps."])
        let result = CaptionTextMapping.correctedText("The cat rests.", units: units)
        XCTAssertEqual(texts(result, units), ["The ", "cat ", "rests."])
    }

    func testInsertedWordsShareASlotWithoutClaimingWordTiming() {
        let units = units(["Hello ", "world."])
        let result = CaptionTextMapping.correctedText("Hello brave world.", units: units)
        XCTAssertEqual(texts(result, units), ["Hello ", "brave world."])
        XCTAssertTrue(CaptionTextMapping.isSingleWord(result[units[0].id] ?? ""))
        XCTAssertFalse(CaptionTextMapping.isSingleWord(result[units[1].id] ?? ""))
    }

    func testDeletedWordsClearTheirSlotWithoutMovingSurvivingWords() {
        let units = units(["One ", "two ", "three"])
        let result = CaptionTextMapping.correctedText("One three", units: units)
        XCTAssertEqual(texts(result, units), ["One ", "", "three"])
    }

    func testTypingUsesTheOriginalSlotsAfterIntermediateClearsAndPartialText() {
        let original = units(["One ", "two ", "three"])
        for intermediate in ["", "R", "Red", "Red green"] {
            let result = CaptionTextMapping.correctedText(intermediate, units: original)
            XCTAssertEqual(texts(result, original).joined().trimmingCharacters(in: .whitespacesAndNewlines), intermediate)
        }
        let final = CaptionTextMapping.correctedText("Red green blue", units: original)
        XCTAssertEqual(texts(final, original), ["Red ", "green ", "blue"])
    }

    func testTrimmedScopeNeverProducesHiddenWordIDs() {
        let hidden = UUID()
        let visible = units(["two ", "three"])
        let result = CaptionTextMapping.correctedText("two THREE", units: visible)
        XCTAssertEqual(texts(result, visible), ["two ", "THREE"])
        XCTAssertEqual(Set(result.keys), Set(visible.map(\.id)))
        XCTAssertNil(result[hidden])
    }

    func testPhraseCorrectionKeepsOneExistingUnit() {
        let units = units(["Hello world."])
        let result = CaptionTextMapping.correctedText("Goodbye world.", units: units)
        XCTAssertEqual(texts(result, units), ["Goodbye world."])
        XCTAssertFalse(CaptionTextMapping.isSingleWord(result[units[0].id] ?? ""))
    }

    func testWhitespacePunctuationAndUnicodeRemainIntact() {
        let units = units([" Hello, ", "world! "])
        let result = CaptionTextMapping.correctedText("Hi, friend!", units: units)
        XCTAssertEqual(texts(result, units), [" Hi, ", "friend! "])
        for value in ["Xin chào thế giới!", "你好，世界！", "A café ☕️ is open.", "go go now"] {
            let original = self.units([value])
            let mapped = CaptionTextMapping.correctedText(value, units: original)
            XCTAssertEqual(texts(mapped, original).joined(), value)
        }
        XCTAssertTrue(CaptionTextMapping.isSingleWord("Hello!"))
        XCTAssertFalse(CaptionTextMapping.isSingleWord("Hello everyone!"))
        XCTAssertFalse(CaptionTextMapping.isSingleWord(""))
    }

    func testWordOnlyHighlightColorAndUnderlineIgnorePhraseAndUnknownIDs() throws {
        let precise = UUID(), phrase = UUID(), unknown = UUID()
        let interval = try interval()
        let units = [CaptionMotionUnit(id: precise, interval: interval, isWordTimed: true),
                     CaptionMotionUnit(id: phrase, interval: interval, isWordTimed: false)]
        for effect in [CaptionEffect.highlight, .emphasis, .underline] {
            var style = CaptionStyle.standard
            style.effect = effect
            let state = CaptionMotionEvaluator.evaluate(units, active: [precise, phrase, unknown],
                style: style, at: try time(1), requireWordTiming: true)
            let affected: Set<UUID>
            switch effect {
            case .highlight: affected = state.highlighted
            case .emphasis: affected = state.emphasized
            default: affected = state.underlined
            }
            XCTAssertEqual(affected, [precise])
        }
    }

    func testKaraokeSweepsOnlyTimedWordsWithoutPhraseEmphasis() throws {
        let precise = UUID(), phrase = UUID()
        let interval = try interval()
        let units = [CaptionMotionUnit(id: precise, interval: interval, isWordTimed: true),
                     CaptionMotionUnit(id: phrase, interval: interval, isWordTimed: false)]
        for format in [1, 2] {
            var style = CaptionTemplate.karaoke.style
            style.formatVersion = format
            let state = CaptionMotionEvaluator.evaluate(units, active: [precise, phrase],
                style: style, at: try time(1), requireWordTiming: true)
            XCTAssertEqual(state.karaoke[precise], 0.5)
            XCTAssertNil(state.karaoke[phrase])
            XCTAssertTrue(state.emphasized.isEmpty)
        }
    }

    func testFrozenPolicyKeepsExistingHighlightAndKaraokeFallback() throws {
        let phrase = UUID()
        let units = [CaptionMotionUnit(id: phrase, interval: try interval(), isWordTimed: false)]
        var style = CaptionStyle.standard
        style.effect = .highlight
        XCTAssertEqual(CaptionMotionEvaluator.evaluate(units, active: [phrase],
            style: style, at: try time(1)).highlighted, [phrase])
        style = CaptionTemplate.karaoke.style
        XCTAssertEqual(CaptionMotionEvaluator.evaluate(units, active: [phrase],
            style: style, at: try time(1)).karaoke[phrase], 0.5)
        style.formatVersion = 2
        XCTAssertEqual(CaptionMotionEvaluator.evaluate(units, active: [phrase],
            style: style, at: try time(1)).emphasized, [phrase])
    }

    func testNonWordEffectsKeepTheSameMotion() throws {
        let phrase = UUID()
        let units = [CaptionMotionUnit(id: phrase, interval: try interval(), isWordTimed: false)]
        for effect in [CaptionEffect.none, .pop, .fade, .rise] {
            var style = CaptionStyle.standard
            style.effect = effect
            let at = try time(0.1)
            let old = CaptionMotionEvaluator.evaluate(units, active: [phrase], style: style, at: at)
            let current = CaptionMotionEvaluator.evaluate(units, active: [phrase], style: style, at: at,
                requireWordTiming: true)
            XCTAssertEqual(old.opacity, current.opacity)
            XCTAssertEqual(old.scale, current.scale)
            XCTAssertEqual(old.verticalOffset, current.verticalOffset)
        }
    }

    private func units(_ texts: [String]) -> [CaptionTextUnit] {
        texts.map { CaptionTextUnit(id: UUID(), text: $0) }
    }
    private func texts(_ result: [UUID: String], _ units: [CaptionTextUnit]) -> [String] {
        units.map { result[$0.id] ?? "" }
    }
    private func time(_ seconds: Double) throws -> MediaTime {
        try MediaTime(validating: CMTime(seconds: seconds, preferredTimescale: 60_000))
    }
    private func interval() throws -> MediaInterval {
        try MediaInterval(start: time(0), end: time(2))
    }
}
