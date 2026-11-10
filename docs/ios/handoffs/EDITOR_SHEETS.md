# Direct editor and sheets — passes 1–3

2026-10-28. Base develop a4cc21b8d795c59dd72a9929076bcde46b12a984;
feat/ios-editor-sheets → develop. One PR, left open with auto-merge disabled.

## Pass 3 — source-integrated

Extends PR #49 head 014ad963cd6e2d1fb642214d0009c8e7a5c44354.

- [x] Reorder mode with native drag handles, local stable-ID ordering, Cancel/Save,
  accessible Move earlier/later, no seek/rename/remove conflicts while arranging,
  selected-row identity/reveal and stale-project rejection.
- [x] One expected-state permutation and one atomic revision/history entry on Save;
  unchanged/cancelled/invalid/stale orders publish no structural edit. Existing
  session/transcription admission/writer and original ownership remain in use.
- [x] Contiguous media positions and exact clip-relative native/manual caption shifts;
  chronological native cues/words/manual phrases, settings/name identity, genuine
  source anchors/raw windows and remapped accepted transcription coverage retained.
- [x] Existing global trim keeps its start/end clock positions, with disclosure that
  reordered footage inside can change. Older gapped graphs compact and trim clamps
  only when required to retain a valid positive range. No per-clip trim is introduced.
- [x] Existing media/audio/MP4/SRT consumers read the same reordered project graph;
  playhead/scope/timeline labels, derived frames and library artwork refresh through
  existing structural adoption. Frozen completed/queued exports are unchanged.
- [x] Structural Undo/Redo admission follows active transcription/authorization;
  labels identify add/remove/reorder. Later incompatible inference is not overwritten.
- [x] Shared append/remove/reorder caption projection; unused ClipStrip UI removed,
  retained thumbnail/name helpers moved to ClipThumbnail.swift.
- [x] Background export-artwork leases still pin exact immutable files against deletion,
  but do not disable Export/Queue sheet dismissal. User preview/save/share leases keep
  the existing dismissal protections. Toolbar-only Export entry remains intact.
- [x] Current entry-point docs consolidated around the final three-pass implementation.

All requested passes have source integration. No runtime/device acceptance is claimed.

## Pass 2 — source-integrated

Extends PR #49 head 6727a94bef363db08ec6d11cf575beb9d88adc44.

- [x] Local AddClipsSheet with ordered Photos/Files selections, metadata/thumbnails,
  per-selection failures/retry/removal, direct HTTPS rights confirmation, cancellation
  and unpublished inspected staging. It does not mutate Home’s importer or create a
  temporary project. Cancelled/unprepared Photos items remain explicit before Add.
- [x] One atomic append to the existing canvas/defaults; partial files remain unpublished
  on failure. Keep Clips open and reveal added rows. No automatic transcription.
- [x] Confirmed removal, one-clip minimum, project-clock gap closure, retained settings,
  genuine raw/native anchors and exact native/manual cue translation. Remove only the
  selected clip’s canonical caption/settings references; keep original files for Undo.
- [x] Explicit end-trim expansion on Add and start-trim preservation; removal collapses
  boundaries and resets to full remaining clips only if the visible range disappears.
  Both behaviors are explained before the relevant action.
- [x] Shared session flushes prior edits, admits the final structural transaction through
  TranscriptionController, checks the exact saved base and publishes one new revision.
  Copy/download does not hold that admission lock. Active project transcription blocks
  structural commits; existing frozen export work remains independent and unchanged.
- [x] Expected-state structural Undo/Redo uses the same durable path and bounded history.
  Undo does not overwrite later inference; incompatible structural entries are disabled.
  Source files remain available for redo/history. Original deletion is not automatic.
- [x] Schema 11 reads 1–10. Current accepted coverage is reindexed by stable clip/core,
  native anchors remain unchanged, and a fresh operation ID excludes stale terminal
  jobs/charged reservations. Free reservations count unresolved audio cores only;
  existing ledger/reservations and the 30-minute policy are retained.
- [x] Completed pre-coverage clips can carry accepted raw/words without fabricated
  checkpoint entries; optional coverage fields validate against real clip/window plans.
  Duplication and resume/publication/gap display support those retained identities.
- [x] Obsolete inactive resume sidecars/artwork are invalidated after publication.
  Preview/timeline, playhead/scope, library metadata/artwork and storage refresh on
  append, removal and structural history. Artwork publication checks the saved revision.
- [x] Pass-1 routes/sheets/toolbar-only Export, native recognition, renderer, shared active
  engine/model, purchase rules, Home organization, Mac and frozen output contracts retained.

Source review only; no compilation or runtime acceptance claimed.

## Pass 1 — retained source checklist

- [x] ProjectEditorDestination directly hosts ProjectEditorView; the intermediate
  overview and its duplicate preview/actions/name sheet are removed.
- [x] Existing editor owns opening cancellation, session attach/detach, save flush,
  rename-on-open and failures. Library/Recent/import/Queue routes keep project IDs.
- [x] Plain ellipsis, 44-point menu target, Project info with basic metadata,
  originals/relink and per-project storage. Only the exact rebuildable library
  thumbnail can be cleared, with confirmation; project data/outputs are retained.
- [x] Large Clips sheet from the bottom bar and Clip N of M header, initial row
  reveal/highlight, select/seek, thumbnail/duration/name/missing-original state.
- [x] Existing clip rename now belongs to the Clips sheet's swipe/context/accessible
  action and nested cancellable Save/Cancel sheet. Outside-trim rows retain rename.
- [x] Frame labels use original project-order numbers even when earlier clips are
  excluded by project trim; actual media/clip names/IDs remain unchanged.
- [x] Existing Export sheet owns configuration, current/queued work and completed
  MP4/SRT inventory. No duplicate current progress or repeated completed-file panel.
- [x] Retained results stay newest first, revision-aware, previewable/saveable/shareable
  and explicitly deletable using existing delivery leases and frozen outputs.
  Export settings can be reused in-place with the current Pro admission policy.
- [x] Toolbar is the sole ExportView entry. Bottom bar contains Clips and editing
  tools; there is no extra Export action or intermediate export screen.
- [x] New sheets use existing modal suspension and stable player sizing. No schema,
  speech, queue worker, renderer, purchase, Home organization or Mac change.
- [x] Current scope, design, architecture, feature and workflow records updated.

## Ownership

ProjectEditorDestination acquires one app-owned session and hosts the editor.
ProjectEditorView owns preparation, modal entry points, selected timeline context,
Project info, native original relinking and the one toolbar Export entry.
ProjectClipsSheet owns the clip list and existing nested rename UI; it never opens
another editor/session. ProjectStorageSection obtains targeted repository accounting
and exposes confirmed thumbnail-only cleanup through ProjectsModel.
ProjectExportsSection emits native Form sections inside ExportView; each immutable
result retains its existing ExportResultView and explicit local-delete behavior.
ProjectTimelineSnapshot generates short display labels only; clocks/identity stay intact.

## Source completion and validation

Adding/removing clips and drag reordering are source-integrated. The old unused
ClipStrip UI is removed; shared thumbnails/name helpers live in ClipThumbnail.swift.

Source review only. No builds/typechecks/tests/fixtures, CI, generation/models,
native processing/exports, UI/device/accessibility execution or deployment.
Compilation and physical-device acceptance are unverified. In particular, modal
stack dismissal, clip-row reveal, small-phone layout, real file preview/delivery,
failed saves/relink, storage refresh and opening cancellation need owner validation.
The partial local review snapshot is not a publishable root tree/history: publish
only changed blobs/deletion onto the full verified remote develop tree.

## Pass-2 ownership and limits

MediaImporter now separates inspected staging from new-project publication; append
reuses the bounded copy/hash/inspection and direct-URL download path. AddClipsSheet
owns its transient picker/review state and never instantiates another engine/model.
ClipGraphEdit owns portable graph/value transformations; ProjectRepository owns
expected-base checks, owned-file adoption and the sole atomic structural publication.
EditorSession owns admission, history, saved-state adoption and preview invalidation.

Only currently referenced assets remain in the document; removed original files remain
inside the project package for Undo. They are counted in project storage and are not
silently purged when history ages out. Missing originals can prevent Undo that needs
those files; failure leaves the current graph intact. Structural history is in memory,
like existing editor history, and is not promised across app termination.

Schema 11 is a format boundary; older builds reject newer project documents. There is
no migration job, original-model UI, new engine, network backend or rendering pipeline.
Actual media/frame/Photos/file-provider behavior, disk-full/crash boundaries, source
relink/Undo, real MP4/SRT parity, strict-concurrency compilation and SE2 memory/layout
remain owner acceptance. Source integration is not runtime/production evidence.

## Final source review and runtime boundary

Source/call-site/diff/whitespace and publication consistency checks only. No Swift
compilation/typechecking, tests/fixtures, CI, generation, model downloads, native
media/export processing, UI/device/accessibility execution or deployment ran.
Drag/drop behavior, cancellation, VoiceOver, small-phone layout, thermal/memory,
provider/Photos/delivery, disk-full/crash recovery and actual MP4/SRT/audio parity
remain owner validation. Schema remains 11; wrappers and all Mac/shared-package
files remain unchanged. Keep PR #49 open without auto-merge.

## Owner CI follow-up — 2026-10-28

Owner-run bybydev/example Build Release #63 (run 40626240371), at PR head
`a6450abb`, failed the iOS archive with two Swift expression typechecking timeouts
in `ClipGraphState.estimatedBytes` (ClipGraphEdit.swift lines 28 and 32). Replace
the nested optional/reduce sum and chained return expression with an explicit Int
accumulator, bounded per-token/per-segment additions and separate optional counts.
All existing size weights and counted values remain the same; history budgeting
and project behavior are unchanged. This is a source fix in PR #49, not evidence
of a successful archive. Source/diff/whitespace and remote publication checks only;
no agent builds/typechecks/tests or CI dispatch/retry were run. Owner reruns CI
against the updated PR head.

Owner rerun Build Release #64 (run 40627336846), at `41f54bcb`, passed the
previous expression typechecking point and reported an exclusive-access conflict
in append's optional trim assignment. Compute the expanded MediaInterval before
mutating `copy.mediaEdits`, so reading the computed source duration finishes before
the nested write begins. Add's existing start-preserving/end-expanding behavior is
unchanged. Reviewed the other structural trim writes: removal/reorder already
compute their end values before assignment. Source/diff/publication checks only;
no agent compilation or CI rerun. A successful archive remains unverified.

---

## Approved scope — archived brief (consolidated 2026-11-07)


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

