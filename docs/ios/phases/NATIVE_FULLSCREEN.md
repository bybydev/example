# Native fullscreen playback

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
