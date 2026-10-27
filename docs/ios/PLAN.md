# Inkribe iOS — current plan

2026-10-27 — Issue #47, timeline editor **passes 1–3 source-integrated** in
PR #48, `feat/ios-timeline-editor` → develop. Pass 3 extends head `95628a7`.
The fixed editor includes real multi-clip frame/caption tracks, ruler, center
playhead, scrubbing/playback, anchored zoom, selection and caption move/resize.
Drag a selected block or its edge handles; hold any block to select/move it.
A temporary block/readout and frame audition precede one validated undoable commit
on release. Cancel/interruption does not publish the proposed timing. Existing
native intervals stay immutable; moved words translate and resized words scale.
Sheets, preview geometry, cancellable opening, cache/queue/Pro contracts remain.
See [scope](phases/TIMELINE_EDITOR.md) and [source handoff](handoffs/TIMELINE_EDITOR.md).
Keep PR #48 open without auto-merge. Source review only; compilation and native
acceptance are unverified. Existing no-build/test/CI/UI/device restrictions remain.


2026-10-26 update: current work is **Add missing caption**, branch
`feat/ios-manual-captions` → develop, based on f0eb80c (merged #43).
See [scope](phases/MANUAL_CAPTIONS.md) and [marked handoff](handoffs/MANUAL_CAPTIONS.md).
Manual phrases are separate project data; schema 10 reads 1–9. Native recognition,
working styles, Mac behavior and existing wrappers are preserved. Source-only
review; compilation/device/output acceptance pending. Keep the new PR open with
no auto-merge. Earlier current-phase entries below describe completed history.


2026-10-26 update: current work is the approved animated Styles sheet in
`feat/ios-animated-style-sheet` → develop, based on 81b8207 (merged #42).
See [source checklist and pending acceptance](handoffs/ANIMATED_STYLES.md).
Keep the PR open. Source-only checks; all existing execution restrictions remain.
Earlier phase descriptions below are completed history.

2026-10-24. Expanded Pass 1 of #40 is tracked by #41. The user authorized all source
implementation in one new PR from develop 4a9780f, left open targeting develop.

| Work | Source status |
|---|---|
| One-project creation | Photos/Files/direct URL; review/remove/order; failed-item handling; atomic single project |
| Project details/editor | Shared session; combined preview; clip strip/transcript groups; explicit entry points |
| Defaults/overrides | Sparse caption/framing/audio patches; section/all inheritance reset; bounded undo; preview/export wiring |
| Project exports | Existing durable inventory; in-place/queued generation; real-file preview and native delivery |
| Saving/consolidation | Existing atomic writer/error retention across routes; docs and eight unrun regression specifications |

All rows are source-integrated, **not compiled or accepted on device**. Exact files,
limits and pending user scenarios are in [the marked handoff](handoffs/PROJECT_EXPERIENCE.md).

## Product contracts

New Project always creates one project with one/multiple ordered files. No separate
projects option. Project defaults update inheriting fields; explicit clip overrides
remain. Reset removes overrides without touching text, timing, original media or trim.
Output aspect, resolution and existing 30fps stay project/output-wide.

Both export entry points capture the saved document and use the same durable queue,
worker and resource gate. Export now follows progress in-place; it does not bypass
accepted work, user pause or foreground requirements. Completed files share one
project export collection and remain immutable after later edits.

Keep the approved Free/Pro rules and pricing. Existing saved premium work survives
expiry; no new watermark, trial, backend quota or product is introduced. Canonical
schema 9 reads 1–8; no migration job or editor-sidecar workflow is added.

## Remaining parent passes

#40 Pass 2: deeper transcription/queue reliability. Pass 3: manual missing captions
and correction/style quality. Pass 4: output/audio/timing parity and delivery acceptance.
Pass 5: first-use, accessibility, commerce and supported-iPhone performance acceptance.
Do not automatically start another pass. Metadata remains excluded.

No post-creation sequencing, new per-clip trim, transitions, multitrack, accounts,
cloud inference/sync, dubbing/translation, share extension, iPad or Mac expansion.
Existing model packaging policy remains unchanged. See [readiness](PRODUCTION_READINESS.md).
