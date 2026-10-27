# Add missing caption — focused feature

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
