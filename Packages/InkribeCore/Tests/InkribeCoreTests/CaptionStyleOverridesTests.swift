import Foundation
import XCTest
@testable import InkribeCore

/// Authored regression specifications. Execution requires separate authorization.
final class CaptionStyleOverridesTests: XCTestCase {
    func testColorOverrideContinuesInheritingProjectTypography() throws {
        var defaults = CaptionStyle.standard
        var edited = defaults
        edited.textColor = .pink
        var overrides = CaptionStyleOverrides()
        overrides.recordChanges(from: defaults, to: edited)
        defaults.font = .serif
        defaults.fontSize = 0.08
        let resolved = overrides.resolved(over: defaults)
        XCTAssertEqual(resolved.textColor, .pink)
        XCTAssertEqual(resolved.font, .serif)
        XCTAssertEqual(resolved.fontSize, 0.08)
        try resolved.validate()
    }

    func testSectionResetRestoresFutureInheritanceWithoutClearingOtherOverrides() {
        let defaults = CaptionStyle.standard
        var value = defaults
        value.textColor = .pink; value.effect = .karaoke
        var overrides = CaptionStyleOverrides()
        overrides.recordChanges(from: defaults, to: value)
        overrides.reset(.colors)
        var changedDefaults = defaults
        changedDefaults.textColor = .mint
        let resolved = overrides.resolved(over: changedDefaults)
        XCTAssertEqual(resolved.textColor, .mint)
        XCTAssertEqual(resolved.effect, .karaoke)
        XCTAssertFalse(overrides.isCustomized(.colors))
        XCTAssertTrue(overrides.isCustomized(.motion))
        overrides.reset(.motion)
        XCTAssertTrue(overrides.isEmpty)
    }

    func testSerializedOverrideDoesNotFreezeUncustomizedFields() throws {
        var overrides = CaptionStyleOverrides()
        var value = CaptionStyle.standard
        value.positionY = 0.4
        overrides.recordChanges(from: .standard, to: value)
        let restored = try JSONDecoder().decode(CaptionStyleOverrides.self, from: JSONEncoder().encode(overrides))
        var defaults = CaptionStyle.standard
        defaults.positionX = 0.25; defaults.font = .mono
        let resolved = restored.resolved(over: defaults)
        XCTAssertEqual(resolved.positionY, 0.4)
        XCTAssertEqual(resolved.positionX, 0.25)
        XCTAssertEqual(resolved.font, .mono)
    }

    func testLegacyColorCustomizationPreservesLegacyAppearanceFormat() throws {
        var overrides = CaptionStyleOverrides()
        var value = CaptionStyle.standard
        value.textColor = .mint
        overrides.recordChanges(from: .standard, to: value)
        let resolved = overrides.resolved(over: .standard)
        XCTAssertEqual(resolved.formatVersion, 1)
        try resolved.validate()
    }

    func testExplicitModernAnimationKeepsItsRenderingVersionOverLegacyDefaults() throws {
        var overrides = CaptionStyleOverrides()
        var modern = CaptionStyle.standard
        modern.formatVersion = 2; modern.effect = .pop
        overrides.recordChanges(from: .standard, to: modern)
        let resolved = overrides.resolved(over: .standard)
        XCTAssertEqual(resolved.effect, .pop)
        XCTAssertEqual(resolved.formatVersion, 2)
        try resolved.validate()
        overrides.reset(.motion)
        XCTAssertEqual(overrides.resolved(over: .standard).formatVersion, 1)
    }

    func testModernClipTypographyRemainsValidAfterProjectReturnsToBasic() throws {
        var overrides = CaptionStyleOverrides()
        var modern = CaptionStyle.standard
        modern.formatVersion = 2; modern.weight = .heavy
        overrides.recordChanges(from: .standard, to: modern)
        let resolved = overrides.resolved(over: .standard)
        XCTAssertEqual(resolved.weight, .heavy)
        XCTAssertEqual(resolved.formatVersion, 2)
        try resolved.validate()
    }

    func testFutureOverrideFormatIsNotSilentlyNormalizedByModernFields() {
        var overrides = CaptionStyleOverrides()
        overrides.formatVersion = 99; overrides.weight = .heavy
        let resolved = overrides.resolved(over: .standard)
        XCTAssertEqual(resolved.formatVersion, 99)
        XCTAssertThrowsError(try resolved.validate())
    }

    func testApplyingPresetKeepsPlacementInheritedUntilExplicitlyCustomized() throws {
        var overrides = CaptionStyleOverrides()
        var preset = CaptionStyle.standard
        preset.font = .serif; preset.positionY = 0.2
        overrides.applyPreset(preset)
        var defaults = CaptionStyle.standard
        defaults.positionY = 0.65
        XCTAssertEqual(overrides.resolved(over: defaults).positionY, 0.65)
        overrides.applyPreset(preset, preservingPlacement: false)
        XCTAssertEqual(overrides.resolved(over: defaults).positionY, 0.2)
        try overrides.resolved(over: defaults).validate()
    }
}
