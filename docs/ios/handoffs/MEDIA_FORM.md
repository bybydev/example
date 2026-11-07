# Media Form — passes 1–2 source handoff

2026-10-31. feat/ios-media-form -> develop; baseline 4a9517bc.
The user's next-pass signal authorizes pass 2 in PR #55, extending bb0d1b11.
Both planned passes are source-complete; compilation/native/UI acceptance is unverified.
See [approved scope](MEDIA_FORM.md).

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

---

## Approved scope — archived brief (consolidated 2026-11-07)


2026-10-31. The user starts pass 1 of two in one new PR targeting develop,
from 4a9517bc. Branch: feat/ios-media-form. The user subsequently authorizes
pass 2 in PR #55 with the next-pass signal, extending bb0d1b11.

## Approved interface

- EDITOR.MEDIA_FORM: large, themed native Form matching Style's rows/sections,
  inline Media title and Cancel/Done. No media preview, player or transport.
- EDITOR.MEDIA_SCOPE: the first row is Settings for: Project / Clip 1 / Clip 2….
  The complete form below changes with scope; keep the picker even for one clip
  because project and clip settings have different meanings. No middle clip picker.
- Project shows Canvas/aspect ratio, whole-project trim/start/end/output duration,
  Reset trim and original-audio master mute. No project framing or volume defaults.
- A clip shows Framing/Fit/Fill, inline expandable Zoom and Position, original
  Volume, Reset framing and Reset volume. Resets restore standard values.
- No inheritance indicators, project-default menu item or reset-to-project actions.
  Scope changes do not seek/select playback or affect editor layout.
- EDITOR.MEDIA_TRANSACTION: all project and clip changes remain local through
  scope switches; Cancel/swipe discards. Done validates/saves before adoption,
  publishes one bounded settings Undo entry, and refreshes the existing preview.
  Invalid trim returns to Project; failed writes retain the draft for retry/Cancel.
- EDITOR.CLIP_MEDIA_VALUES: resolve existing legacy defaults on entry. On the
  first successful changed Media save, persist those effective values explicitly
  for every existing clip and retain only trim at the project media level.
  No-op Done and cancellation do not rewrite settings or create history.
  No schema migration/read-time writes; schema remains 12. Legacy/frozen readers
  remain supported, and untouched clips retain their exact effective values.

## Protected behavior

Keep Style, Clips, Music, timeline/navigation, preview dimensions, caption data
and genuine timing, shared engine/model, allowance/Pro, queues, frozen exports,
originals, storage and Mac unchanged. Master mute preserves clip levels/music.
Retain the shared media graph/trim clock for preview and new output requests.
No new renderer, dependency, schema/wrapper format, CI or player.

Both planned passes are now source-complete. Pass 1 implements the form/draft/
session integration. Pass 2 reviews scope/reset,
cancel/stale/save/history/reopen and preview/export integration, fixing scoped
defects only. Keep this PR open with auto-merge disabled.

Source review only: no builds/typechecks/tests/fixtures, CI runs, generation,
downloads, native media execution/exports, UI/device execution or deployment.

## Pass 2 integration revision

Keep the same interface. Cancel immediately closes the local draft; sheet teardown
cancels its owned save task and closes the draft. Closed/cancelled work is rejected
before publication; a successful durable publication is always adopted without
another cancellation point. Late completion never dismisses another presentation.
Done relies on saved document state, independently of preview readiness. Saving
invalidates old loading/preview generations; interrupted work restarts against the
unchanged document after failure/no-op, or the saved document after success.
Build explicit clip settings from one latest-state index and sort once, preserving
clip names/caption fields and exact effective values. Dismissal reconciles speech
progress whose notification may have been excluded during the Media transaction,
waiting for scheduled graph work to finish before reconciling. A forced teardown
also reconciles once an admitted save settles.
These are scoped source fixes, without runtime acceptance or new feature scope.

