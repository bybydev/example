# Preview handoff — source handoff

2026-10-28. Stacked on PR #50 at `5c9f9eb247cb6339d2c41fb05f55f721b3a4dc03`.
Branch fix/ios-preview-handoff targets feat/ios-contextual-caption-editor.
Keep both PRs open without auto-merge; parent PR source is not modified.

- [x] Covered main/Captions previews remain mounted with a still instead of exposing
  Color.black after video-layer removal. Preview dimensions/controls are preserved.
- [x] One session-owned decoded-frame output, one retained pixel buffer, at most
  768px stills per mounted host and a shared latest-still reference. Conversion only
  at readiness/handoff; no per-tick bitmap conversion, extra player or asset decoder.
- [x] Capture before live ownership transfer, including inverse UIKit mount/dismantle
  ordering. Returning hosts adopt the outgoing host's latest still.
- [x] Readiness-gated live reveal; transition/item identity guards, weak ownership,
  observer teardown and stale publication rejection. Item replacement/stop reset
  decoded-output ownership. Failed capture keeps an earlier valid still.
- [x] Closing Customize/manual/fullscreen hosts lose live permission through their
  presentation state; late item changes cannot reclaim the layer during dismissal.
- [x] Frozen video/caption snapshot and presentation clock stay together; incoming
  live overlay resumes with live time. Audio-only items bypass video readiness.
- [x] Main/Captions/fullscreen, Customize and manual authoring share the adapter;
  nested authoring and contextual push/pop retain the parent interaction behavior.
- [x] #50 row selection/highlight/seek, top-left Edit caption, list read-only policy,
  no Split / Words, native push/pop, preview controls and no auto-scroll preserved.
- [x] No schema, renderer implementation, recognition, speech/model/allowance,
  queue/export, commerce, shared package, Mac or CI change.

Ownership: PreviewFrameBuffer samples existing AVPlayerItem output and coordinates
one live host. PlayerSurface owns layer/still/KVO handoff. EditorPlayerPreview pairs
the held caption presentation with existing StyledCaptionOverlay. EditorSession
attaches/resets/samples output at its existing preview lifecycle and clock points.

Source review covers initial/paused/playing, rapid transfer, return after sheet
playback, nested manual authoring, caption push/pop, fullscreen, item replacement,
teardown and audio-only paths. No builds/typechecks/tests/fixtures, CI, generation,
native playback/exports or UI/device execution ran. Compilation and actual visual,
touch, VFR/HDR/color/orientation, memory/thermal and scheduling acceptance are
unverified. Native pipeline resource use is not inferred from the app's cache bound.
This addresses the confirmed covered-preview removal; it does not claim to repair
unrelated missing/undecodable video or a persistently failed sheet player.

API references reviewed (Apple primary documentation):
- https://developer.apple.com/documentation/avfoundation/avplayerlayer/isreadyfordisplay
- https://developer.apple.com/documentation/avfoundation/avplayeritemvideooutput/copypixelbuffer(foritemtime:itemtimefordisplay:)
- https://developer.apple.com/documentation/avfoundation/avplayeritemoutput/suppressesplayerrendering

---

## Approved scope — archived brief (consolidated 2026-11-07)


2026-10-28. User confirmed the proposed fix in a stacked PR. Start at PR #50 head
`5c9f9eb247cb6339d2c41fb05f55f721b3a4dc03`, branch fix/ios-preview-handoff, target
feat/ios-contextual-caption-editor. Keep both PRs open without auto-merge.

- Preserve a current video frame before disconnecting the covered live surface.
- Keep the covered preview mounted with a bounded still and matching caption
  snapshot/clock. Preserve geometry while sheets animate and playhead/style changes
  occur elsewhere. One player and one live layer owner; no reload or extra decoder.
- Return with the outgoing host's latest still, then expose live video only after
  AVPlayerLayer readiness. Reject callbacks from earlier handoffs/items/teardown.
- Apply the same adapter to main/Captions/fullscreen, Customize and manual authoring.
- Keep audio-only caption playback live; retain existing no-frame/source-error states.
- Preserve every #50 row/select/seek/top-left edit, push/pop, preview/control and
  no-auto-scroll behavior; preserve caption timing/history/save and immutable outputs.
- No renderer implementation, schema, shared packages, speech/model/allowance,
  queue/export/commerce, Mac, CI or further consolidation changes.

Source-only: no builds/typechecks/tests/fixtures, CI/generation/models, native media
processing/exports, UI/device/accessibility execution or deployment. Source
integration is not runtime acceptance. Other edit plans await user confirmation.

