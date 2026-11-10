# Timeline clip trimming — source handoff

2026-10-31. feat/ios-timeline-clip-trimming -> feat/ios-media-form, stacked on
PR #55 at 381b0d2b. [Approved scope](CLIP_TRIMMING.md).

- [x] Timeline clip selection reveals start/end handles. Clip pan recognition is
  separate from caption timing; normal body scrolling/pinch remains available.
  Tapping a timeline clip preserves the playhead; Clips-sheet navigation still
  seeks to the selected clip's start.
  Edge scrolling and continued adjustment beyond a viewport boundary are bounded
  by the original footage. Short/empty selected clips have separate handle targets.
- [x] Transient handle/dimmed-exclusion feedback and source/length readout. Drag
  candidates are frame-sized rational offsets without rounding untouched values.
- [x] Main-preview boundary audition via TimelineClipTrimPreview and the existing
  CaptionPreviewFrame/shared composition. One serial worker coalesces requests,
  cancels stale work, retains the previous image and never creates another player.
  Native source decode, applied framing and matching caption clocks share the graph.
- [x] Save on release, compare the immutable graph/trim state, flush prior edits,
  validate and commit atomically before adoption. One bounded clipTrim Undo entry;
  failure/no-op/cancellation does not adopt an edit. Pause near the final boundary.
- [x] Cover/background/resize/second touch/teardown cancels active gestures and
  frame work. Session mutation/history/export capture is excluded during a gesture
  or its final save; append-only speech remains handled by the existing repository.
- [x] Remove all Media trim controls and keep its remaining scope/form behavior.
  Media draft saves preserve both compatibility project trim and new clip trims.
- [x] Schema 13 reads 1–12. Source endpoints are validated against original clip
  bounds. Original graph/native/manual captions/raw windows/coverage stay canonical.
- [x] One piecewise rational output map for preview/MP4/audio, captions/words/gaps,
  SRT, timeline frames, duration and forward/inverse seeking. At clip joins a manual
  caption's ending inverse uses the preceding interval; caption-edge timing uses
  the actual retained clip bounds and captures the entire map for stale checks.
- [x] Preserve legacy project trims without read-time writes. Freeze old clip
  exclusions before editing a legacy window; contiguous projects clear the
  redundant window so reordering retains their clip trims. Gapped legacy projects
  retain their exact old gap boundaries. Keep hidden clip identities/settings.
  Select a hidden clip in Clips to restore it with timeline handles.
- [x] Undo/Redo stores trim-only state without replacing names/styles/recognition.
  Existing duplicate/remap and structural settings preservation keep source trims.
  Existing frozen exports/completed files remain independent; new exports use the
  saved map, and music loop/fades resolve against the new output duration.
- [x] Source/call-site/filename/diff/whitespace and publication consistency review.

No builds/typechecks/tests/fixtures, CI, project generation, model downloads,
native decode/playback/render/export or UI/device execution ran. Compilation,
actual drag arbitration/edge scrolling/VoiceOver, rendered frames/captions/audio,
disk failure behavior and device performance remain unverified. Keep both PRs
open without auto-merge; do not merge or start another feature automatically.

---

## Approved scope — archived brief (consolidated 2026-11-07)


2026-10-31. The user explicitly requests the discussed feature in a stacked PR.
Base: PR #55 / feat/ios-media-form at 381b0d2b. Child branch:
feat/ios-timeline-clip-trimming, targeting feat/ios-media-form, not develop.
Keep parent and child open with auto-merge disabled. Do not modify the parent.

## Interface and transaction

- Select an existing video-lane clip to reveal accent-colored start/end handles.
  Drag either edge within the original source interval; later output closes up
  after a shortened clip. Restore hidden footage by dragging outward.
- Normal scrolling, pinch, captions, lane buttons and editor layout remain.
  Clip-edge drags take precedence only inside the selected edge's hit target.
- Show the boundary frame in the existing main preview with source-range and
  retained-duration feedback on the timeline. No media preview sheet or new player.
- Keep one serial, cancellable, bounded frame capture using the existing shared
  composition/frame helper. Keep the previous good frame during a request; editor
  loading indicators remain hidden. No temporary video or inference work.
- One completed gesture is one durable, expected-state clip-trim history entry.
  Cancel/second touch/cover/background/resize/teardown discards the proposal.
  Writes precede adoption; no-op/rejected/failed gestures do not publish history.
- Retain VoiceOver start/end adjustment actions and native clip selection.
- Remove trim fields, output-duration trim row and Reset trim from Media. Project
  Media retains canvas/master mute; clip Media retains framing/volume/resets.

## Data and output

- Schema 13 adds optional ClipSettings.sourceTrim endpoints in immutable source
  time. Nil means the full original clip; empty ranges retain clips wholly hidden
  by a legacy project trim. New gestures retain at least a frame-sized duration
  (or the original duration for a shorter clip).
- Never rewrite original clip intervals, source/native words, cue IDs, raw results,
  accepted speech coverage or manual captions. No trimming-triggered transcription
  or allowance changes. Caption timing stays canonical and maps at output time.
- OutputTimeline removes excluded clip portions with rational piecewise mapping.
  Preview/MP4, original audio, caption/word/gap projection, SRT, thumbnail samples,
  duration and seeking use that same map. Existing genuine gaps remain genuine gaps.
- Old project-wide trim windows remain readable and unchanged on opening. Before
  extending such a window, materialize its current clip exclusions so restoring
  one clip cannot reveal other hidden clips. Contiguous imported timelines then
  clear that redundant window, preserving clip trims across later reordering.
  Keep a compatibility window only for genuine legacy gap boundaries; users edit
  only clip handles.
- Fully hidden legacy clips remain selectable in Clips and expose a selected
  timeline marker with handles for restoration. Do not delete their source data.
- Music stays anchored on the project output clock; loop length/fades follow the
  resulting output duration. Existing frozen manifests/completed files do not change.
- Keep package/job/export wrapper versions, shared packages, engine/models, Pro,
  purchases, home, Mac, styles and all unrelated editor design unchanged.

Source review only. No builds/typechecks/tests/fixtures, CI runs, generation,
downloads, native decoding/playback/exports or UI/device execution by the agent.
Source completion is not compilation or device/runtime acceptance.

