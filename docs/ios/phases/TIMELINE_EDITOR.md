# Timeline editor — issue #47

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
