# Native fullscreen playback — source handoff

## Fullscreen caption clock follow-up

2026-11-01. The user reports captions freezing at fullscreen entry and requests
the fix in a new generic fix/ios-improvements PR from develop 5910c9c, targeting
develop. Keep this PR open for later explicitly requested small changes.

- [x] NativeVideoPlayer.Presenter owns an editor-only 30 Hz AVPlayer periodic
  time observer. Caption redraws no longer require the covered SwiftUI editor to
  call updateUIViewController. Native playback and time jumps drive the callback.
- [x] Each redraw reads the current session snapshot and actual player time,
  clamped to output duration, rather than a previously forwarded SwiftUI clock.
  Readiness still selects the matched held frame/snapshot/time until video is ready;
  the existing video-bounds observer preserves rotation/zoom alignment.
- [x] Observer replacement, final dismissal/failure and representable teardown
  remove the token from the exact player that registered it. Generation and weak
  controller checks reject queued callbacks after replacement/close/reopen; skip
  updates when the native controller no longer owns the player.
- [x] Completed-file previews do not install the observer. The shared editor player,
  native controls, pause/current-time return, delivery leases, inline previews,
  renderer, export pipeline and project data remain unchanged.

Validation: source lifecycle/call-site review and diff/whitespace checks only.
No builds/typechecks/tests, CI or native/UI/device execution. Compilation and
device playback/paused seeking/close/reopen acceptance remain unverified.

## Original native-player implementation

2026-10-29. feat/ios-native-fullscreen-player -> feat/ios-style-sheet-grid.
Based on PR #52 head 3f9b81076fd3ec0e20638865b3cdbd57247f3d2f; parent unchanged.
Keep both PRs open without auto-merge.

CI follow-up: bybydev/example run 40844877724 failed on Swift 6.2.4 because
AVPlayerViewControllerDelegate's nonisolated conformance crossed Presenter isolation.
Explicitly mark that conformance @MainActor, as the compiler recommends. This is a
source correction; no agent build/test/CI rerun or successful-build claim.

- [x] Shared NativeVideoPlayer presents an un-subclassed AVPlayerViewController
  modally, using native fullscreen playback/dismissal controls.
- [x] Both editor expand entries use the existing player/item; remove the custom
  fullscreen NavigationStack/Done/transport/timeline/history implementation.
  Preserve the entry's playing/paused state and current playhead.
- [x] NativeCaptionOverlay uses StyledCaptionOverlay.Surface in contentOverlayView;
  follows videoBounds for rotation/zoom and the session's existing caption clock.
  Held frame/snapshot/time stay paired until native display readiness.
- [x] Participate in PreviewFrameBuffer ownership, detach the previous layer before
  native attachment, and retain an up-to-date still before returning to the editor.
  Keep the main preview mounted/covered and geometry independent of modal state.
- [x] EditorSession observes actual timeControlStatus and retains native seek time
  on return. Pause on close/inactivity; no seek, new graph or history edit on entry.
- [x] ExportResultView uses the same native presenter across Exported files, completed
  Queue jobs and retained files. Completed-file captions remain burned in; no live
  overlay or dependency on the working project's later edits.
- [x] Preserve the job-specific delivery lease until native detachment, then pause,
  clear the file player's item and release once. Share/Files/Photos unchanged.
- [x] Native dismissal, adaptive dismissal fallback, cancelled transitions, playback
  failure and teardown paths share guarded cleanup. Observers and delegates are
  removed; caller external-playback policy restored. PiP/external playback remain
  disabled during these in-app previews; no new background playback entitlement.
- [x] No changes to inline players, Style samples/settings, caption/media values,
  export processing/manifests/files, schema/packages/renderer, Mac or speech/commerce.

Source review: entry/call-site inventory, modal lifecycle/ownership/lease review,
diff/whitespace checks, remote expected-base/preserved-files and final PR verification.
No builds/typechecks/tests/fixtures, CI, generation/downloads, native playback/render/
export or UI/device execution. Compilation, native close/gesture cancellation,
rotation/zoom, live captions while scrubbing, error transitions and frame-return
appearance need user device validation. Source completion is not runtime acceptance.

Apple API references reviewed:
- https://developer.apple.com/documentation/avkit/avplayerviewcontroller
- https://developer.apple.com/documentation/avkit/avplayerviewcontroller/contentoverlayview
- https://developer.apple.com/documentation/avkit/avplayerviewcontroller/videobounds
- https://developer.apple.com/documentation/avkit/avplayerviewcontrollerdelegate
- https://developer.apple.com/documentation/avfoundation/avplayer/timecontrolstatus-swift.property

---

## Approved scope — archived brief (consolidated 2026-11-07)


2026-10-29. Explicit implementation request, stacked on PR #52 at 3f9b8107.
feat/ios-native-fullscreen-player -> feat/ios-style-sheet-grid. Keep both PRs open
without auto-merge; do not modify the parent branch.

- EDITOR.NATIVE_FULLSCREEN: playback-row fullscreen and ellipsis Expand preview
  present AVPlayerViewController directly. No custom Preview navigation, Done,
  editor transport, timeline or history in fullscreen.
- Reuse the current editor AVPlayer/AVComposition/video composition/audio mix.
  Live styled captions use the existing drawing adapter in contentOverlayView,
  synchronized with the player clock. No temporary output or extra editor player.
  Preserve playing/paused state on entry; close returns paused at the current time.
- Keep one live owner, a matched video/caption still under the modal, and readiness
  before live return. Native seeks return to the current position paused, without
  changing selection/history/project values. Observe native playback state too.
- Align captions to native videoBounds during aspect fit, zoom and rotation;
  use held media/caption state while the native layer becomes ready.
- EXPORT.NATIVE_PREVIEW: replace ExportVideoPreview's navigation/sheet wrapper
  with the same direct native presentation. Every existing ExportResultView route
  in Exported files, Queue completed exports and retained completed files follows it.
  Use the selected immutable MP4 and its already-burned-in captions.
- Preserve delivery protection until native dismissal, failure or teardown has
  detached playback; pause/clear the file player before releasing its lease.
- Native presentation callbacks must be idempotent, reject obsolete media callbacks,
  and survive cancelled transitions or teardown during presentation. Pause when
  the app resigns active. Surface playback failures through existing error UI.
- Keep these previews in-app: PiP/external playback disabled during presentation,
  with the caller's external-playback policy restored afterward. No background mode.
- Keep all inline previews, Style's sample/form/transaction and placement, editor
  actions/timeline/caption/media workflows, export capture/processing/delivery actions,
  shared renderer/packages, schema, Mac, speech/model/allowance and commerce intact.

Source/call-site/diff/publication review only. No builds/typechecks/tests/fixtures,
CI/generation/downloads, native media playback/render/export, UI/device execution or
deployment. Compilation and real-device transitions/controls/legibility remain
unverified. Discussion of further work requires a separate implementation command.

