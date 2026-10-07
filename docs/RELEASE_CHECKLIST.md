# ReadAloud 1.0 Release Checklist

This reduced final release pass replaces the original Phases 12–15 for 1.0.

## Already implemented

- iOS 26+ / iPhone-only product target.
- Marketing version 1.0, build 1 baseline.
- Durable .readaloud projects with explicit schema-version rejection.
- Atomic package/audio writes and rollback-safe finalized audio replacement.
- Retained source SHA-256 validation when a project is opened.
- Stale queued-generation recovery.
- Age-gated cleanup of orphaned hidden import staging directories.
- Background spoken-audio playback and system media controls.
- Storage/offline management.
- AppFoundation purchase, restore, paywall, entitlement, and premium-theme shell.
- Privacy manifest declares no tracking and no collected data.
- Analytics remains disabled by default; no 1.0 product-event collection is enabled.
- App Store 1.0 metadata baseline under AppStore/.

## Manual release checks

### Product smoke pass

- Import one EPUB.
- Import one PDF.
- Import/paste plain text.
- Force-close and reopen; verify projects and progress remain.
- Start streaming speech and verify first audio/play-pause/seek.
- Generate one chapter offline and replay the finalized WAV.
- Change voice/speed and verify incompatible exact audio position is invalidated safely.
- Background the app and verify Lock Screen / Control Center play-pause and seek.
- Interrupt playback (phone/audio route) and verify pause/recovery behavior.
- Clear Temporary Cache; verify source/final audio remain.
- Clear Generated Audio; verify source and reading bookmark remain.
- Verify Free project limit and canonical Pro paywall.
- Restore purchases in the Plan section.
- Turn Pro simulation off before any production archive.

### Accessibility / iPhone

- Check a compact supported iPhone and a large supported iPhone.
- Check one large Dynamic Type size.
- Check VoiceOver labels for Reader play/pause, configured skip interval, chapter progress, Chapters, and Reader Actions.
- Enable Reduce Motion and verify playback-follow scrolling does not animate.
- Verify long project/chapter titles truncate/wrap without blocking controls.

### Privacy / commerce

- Confirm App Store Connect product IDs match ReadAloudCommerce.
- Set final App Store prices in App Store Connect; local StoreKit prices are development-only.
- Confirm PrivacyInfo.xcprivacy still matches actual behavior.
- Confirm analytics is disabled for the production 1.0 configuration.
- Confirm Privacy / Terms / Support URLs resolve from the public release branch.

### App Store assets

- Add final App Store icon if it changes from the current asset.
- Capture the five screenshots in AppStore/Screenshots/README.md.
- Review name, subtitle, description, keywords, promotional text, review notes, and What's New.
- Confirm no internal engineering name or fixture/debug content appears in public screenshots/metadata.

### Archive / submission

The 1.0 canonical release path is manual/local using project.yml plus mycli/Xcode.

- Stage verified production Kokoro resources, not fixture resources.
- Generate the Xcode project from project.yml if the owner-managed project needs regeneration.
- Archive the ReadAloud iOS Release scheme with automatic signing.
- Verify the archive bundle ID is com.hoangbkit.readaloud.
- Verify version 1.0 and intended build number.
- Upload to TestFlight / App Store Connect.
- Install the TestFlight build on a physical iPhone and repeat the critical smoke flow above.
- Submit only after App Store screenshots, privacy answers, pricing, and review information are complete.

## Intentionally deferred after 1.0

- Broad product analytics/event funnel instrumentation.
- Expanded developer performance dashboards.
- Full accessibility certification across every screen/state.
- Automatic storage quotas/eviction/cloud sync.
- Additional migration versions beyond the current explicit v1 boundary.
- CI expansion/repair. The existing GitHub release workflow is not the canonical 1.0 submission path and was not modified or run in this final pass.
