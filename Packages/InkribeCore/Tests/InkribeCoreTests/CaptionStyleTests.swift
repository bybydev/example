import CoreMedia
import Foundation
import XCTest
@testable import InkribeCore

/// Source specifications only; not executed during issue #38 implementation.
final class CaptionStyleTests: XCTestCase {
    func testLegacyPayloadDefaultsToFrozenAppearance() throws {
        // A historical payload, independent of current model/catalog encoding.
        let legacy = Data(#"""
        {"font":"bold","fontSize":0.06,"textColor":{"red":1,"green":1,"blue":1,"alpha":1},
         "accentColor":{"red":0.25,"green":1,"blue":0.65,"alpha":1},
         "outlineColor":{"red":0,"green":0,"blue":0,"alpha":1},"outlineWidth":0.045,
         "backgroundEnabled":true,"backgroundColor":{"red":0,"green":0,"blue":0,"alpha":0.6},
         "positionX":0.5,"positionY":0.82,"effect":"karaoke"}
        """#.utf8)
        let decoded = try JSONDecoder().decode(CaptionStyle.self, from: legacy)
        XCTAssertEqual(decoded, CaptionTemplate.karaoke.style)
        XCTAssertEqual(decoded.weight, .original)
        XCTAssertEqual(decoded.lineWidth, 1); XCTAssertEqual(decoded.maximumLines, 8)
        XCTAssertEqual(decoded.lineSpacing, 0.1); XCTAssertEqual(decoded.minimumScale, 1)
        XCTAssertEqual(decoded.backgroundPadding, 0.28); XCTAssertEqual(decoded.backgroundRadius, 0.22)
        XCTAssertFalse(decoded.shadowEnabled)
        XCTAssertEqual(decoded.formatVersion, 1)
        XCTAssertFalse(decoded.requiresSchema8)
        XCTAssertNil(decoded.preset)
    }

    func testResolvedVersionTwoRejectsMissingAndNullFields() throws {
        let preset = try XCTUnwrap(CaptionPreset.catalog.first { $0.id == "cinema" })
        let bytes = try JSONEncoder().encode(preset.resolved)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let fields = ["weight", "tracking", "lineWidth", "lineSpacing", "maximumLines", "alignment", "minimumScale",
            "backgroundMode", "backgroundPadding", "backgroundRadius", "shadowEnabled", "shadowColor",
            "shadowBlur", "shadowOffsetX", "shadowOffsetY"]
        for field in fields {
            var missing = original
            missing.removeValue(forKey: field)
            XCTAssertThrowsError(try JSONDecoder().decode(CaptionStyle.self,
                from: JSONSerialization.data(withJSONObject: missing)), "Missing \(field) must not reset a resolved look")
            var null = original
            null[field] = NSNull()
            XCTAssertThrowsError(try JSONDecoder().decode(CaptionStyle.self,
                from: JSONSerialization.data(withJSONObject: null)), "Null \(field) must not reset a resolved look")
        }
    }

    func testCatalogDefinitionsAreValidDistinctAndRoundTripResolvedValues() throws {
        XCTAssertEqual(CaptionPreset.catalog.count, 10)
        XCTAssertEqual(Set(CaptionPreset.catalog.map(\.id)).count, 10)
        for preset in CaptionPreset.catalog {
            let style = preset.resolved
            try style.validate()
            XCTAssertEqual(try JSONDecoder().decode(CaptionStyle.self, from: JSONEncoder().encode(style)), style)
            XCTAssertEqual(CaptionPreset.definition(for: style.preset)?.version, preset.version)
            XCTAssertTrue(preset.matches(style))
            XCTAssertTrue(style.requiresSchema8)
        }
        // Color/placement/identity differences alone do not make a new design.
        for a in CaptionPreset.catalog.indices {
            for b in CaptionPreset.catalog.indices where b > a {
                XCTAssertNotEqual(designSignature(CaptionPreset.catalog[a].style), designSignature(CaptionPreset.catalog[b].style))
            }
        }
    }

    private func designSignature(_ input: CaptionStyle) -> CaptionStyle {
        var value = input.withoutPreset
        value.formatVersion = 2
        value.textColor = .white; value.accentColor = .yellow; value.outlineColor = .black
        value.backgroundColor = .black; value.shadowColor = .black
        value.positionX = 0.5; value.positionY = 0.82
        return value
    }

    func testCatalogDoesNotUpgradeHistoricalReference() throws {
        let old = try XCTUnwrap(CaptionPreset.definition(for: .init(id: "karaoke", version: 1)))
        let current = try XCTUnwrap(CaptionPreset.catalog.first { $0.id == "karaoke" })
        XCTAssertEqual(old.style, CaptionTemplate.karaoke.style)
        XCTAssertEqual(old.style.formatVersion, 1)
        XCTAssertEqual(current.version, 2)
        let saved = old.resolved
        XCTAssertEqual(try JSONDecoder().decode(CaptionStyle.self, from: JSONEncoder().encode(saved)), saved)
        XCTAssertEqual(CaptionPreset.matching(saved)?.version, 1)
    }

    func testPresetApplyPreservesPlacementAndPlacementResetIsIndependent() throws {
        let preset = try XCTUnwrap(CaptionPreset.catalog.first { $0.id == "classroom" })
        var current = CaptionStyle.standard
        current.positionX = 0.4; current.positionY = 0.75
        var applied = preset.preservingPosition(of: current)
        XCTAssertEqual(applied.positionX, 0.4); XCTAssertEqual(applied.positionY, 0.75)
        XCTAssertEqual(applied.preset, preset.reference)
        applied.textColor = .pink
        let repositioned = applied.resetting(.placement, to: preset.style)
        XCTAssertEqual(repositioned.positionY, preset.style.positionY)
        XCTAssertEqual(repositioned.textColor, .pink)
        XCTAssertEqual(repositioned.preset, applied.preset)
    }

    func testResetTypographyDoesNotReplaceLayoutMotionOrIdentity() throws {
        let preset = try XCTUnwrap(CaptionPreset.catalog.first { $0.id == "punch" })
        var style = preset.resolved
        style.fontSize = 0.1; style.lineWidth = 0.6; style.effect = .rise
        let reset = style.resetting(.typography, to: preset.style)
        XCTAssertEqual(reset.fontSize, preset.style.fontSize)
        XCTAssertEqual(reset.lineWidth, 0.6); XCTAssertEqual(reset.effect, .rise)
        XCTAssertEqual(reset.preset, style.preset)
        XCTAssertFalse(preset.matches(reset))
    }

    func testUnknownPresetIdentityPreservesSavedResolvedLook() throws {
        var style = CaptionStyle.standard
        style.formatVersion = 2; style.preset = .init(id: "retired-look", version: 23)
        style.lineWidth = 0.65; style.shadowEnabled = true
        let saved = try JSONDecoder().decode(CaptionStyle.self, from: JSONEncoder().encode(style))
        XCTAssertEqual(saved, style)
        XCTAssertNil(CaptionPreset.definition(for: saved.preset))
        XCTAssertNil(CaptionPreset.matching(saved))
    }

    func testFutureStyleIsNotTreatedAsCorruptPriorValidFallback() throws {
        var dictionary = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(CaptionStyle.standard)) as? [String: Any])
        dictionary["formatVersion"] = 99
        dictionary["font"] = "future-font"
        let data = try JSONSerialization.data(withJSONObject: dictionary)
        XCTAssertThrowsError(try JSONDecoder().decode(CaptionStyle.self, from: data)) { error in
            guard let stored = error as? ProjectStoreError, case .unsupportedCaptionStyle(99) = stored else {
                return XCTFail("Future format must be identified before decoding unknown fields: \(error)")
            }
        }
        var future = CaptionStyle.standard
        future.formatVersion = 99
        XCTAssertEqual(future.resetting(.colors, to: .standard).formatVersion, 99)
        XCTAssertThrowsError(try future.validate())
    }

    func testInvalidExtendedValuesCannotMasqueradeAsLegacy() {
        var style = CaptionStyle.standard
        style.lineWidth = 0.5
        XCTAssertThrowsError(try style.validate())
        style.formatVersion = 2; style.shadowBlur = .infinity
        XCTAssertThrowsError(try style.validate())
        style.shadowBlur = 0.2; style.maximumLines = 0
        XCTAssertThrowsError(try style.validate())
    }

    func testExpiryRetainsPremiumLookAndFreeChangesButPreventsNewPremiumFields() throws {
        let premium = try XCTUnwrap(CaptionPreset.catalog.first { $0.id == "cinema" }).resolved
        var changed = premium
        changed.textColor = .pink; changed.fontSize = 0.06; changed.positionY = 0.6
        XCTAssertTrue(CaptionStyleAccess.canChange(from: premium, to: changed, hasPro: false))
        XCTAssertTrue(CaptionStyleAccess.canChange(from: premium, to: .standard, hasPro: false))
        XCTAssertFalse(CaptionStyleAccess.canChange(from: .standard, to: premium, hasPro: false))
        var newWeight = CaptionStyle.standard
        newWeight.formatVersion = 2; newWeight.weight = .heavy
        XCTAssertFalse(CaptionStyleAccess.canChange(from: .standard, to: newWeight, hasPro: false))
        XCTAssertTrue(CaptionStyleAccess.canChange(from: .standard, to: newWeight, hasPro: true))
    }

    func testPhraseKaraokeDoesNotInventWordSweepAndMixedTimingStaysIndependent() throws {
        let precise = UUID(), phrase = UUID()
        let interval = try MediaInterval(start: MediaTime(value: 0, timescale: 1), end: MediaTime(value: 2, timescale: 1))
        let units = [CaptionMotionUnit(id: precise, interval: interval, isWordTimed: true),
                     CaptionMotionUnit(id: phrase, interval: interval, isWordTimed: false)]
        let time = try MediaTime(value: 1, timescale: 1)
        var style = CaptionTemplate.karaoke.style
        let legacy = CaptionMotionEvaluator.evaluate(units, active: [precise, phrase], style: style, at: time)
        XCTAssertEqual(legacy.karaoke[phrase], 0.5)
        style.formatVersion = 2
        let current = CaptionMotionEvaluator.evaluate(units, active: [precise, phrase], style: style, at: time)
        XCTAssertEqual(current.karaoke[precise], 0.5)
        XCTAssertNil(current.karaoke[phrase])
        XCTAssertTrue(current.emphasized.contains(phrase))
        let later = try MediaTime(value: 3, timescale: 1)
        XCTAssertTrue(CaptionMotionEvaluator.evaluate(units, active: [], style: style, at: later).emphasized.isEmpty)
    }

    func testLayoutPolicyKeepsReadableFloorAndLegacyMotionBounds() {
        XCTAssertEqual(CaptionLayoutPolicy.outerInsetInFontUnits(for: CaptionTemplate.spotlight.style), 0)
        var style = CaptionStyle.standard
        style.formatVersion = 2; style.fontSize = 0.025; style.minimumScale = 0.5
        XCTAssertEqual(CaptionLayoutPolicy.minimumFontFraction(for: style), 0.025)
        style.effect = .rise
        XCTAssertEqual(CaptionLayoutPolicy.outerInsetInFontUnits(for: style), 0.35)
        XCTAssertEqual(CaptionLayoutPolicy.refinementCount, 4)
    }
}
