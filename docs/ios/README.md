# Inkribe iOS — start here

2026-10-28. PR #49 (`feat/ios-editor-sheets` → develop) contains source integration
for all three approved project-sheet passes, through pass 3 based on `014ad963`.
Keep the PR open without auto-merge. Compilation/device acceptance is unverified.

Projects open directly in the fixed player → controls → timeline → bottom-actions
editor. Project info in the plain ellipsis menu handles metadata, originals/relink
and storage. Clips opens from the bottom action or numbered timeline header and
supports Photos/Files/URL append, rename, confirmed removal and native drag reorder.
Reorder is local until Save, with Cancel and one durable undoable change.

Only toolbar Export opens the existing Export sheet, which owns configuration,
progress, completed MP4/SRT files, preview/save/share and local deletion. Original
files and frozen outputs remain independent from later project changes.

Schema 11 reads 1–10. Keep genuine native/source anchors, accepted partial captions,
clip settings, shared active engine/model, 30-minute Free policy and Mac behavior.
Adding/reordering clips does not start transcription. Current global trim is a
clock window; reordering can change which footage falls inside it.

Read [scope](phases/EDITOR_SHEETS.md), [marked source handoff](handoffs/EDITOR_SHEETS.md),
[plan](PLAN.md), [features](FEATURES.md), [workflow](WORKFLOW.md), [architecture](ARCHITECTURE.md)
and [design](DESIGN.md). Root AGENTS.md and the latest user request control scope.
Previous phase evidence remains in linked handoffs and the archive.

Source-only: no builds/typechecks/tests/fixtures, CI, generation/models, native
processing/exports, UI/device/accessibility execution or deployment. Source
completion is not production validation. [Readiness](PRODUCTION_READINESS.md)
retains the unverified runtime/release gates.
