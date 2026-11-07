# Timeline editor — passes 1–3 source handoff

Issue #47, PR #48. Base develop `0bb0653dc3c78294f45aef852c1e671d8f0511e1`.
Pass 2 extends `833c08050deaaca7be9221dbf8ee3857133013a5`; pass 3 extends
`95628a769c09a11209c8cd349ff1f9369d8e1699` on `feat/ios-timeline-editor` → develop. Leave open with no auto-merge.

## Pass 1 — retained

- [x] Four-area editor and sticky horizontal actions, with no main caption list.
- [x] Captions/Timing/Media sheets, large animated Styles, Customize and Export.
- [x] Nested manual-caption/upsell routes, stable preview and fullscreen handoff.
- [x] Delayed blurred loading/custom indicator, Cancel/Back and stale-load rejection.

## Pass 2 — implemented source work

- [x] One continuous trimmed output-clock timeline for all retained clips, with
  visible clip boundaries, names, selection and rename/start access.
- [x] Real oriented frame samples throughout each video clip, aligned to ruler
  time. Retained source start accounts for project trim/clip source offsets.
- [x] Caption blocks/gaps align beneath their media on the same output axis.
  Native overlapping captions remain visible via prefix-max interval lookup.
- [x] Track/header space is reserved before sizing portrait footage on small screens;
  sheet and keyboard state remain excluded from preview sizing.
- [x] Fixed center playhead and start/end padding; horizontal scrub/deceleration
  pauses playback and uses coalesced seeks plus a final exact seek.
- [x] Playback moves tracks beneath the playhead across the existing composition.
  Programmatic scrolls do not seek; playback/selection/sheets cancel stale scrubs.
- [x] Pinch zoom anchors time under the fingers, clamps scale/content coordinates,
  and preserves navigation scale in session presentation state.
- [x] Tap clip to select/seek. Tap caption to select; tap selected caption again
  to open text/timing correction without re-seeking on that second tap.
- [x] Visible/nearby asynchronous frame work, at most two live decoders, obsolete
  request cancellation, normalized 192px frames and 12 MiB cache budget.
- [x] Missing/audio/failed frame placeholders; optional artwork never fails opening.
  Covered/background timelines suspend requests; teardown cancels work.
- [x] Viewport-sized drawing, per-snapshot projection, interval-indexed lookup,
  cached frames, and native adjustable/activatable VoiceOver timeline elements.
- [x] Source review and updated current scope/design/architecture/feature records.

## Pass 3 — implemented source work

- [x] Selected caption body drag, visible start/end edge handles and hold-to-move
  for unselected/narrow captions; other drags continue scrolling.
- [x] Transient proposed block/readout with validity feedback and frame audition;
  commit on release only. Canonical caption rendering changes after that commit.
- [x] Exact rational translation of every linked word on body moves. Resize uses
  the existing explicit affine manual timing adjustment; native source anchors,
  IDs, text/grouping and raw recognition are unchanged.
- [x] Clip/retained-range bounds, positive minimum interval and word precision guard;
  hidden trim portions remain intact, and hidden edges are edited in the sheet.
- [x] Preserve allowed native overlaps and previously reviewed manual replacements.
  Reject new manual overlaps/replacements, rechecking concurrent results at release.
- [x] One existing native/manual undo patch and normal atomic autosave per accepted
  gesture. No-op, cancelled, rejected or stale gestures create no timing patch.
- [x] Compare captured cue/words/clip/trim at commit; unrelated saves/publications
  remain compatible. Changed target state cancels the transient gesture.
- [x] Edge scrolling with bounded clip motion; exclusive gesture ownership, final
  pointer sample, cancellation of audition seeks and teardown of the weak-target clock.
- [x] Navigation/sheet/background/rotation/playback-start cancellation; rejected and
  direct touch-cancel gestures restore the initial playhead without discarding edits.
- [x] VoiceOver move/start/end actions use the same transaction and history path.
- [x] Source/call-site/diff/whitespace review and current scope/design documentation.

## Source ownership

ProjectTimelineSnapshot: output geometry, interval indexes, source sample/tile keys.
ProjectTimelineView: native scrolling, ruler/track viewport, pinch/seek ownership.
TimelineTrackCanvas: visible drawing, selection/hits, virtual accessibility elements.
TimelineThumbnailLoader: bounded asynchronous decode/cache and cancellation.
EditorSession/EditorWorkspace: derived projection, source URLs and transient selection.
ProjectEditorView: frame timeline integration, selected-clip menu and correction sheet.
TimelineCaptionTiming: expected-state capture, rational proposals, bounds and overlap rules.
CaptionEdits.moveCue: constant word translation without native-anchor rewriting.
EditorSession: gesture admission and one existing patch/history/save commit.
Pass-1 files retain opening/sheet/save/fullscreen ownership.

No schema, Mac/shared-package, generator, queue/commerce/speech or export-renderer
changes. The old ClipStrip/CaptionTimeline helpers remain for other existing routes,
but are removed from the main timeline workspace.

## Checks and limitations

Source/call-site/diff/whitespace and publication review only. No builds/typechecks/
tests/fixtures, CI, generation/models, native media/export, UI/device/accessibility
execution or deployment. Compilation and physical-device acceptance remain pending.
In particular: real orientation/VFR/HDR frame sampling, gesture/deceleration/pinch
behavior, decoder cancellation latency, native modal/player handoff, small-phone
layout, VoiceOver and long-project thermal/memory performance are not executed claims.
Very short/subpixel clips render their boundaries; the decoder prioritizes readable
visible tiles instead of generating every clip's artwork at extreme zoom-out.

All requested passes now have source integration. No runtime/device/production
acceptance is claimed. Actual touch competition, cancellation at every phase,
retiming/reopen/undo/redo, trim/overlap and native preview/export parity still need
owner verification under the existing execution policy. No merge is authorized.

## CI follow-up — gesture admission override

Observed Build Release run [40541966301](https://github.com/bybydev/example/actions/runs/40541966301)
on the pass-3 commit 8c1935e failed while emitting the iOS Swift module. Both errors
pointed to ProjectTimelineView.swift: gestureRecognizerShouldBegin redeclared
UIView's selector in an extension without the required override. The method is
now an override in TimelineViewport's class body, and non-timing gestures retain
the superclass admission policy. Timing pan/hold checks are unchanged.

Source/diff/whitespace review only for this correction; the updated head has not
been compiled or rerun in CI. The observed failed run is not a passing validation.

---

## Approved scope — archived brief (consolidated 2026-11-07)


Reference: https://github.com/hoangbkit/Inkribe/issues/47 and the supplied CapCut
screenshot. Current authorization is **passes 1–3**, in existing PR #48 targeting
develop, left open without auto-merge. Pass 3 extends pass-2 head 95628a7.

## Pass 1 scope

- Fixed media player → player controls → timeline area → sticky horizontal actions.
- Remove the editor's inline transcript/configuration. Bottom actions open sheets;
  retain text/timing, split/merge, manual creation, retry, settings/reset and export.
- Preserve existing large animated Styles browser and current preview dimensions
  through sheet/keyboard/focus changes.
- Use the current overview scrubber/clip strip as the functional interim timeline.
- Delayed custom preparation indicator over blurred editor content; Cancel and
  native Back remain usable. Cancel/Back invalidate and cancel opening work without
  affecting saved data, edits, transcription/export queue jobs or the rest of the app.
- Recoverable errors/retry, existing session/save/history/Pro/model contracts.

## Pass 2 scope — source integrated

Actual sampled frame thumbnails, continuous multi-clip tracks/boundaries, ruler,
centered playhead, continuous scrub/playback, clip/caption selection and anchored
pinch zoom. Trim/source offset mapping stays consistent with the existing player.
Second tap on the selected caption opens its text/timing editor. Keep clip rename
reachable. Prioritize visible thumbnails with bounded caching/concurrency and
cancellation. Preserve pass-1 sheets, loading/cancel and preview geometry.

## Pass 3 scope — source integrated

Caption body movement and visible-edge resizing, exact translation versus explicit
word-interval scaling, clip/trim/precision and overlap checks, transient proposal/
frame audition and one validated undoable/autosaved commit per completed gesture.
Cancelled/rejected/interrupted gestures do not publish timing. Protect expected
cue/word/clip state and recheck current overlaps at release. Retain hidden original
trim portions, expose their original timing through the sheet, support edge-scroll
and VoiceOver retiming. Keep scroll/pinch/tap/drag ownership and teardown coherent.
No new clip sequencing, transitions, music tracks or automatic next phase.

All three passes are source-integrated, not compiled or accepted on device.

Read current DESIGN/ARCHITECTURE plus the handoff. No builds/typechecks/tests,
fixtures, CI/generation, model downloads, native processing, UI/device execution or
deployment. User validates afterward. No schema, Mac, commerce or speech change.

