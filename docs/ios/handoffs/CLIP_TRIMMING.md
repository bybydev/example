# Timeline clip trimming — source handoff

2026-10-31. feat/ios-timeline-clip-trimming -> feat/ios-media-form, stacked on
PR #55 at 381b0d2b. [Approved scope](../phases/CLIP_TRIMMING.md).

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
