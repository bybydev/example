# Media Form — passes 1–2 source handoff

2026-10-31. feat/ios-media-form -> develop; baseline 4a9517bc.
The user's next-pass signal authorizes pass 2 in PR #55, extending bb0d1b11.
Both planned passes are source-complete; compilation/native/UI acceptance is unverified.
See [approved scope](../phases/MEDIA_FORM.md).

- [x] Dedicated MediaSheet large native themed Form; remove the old Media
  player/playback header, material card and redundant title/introductory text.
- [x] First-row Settings for menu changes the entire form between Project and
  numbered clips. Names remain in menu/accessibility/footer; no inheritance UI.
- [x] Project-only aspect ratio, original-clock trim, derived output duration,
  reset trim and independent original-audio master mute.
- [x] Clip-only Fit/Fill, expandable Zoom/Position/Volume and standard resets.
  Clip changes stay keyed to stable IDs and survive local scope switches.
- [x] One MediaDraft for every scope, with native timestamp preservation during
  initial editing and reset. No session/media/history writes from Form controls.
- [x] Cancel/swipe discards; Done validates source graph/media state, serializes
  against other session mutations, durably saves, adopts one settings history
  entry and refreshes the existing shared preview. Failed saves remain local.
- [x] Invalid trim returns to Project to expose the invalid fields. No-op Done
  does not normalize legacy documents or add a history entry.
- [x] A changed save resolves legacy project/clip values into explicit independent
  clip settings, retaining trim only at project media level. Names/caption fields,
  music, native clips/intervals and unrelated latest metadata are preserved.
  Existing readers/frozen outputs keep their current compatibility behavior.
- [x] Existing output-clock mapping preserves/clamps the playhead after trim.
  Main preview sizing, Style/Captions/Music and editor chrome are unchanged.
- [x] Source/call-site/diff/whitespace and remote-publication consistency review.
- [x] Pass 2 source integration review and scoped fixes.

## Pass 2 review matrix

| Area | Source evidence and result |
|---|---|
| Project/clip scope | First Form row changes the complete section set. The local scope never seeks or writes; even single-clip projects retain Project/Clip meaning. |
| Clip resets | Framing resets only fit/zoom/X/Y; volume resets only the selected clip's level. Both restore standard values, preserving mute/music and other clips. |
| Trim/no-op | Original rational endpoints survive untouched fields and Reset trim. Invalid bounds return to Project; unchanged resolved state creates no save/history/normalization. |
| Cancel/dismiss/late completion | Cancel closes the draft immediately; teardown closes it and cancels the owned save task. Closed/cancelled work fails before publication. Late task results cannot dismiss a later presentation. |
| Failed writes/stale edits | Graph/media expected-state gates preserve newer changes. Repository writes precede adoption/history; a failed write retains local values for retry or Cancel. |
| Preview preparation | Done no longer depends on preview readiness. Transaction admission invalidates old preparation generations; failed/no-op work restores interrupted preparation and success refreshes the saved graph. |
| Legacy values/settings rewrite | Index clip settings once and build/sort one replacement array, avoiding repeated scans/sorts. Preserve latest names/caption fields and every untouched clip's resolved media value. |
| History/playhead | One bounded settings history entry restores the exact old legacy or new explicit settings. Existing original/output mapping retains/clamps the playhead through trim Undo/Redo. |
| Reopen/duplicate/clip changes | Codable fields/schema 12 are unchanged. Repository duplication remaps settings IDs; append/remove/reorder retains the established clip/trim contracts. No read-time migration. |
| Speech publication | Media excludes session mutations while saving; the repository rebases only append-only speech. Tool-sheet dismissal now reconciles notifications excluded during that transaction, waiting for the scheduled graph rebuild so the unchanged graph can be reused. Forced teardown also reconciles after the save settles. |
| Preview/export/frozen files | PreviewComposition resolves the same per-clip framing/volume/master mute for preview and MP4. New manifests capture saved settings; existing frozen manifests/completed files remain independent. Music and native captions are preserved. |

Changes are confined to Media draft/sheet/save/dismissal integration and current
scope records. Approved layout, other editor tools, schema/wrapper/shared packages,
renderer implementation, Mac, engine/models, allowance/commerce and CI stay unchanged.

No builds/typechecks/tests/fixtures, CI dispatch, generation, native playback/
processing/export or UI/device execution. Compilation and actual native Form,
keyboard, dismissal, persistence/history and audiovisual behavior are unverified.
Keep the PR open without auto-merge; no next feature or merge is automatic.

## CI filename/type collision correction

The user's failed bybydev/example Build Release run 41184375867 built PR #55 head
43b94551. Compilation stopped because Inkribe/Editor/MediaInspector.swift and
Inkribe/Media/MediaInspector.swift shared a basename; their top-level types also
shared the same name. Rename only the editor Form file/type to MediaSheet.swift /
MediaSheet and update its editor route. Keep the existing metadata inspector and
import pipeline unchanged. Source filename/type/call-site/diff review only; this
correction has not been compiled or dispatched to CI by the agent.
