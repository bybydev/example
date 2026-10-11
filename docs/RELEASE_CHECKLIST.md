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

- Verify Library opens without a tab bar; use the top-right Settings button and
  Back to return without losing the Library search or sort selection.
- Verify the circular floating plus button has no visible Add label and, in empty,
  populated, and search-result Library states, offers EPUB, PDF, Document, and Paste Text. It disables during import and
  cancellation cleanup; scrolling can reveal the final row above the button.
- Start playback, return to Library, and open Settings. Verify the mini-player
  remains accessible and the floating Add button sits above it only in Library.
- Import one EPUB.
- Import one PDF.
- Import/paste plain text.
- For EPUB, PDF, documents, and Paste Text: verify a successful import closes
  progress automatically, creates exactly one Library entry, and does not reopen
  at “Finishing…”.
- Exercise document formats: TXT/Markdown, SRT/VTT, RTF/HTML, DOCX/ODT/PPTX.
- Cancel and swipe-dismiss during extraction and normalization; verify immediate
  dismissal, no cancellation alert, no late progress reopening, and no published
  partial project. Synchronous extraction may finish unwinding before Add enables.
- Cancel during package staging; verify staging cleanup. If the atomic publish
  already completed, verify the completed project remains in the Library.
- Cancel the file picker; verify no error alert.
- Import empty, unsupported, and malformed content; verify an error, no new project,
  and that another import can start afterward.
- Submit pasted text; verify its editor dismisses before progress appears.
  Cancel/fail and reopen Paste Text to verify the draft is retained; successful
  import clears the matching draft.
- Try repeated Add actions while importing/cancelling; verify no overlapping jobs.
- With Pro disabled, import more than three projects using EPUB, PDF, documents,
  and Paste Text; verify all are allowed and durable.
- Force-close and reopen; verify projects and progress remain.
- Start streaming speech and verify first audio/play-pause/seek.
- Generate one chapter offline and replay the finalized WAV.
- Change voice/speed and verify incompatible exact audio position is invalidated safely.
- With the compact and expanded players, verify buffered audio is shown as
  separate subtle accent-colored source ranges, including disconnected cached
  chunks after seeking. Unavailable and still-generating chunks must remain
  neutral; played progress overlays the buffer ranges. Fully validated offline
  chapters fill the buffer track; ensure scrubbing and VoiceOver remain usable.
- Change Settings > Speech Engine > Unknown Words between Adaptive (default),
  Skip and Stop with Error; confirm selection persists after relaunch.
- Force recoverable bad tokens (e.g. unsupported script and >60-char word):
  Adaptive tries bounded letter-name fallback; Skip omits failed tokens; Stop
  reports the specific word. Original source and progress must remain intact.
- Verify an entirely unreadable chunk advances without an empty WAV in
  Adaptive/Skip, and changing modes invalidates incompatible chunk/final audio.
  Actual ONNX model failures must remain errors in every mode.
- Verify Speed in Settings / project / chapter: 0.5×–2× at 0.1× increments,
  −/+ controls and four presets. Cancel must preserve the previous speed; Done
  applies once, and inherited project/chapter speeds retain their source.
  Free users may choose custom chapter speeds without a paywall.
- Background the app and verify Lock Screen / Control Center play-pause and seek.
- Interrupt playback (phone/audio route) and verify pause/recovery behavior.
- Clear Temporary Cache; verify source/final audio remain.
- Clear Generated Audio; verify source and reading bookmark remain.
- On Free, verify bulk Generate Selected/Remaining/All, prefetch,
  Generate While Listening, and Clear Cache & Regenerate work without a paywall.
- Verify the Pro paywall advertises only extra voices and themes.
- On Free, confirm Heart can be selected as a project or chapter voice while
  the other 27 voices require Pro. Theme locking must remain unchanged.
- Restore purchases in the Plan section.
- Turn Pro simulation off before any production archive.

### Appearance

- On a fresh install, verify ReadAloud Dark is the default. Verify the picker
  offers free ReadAloud Light and Dark themes and has no System option.
- Select ReadAloud Light or Dark explicitly; verify it stays fixed across system
  changes and relaunch, with both themes available on Free.
- Upgrade an existing Midnight/Paper selection; verify it maps to ReadAloud
  Dark/Light. Preserve other saved theme selections and entitlement behavior.
- Inspect Library, Settings, project details, Reader, sheets, and the mini-player
  in both appearances; check text, row surfaces, toolbar icons, and the floating
  plus button for readable contrast.
- Select a Pro theme, restore/purchase, and simulate expiry; verify the existing
  access behavior and the ReadAloud Dark fallback.

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

The GitHub **Release** workflow creates an unsigned mycli archive for the
selected branch and configuration (Debug or Release). **Every build bundles
Kokoro ONNX INT8, both G2P assets and all 28 English voice styles.** There is
no fixture/real selector and no user-facing model download.

The canonical App Store submission path remains manual/local using project.yml
plus mycli/Xcode, with the same verified ONNX resources.

- On a local build machine, run `python3 scripts/onnx-assets.py download`
  and `bash scripts/stage-onnx-resources-for-build.sh` before generating/archiving.
- Verify the archived `ReadAloud.app/ONNX` folder contains all 31 pinned
  resources (use `python3 scripts/onnx-assets.py verify --root <app>/ONNX`).
- Verify the production archive contains no Core ML packages or model selector.
- Install offline and confirm Listen, resume, and the Settings speech test never
  request a model download or network connection.
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
- Fast CI / Full CI implementation. The manual Release artifact workflow is implemented; App Store upload remains intentionally outside GitHub Actions.


## Listen safety verification — pending

- [ ] Run the scenarios in LISTEN_SAFETY.md on a physical supported iPhone with
  real models, in both Debug and Release.
- [ ] Capture peak memory through first synthesis, long chapter completion,
  cached replay, seek/resume, and repeated project switching.
- [ ] Confirm memory warnings stop work with a recoverable error and preserve
  source progress; retry after cleanup succeeds without duplicate model loads.
- [ ] Confirm malformed/oversized input or audio yields an error, not a trap.

These items have not been executed by the implementation pass. No CI was triggered.
