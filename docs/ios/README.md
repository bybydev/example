# Inkribe iOS — start here

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

2026-10-24. Current work is expanded Pass 1, issue #41 (parent #40), in
`feat/ios-pass1-project-experience` → develop. Base 4a9780f includes merged #39.
Leave the new PR open without auto-merge.

The iPhone app uses one project per creation, containing one or ordered multiple
files. Project details opens the shared scrolling editor, project-default/clip
settings and retained exports. Canonical schema 9 reads 1–8; package/queue wrappers,
working transcription and Mac source/config remain intact.

**Source-integrated and reviewed; compilation and production acceptance pending.**
No builds/typechecks/tests/fixtures, CI, generation, model downloads, native
processing/exports, UI/device/accessibility execution or deployment ran.

- [Current phase](phases/PROJECT_EXPERIENCE.md), [detailed marked handoff](handoffs/PROJECT_EXPERIENCE.md)
- [Plan](PLAN.md), [feature ledger](FEATURES.md), [workflow](WORKFLOW.md), root AGENTS.md
- [Architecture](ARCHITECTURE.md), [design](DESIGN.md), [handoff](HANDOFF.md)
- [Production readiness](PRODUCTION_READINESS.md) and [model policy](MODELS.md)
- [Earlier consolidation](CONSOLIDATION.md), [historical records](archive/before-consolidation/README.md)

Preserve confirmed successful caption quality, partial publication, genuine native
intervals/IDs, corrections, undo, allowance and independent outputs. Source completion
never substitutes for actual device/output acceptance.
