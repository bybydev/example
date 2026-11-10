# Manual captions — marked handoff

2026-10-26. feat/ios-manual-captions → develop, based on f0eb80c (#43).
Keep the PR open without auto-merge. Remaining #40 passes stay separate.

## Source implementation

- [x] Add in Captions even without recognition, and beside unfinished ranges.
- [x] Large sheet with clip selection, text, shared player/scrubbing, exact start/end
  and independent playhead shortcuts. Preserve parent layout/scroll/expanded state.
- [x] ManualCaption stores stable ID, clip ID, text and original-project interval;
  schema 10 reads 1–9. Validate bounds, IDs, limits and visible manual overlaps.
- [x] CaptionUnit adapts native words and manual phrases for display/rendering only.
  Native CaptionWord/Recognition fields, decoder and raw/checkpoint anchors stay
  unchanged. Manual provenance never enables invented word-timed motion.
- [x] Correction, hiding, deletion, selection repair and bounded undo/redo, including
  text coalescing, use the existing shared session.
- [x] Existing serialized atomic writer retains failed work in memory; narrow speech
  rebase requires unchanged manual fields. Append-only publication preserves manual
  edits and history; unrelated concurrent manual edits remain conflicts.
- [x] Duplication remaps manual/clip IDs; library recognizes manual-only projects.
  Such projects can still request transcription. Manual input never charges usage.
- [x] Shared snapshot owns styles/trim/overlaps for preview, MP4 and chronological
  SRT. Frozen manifests capture manual data without altering existing wrappers.
- [x] Explicit overlap warning at creation, editor review of retained native text,
  Edit/Remove manual actions and export warning. Retry-created overlaps are visible.
- [x] Source/call-site/diff/whitespace review. See final PR for published commit.

## Deliberate limits

Manual phrases have phrase timing, not per-word inference or mixed native merges.
A visible manual phrase replaces an entire overlapping native cue, including text
outside its interval. Add & replace warns; review lists the native text. Removing
or hiding the manual phrase restores underlying cues. Retry may introduce new
review items without overwriting manual work. Unfinished transcription rows remain
because manual input does not mark native windows complete or settle allowance.

The Add sheet previews existing saved captions while locating speech. New text
appears in the project preview after Add; dismissal cancels unadded input. No new
draft/recovery workflow. Schema-10 metadata must not be downgraded by older builds.

## Acceptance pending

**No compilation/typecheck, automated tests, fixtures, CI runs, UI/device checks,
real recognition/exports or performance measurements were performed.** These are
regression specifications, not executed/passing tests:

- [ ] Empty/never-transcribed/failed-speech project: add, reopen, SRT and MP4 without
  a model. Recognition stays nil and usage remains unchanged.
- [ ] Add from a clip-2 missing range; set separate start/end playheads, correct
  text, and verify clip binding, chronological list and both output formats.
- [ ] Trim on non-millisecond rational boundaries; accept unchanged defaults and
  exact playhead bounds. Compare persisted original vs zero-based output times.
- [ ] Reject negative/nonfinite/reversed/out-of-clip/cross-clip ranges, empty creation,
  oversized text, duplicate identities and visible manual overlaps; allow adjacency.
- [ ] Text/timing/hide/delete and undo/redo preserve IDs/raw recognition. Undo typing
  groups independently; do not coalesce Add with its subsequent text correction.
- [ ] Retry/append while a manual edit is unsaved or its writer is suspended. Keep
  latest manual text/times, accepted native edits, history and correct revisions.
- [ ] Retry introduces overlap: review native text/time; compare preview/MP4/SRT;
  remove manual to restore native and undo to restore manual. An overlap wholly
  outside trim must not suppress retained text.
- [ ] Concurrent manual edit from another owner remains a conflict. Save failure
  retains work across navigation and successful retry; relaunch uses last saved data.
- [ ] Duplicate multi-clip work, remap IDs, preserve text/times/styles and physical
  originals. Renames/settings resets must not change manual data.
- [ ] Freeze output, edit/delete manual text, then render old/new requests. Each
  output retains its own document and delivery after project edits/deletion.
- [ ] SE2, larger iPhone, large Dynamic Type, VoiceOver and keyboard: wrapping header,
  both gap actions, one player, native dismissal and no parent preview/layout jump.
  Closing/backgrounding the sheet pauses playback.
- [ ] All ten looks with Vietnamese, emoji, long text and trim through a phrase;
  manual motion is phrase-timed and matches preview/output without fake word timing.

Source integration does not establish production readiness.


## Same-PR follow-up — free allowance

2026-10-26: raised Free to 30 captioning minutes/week (1,800 seconds), with Pro
unlimited. One Commerce.weeklyMinutes value now drives the gate and all numeric
comparison/summary/upsell copy. Existing usage, reservations, weekly reset and
charge/retry semantics are preserved; no ledger reset or migration is needed.


## Same-PR follow-up — one shared speech engine and active model

2026-10-26. The user's final contract replaces per-job model selection:

- Settings alone exposes the active model and its name. A different installed
  model requires confirmation before any work is cancelled; dismissing keeps all
  work and the active model unchanged.
- One SpeechEngine owns the active preference, retained NativeWhisperRuntime and
  store lease. Consecutive jobs share that context. Model switching or a failed/
  cancelled context unloads it before another context can be created.
- Confirmed switching closes speech admission, invalidates speech preparations
  suspended across awaits, pauses/cancels queued/running transcription plus model
  downloads, and waits for speech teardown. Export preparation, queued/running
  exports and export controls remain unaffected; switching does not wait for them.
  Speech cancellation storage failures abort activation; the previous active
  preference stays in place.
- The previous engine is unloaded before the active preference changes. Processing
  keeps the user's prior pause/foreground state. Cancelled jobs stay cancelled
  until the user explicitly retries; saved captions and completed exports remain.
- New/restored/resumed jobs use the active engine. New payloads omit modelID; old
  optional modelID fields remain readable but never choose an engine. No Small
  fallback or original-model requirement remains in job execution or resume UI.
- Accepted raw windows, stable IDs, word timing, corrections, manual captions and
  bounded history survive cross-model resume. Only unresolved ranges infer with
  the active model. Mapping/runtime/source/language compatibility remains checked.
  Recognition/checkpoint model ID/SHA describe the latest attempt, not a lock or
  a claim that earlier retained windows came from the current model.
- Existing project/job/checkpoint wrappers, model packaging, 30-minute allowance,
  Mac runtime and purchases remain intact. Source/call-site/whitespace review only.

---

## Approved scope — archived brief (consolidated 2026-11-07)


Authorized 2026-10-26: one new PR from develop f0eb80c, branch
feat/ios-manual-captions, targeting develop and left open without auto-merge.
This is the manual-authoring slice of #40 Pass 3, not the entire remaining roadmap.

## Product contract

- Add caption in Captions, including never-transcribed/empty projects, and beside
  unfinished transcription ranges. Preserve the visible Retry action.
- A large native sheet offers shared footage/playback/scrubbing, clip selection,
  text, start/end seconds and independent Set at playhead actions.
- Input uses the output clock; storage uses exact original-project timing inside
  one clip. An unchanged boundary or playhead choice retains rational precision.
- ManualCaption is separate user-authored project data. A phrase has user timing;
  it creates no native anchors, word boundaries, model result or speech charge.
- Integrate text/timing correction, hiding, deletion, bounded undo/redo, atomic
  saving/reopen, duplication, clip styles, trim, preview, MP4 and SRT.
- Retain manual work during transcription retry/publication and concurrent saves.
  Frozen outputs retain their own version of manual captions.

## Overlaps and limits

Visible manual phrases cannot overlap one another. Adjacent half-open intervals
are valid; hidden phrases do not replace native captions. A visible manual phrase
replaces the **whole** overlapping recognized cue in preview and output, including
native text outside the manual interval. Creation warns and uses Add & replace.
The editor lists replaced native text/times and offers Edit manual / Remove manual;
export repeats the warning. Later retries use this same policy. Native recognition
stays saved; removing, hiding or retiming manual text restores cues it no longer
replaces. Manual coverage does not mark recognition windows complete.

Manual phrases have no native split/word controls or mixed native/manual merge.
Create separate phrases instead. Limit: 10,000 phrases/project, 4,096 characters
per phrase. Creation requires non-whitespace text; correction may hide a phrase.

Schema 10 reads 1–9, adding optional manualCaptions. Do not downgrade newer saved
projects/requests in place. Package/job/checkpoint/export wrappers and Mac remain
unchanged. This is free editing under the existing access contract.

No builds/typechecks/tests/fixtures, CI/generation/models, native inference/exports,
UI/device execution or deployment. Source review only; actual acceptance pending.
See [marked handoff](../handoffs/MANUAL_CAPTIONS.md).

