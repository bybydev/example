# Inkribe iOS — start here

2026-10-28. PR #50 also removes the timeline's outer side gutters: ruler/tracks
span the editor width; preview, controls, labels and prompts keep 12-point insets.
Centered-playhead scroll space is preserved. Source-only; device layout unverified.

2026-10-28. Current work in PR #50: Free dark **Graphite**, immediately after
Paper, with accent #279ED2, translucent panels and layered charcoal/blue lighting
following the user's confirmed revision to match Midnight's depth. Paper remains the
default; other themes stay Pro. [Source handoff](handoffs/GRAPHITE_THEME.md).
PR #51's preview fix is squash merged into #50 as 35b29af after the user reported
it working. Keep #50 open without auto-merge; source-only checks remain in force.
Earlier stacked-PR status below is historical.

2026-10-28. Current work: preserve preview frames during sheet/player handoffs in
`fix/ios-preview-handoff`, stacked on PR #50 (`5c9f9eb`) and targeting
`feat/ios-contextual-caption-editor`. Covered hosts keep a still with its caption
clock/snapshot; live video returns after layer readiness. The single session player,
all #50 caption flows and preview dimensions remain. Source integration only;
compilation/device acceptance is unverified. See [scope](phases/PREVIEW_HANDOFF.md)
and [handoff](handoffs/PREVIEW_HANDOFF.md). Keep both PRs open without auto-merge.

2026-10-28. Current work is the contextual caption editor, based on develop
`ba5b422`, in a new PR targeting develop. The bottom Timing action is removed.
Second-tap a selected timeline caption, or use the selected row's top-left Edit
caption in Captions, to open the editor. It has no playback controls. Captions pushes it in its own
navigation stack; Back or Done returns to the same list. Timeline entry stays a
sheet whose Done returns paused 0.25 seconds before the edited caption (clamped
to zero), retaining selection.
Captions has a bounded video preview and play/pause/Undo/Redo above its scrollable
list, with no scrubber/timeline. The current playback row is always highlighted;
playback does not select rows or automatically scroll the list.
Tapping row text still selects/highlights/seeks. Caption text in the list is read-only;
only Edit caption pushes editing. There is no Split / Words or inline text field.
See [scope](phases/CONTEXTUAL_CAPTION_EDITOR.md) and
[source handoff](handoffs/CONTEXTUAL_CAPTION_EDITOR.md). Other consolidation waits
for a separate user signal. The earlier sheet passes below are merged in the base.

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
