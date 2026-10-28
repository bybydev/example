# Direct editor and project sheets

2026-10-28. User-authorized passes 1–3 in existing PR #49, from develop a4cc21b targeting
develop on feat/ios-editor-sheets. Pass 3 extends 014ad963 after pass 2 (6727a94). Keep open without auto-merge. V1.PROJECTS,
V1.RENAME, V1.IMPORT, V1.UNDO, V1.STORAGE, V1.EXPORT_JOB and V1.DELIVERY.

## Pass 1

- Open every project directly in the existing four-area timeline editor, including
  Recent Project, creation completion, Queue and rename routes. Remove the former
  intermediate ProjectDetailView. Retain cancellation, writer/history and session ownership.
- Project info is in the plain ellipsis toolbar menu: title, duration, clip count,
  canvas, created/modified dates, original media, missing-original relinking,
  project storage breakdown and confirmed project-only library-thumbnail cleanup.
- A dedicated large Clips sheet opens from the bottom Clips action or the timeline
  header's Clip N of M chevron. Reveal/highlight the selected row. Existing clip
  selection and rename remain available, including rename of clips outside trim.
- Timeline frame labels use Clip N in full project playback order. Remove timeline
  rename menus and the editor menu's separate single-clip rename action. Saved
  clip names remain in the Clips sheet and existing focused settings inspectors.
- Move completed MP4/SRT inventory, export activity, freshness, real-file preview,
  Photos/Files/Share and confirmed deletion into the existing large Export sheet.
  Retain configuration, Export now, Queue export, durable jobs and progress.
  Reusing settings stays within that sheet and rechecks the existing Pro gate.
- Only the toolbar Export button opens ExportView. Remove the bottom Export action.
  Existing cross-project Queue delivery remains available independently.
- Preserve fixed preview geometry and suspend timeline gestures/frames under all
  sheets. Preserve raw/native timing and IDs, clips/media, trims, schema 10,
  shared speech engine, allowance/Pro, frozen outputs, Home organization and Mac.

## Pass 2 — clip management

- Add clips through a dedicated local Photos/Files/direct-HTTPS picker/review flow.
  Keep selection order, report failed Photos/media checks, retry/remove failed picks,
  preserve prepared successes, support cancellation, and publish all selections or none.
  Do not use Home’s mutable New Project selection or create an intermediate project.
- Append to the existing canvas/defaults. Keep Clips open and reveal/highlight added
  rows. Transcription remains an explicit existing action; accepted captions are reused.
- Confirm removal, keep one clip minimum, close the removed interval, preserve all
  retained native IDs/source intervals/raw windows/edits/styles and translate project
  caption/manual timings exactly. Keep original files for structural Undo.
- Preserve start trim and expand explicit end trim when adding, disclosed in Add.
  Collapse trim boundaries on removal; if no visible range survives, show remaining
  clips in full, disclosed in confirmation.
- Flush existing edits first; use expected document/graph state and the existing
  serialized repository. Stage new originals before one atomic graph publication;
  failed/cancelled preparation never publishes a subset. Only the final transaction
  takes transcription admission; active project transcription requires finish/cancel.
  Running/queued exports keep their independent frozen inputs.
- Structural Undo/Redo is bounded, durable and expected-state checked. Later inference
  makes incompatible structural history unavailable rather than erasing new captions.
  Normal caption/settings writes retain the existing narrow immutable-source rules.
- Schema 11 reads 1–10. Reindex canonical accepted windows by clip/core, use a fresh
  recognition operation identity after structural edits, invalidate obsolete sidecars,
  and reserve only unresolved audio cores. Optional retained-complete legacy clips
  carry existing accepted captions without invented raw windows or word timing.
- Refresh preview/timeline, selection, library artwork/counts and scoped storage after
  append/removal/structural history. Reject late artwork for another project revision.

## Pass 3 — reorder and consolidation

- Native List drag handles in explicit Reorder mode within the same large Clips
  sheet. Capture stable clip IDs and expected graph, edit order locally, support
  Cancel and Save, and publish one undoable/durable transaction. Same-order Save,
  invalid permutations and stale graphs never publish new history/revisions.
- Preserve each clip’s source interval, identity, raw/native word anchors, caption
  text/timing offsets, manual phrases, names and settings. Rebuild contiguous
  project-clock positions, chronological cue/word/manual projections and accepted
  window indices. Existing preview/media/audio/SRT use this same new graph.
- Project trim keeps its absolute start/end positions, disclosed in Reorder; the
  footage inside can change. Compact historical gaps and clamp an invalid older
  trim if necessary. Do not invent per-clip trimming or silently discard media.
- Keep stable selection/playhead, numbered labels, current row reveal, failed-save
  handling, admission and expected-state Undo/Redo. Structural history is unavailable
  while transcription/admission is active or later inference changed its expected graph.
- Consolidate append/remove/reorder caption projection, remove unused ClipStrip UI,
  distinguish background artwork leases from user delivery for sheet dismissal, and
  retain all per-file deletion protection. Keep toolbar-only Export presentation.
- Consolidate current scope/design/architecture/feature/workflow/source handoff.
  All three passes are source-integrated; do not claim compilation or device acceptance.

No builds/typechecks/tests/fixtures, CI setup/triggers/runs, generation/models,
native media processing/exports, UI/device/accessibility execution or deployment.
Source/call-site/diff/whitespace and publication checks only; user validates afterward.
