# Caption text correction across trim boundaries

2026-11-05. User-requested P1 fix on `fix/ios-improvements` from develop
`d870b04dd8cb2c642e0083e4d6ca85ac2f072bfb`, targeting develop. Keep the PR open
without auto-merge for later explicitly requested changes.

The caption text field reads `CaptionSnapshot.text(for:)`, whose cue contains
only words retained by `OutputTimeline`. Previously `CaptionEdits.cueText` used
every word in the original cue. A correction to visible text could clear hidden
words or assign the correction to a word outside the retained video.

## Source integration

- [x] `EditorSession.editCueText` supplies the current snapshot cue's word IDs.
- [x] `CaptionEdits.cueText` validates that the supplied IDs are a nonempty,
  ordered subset of the original cue. Invalid or missing targets fail before
  mutation; there is no fallback to rewriting the entire cue.
- [x] Character comparison, insertion ownership and final text assignment all
  use that same subset. Words outside it are untouched, including whitespace.
- [x] The existing timed-unit character mapping, native IDs/intervals, raw
  recognition, cue membership/order, undo/redo and serialized autosave remain.
- [x] Manual phrases keep their existing text-edit path. No UI, schema, player,
  renderer, speech/retry/language, export pipeline, Mac or CI change is included.

## Regression cases reviewed in source

These are source-path checks, not executed tests or device acceptance.

| Case | Expected behavior and source evidence |
|---|---|
| Leading trim | Original timed words `One ` / `two ` / `three`; retain only the last two and replace visible text with `two THREE`. The hidden first word stays `One `; replacement ownership is restricted to the retained words. |
| Trailing trim | Correct retained leading words without changing any trailing hidden words. Both read and write loops use only the supplied IDs. |
| Both boundaries | Correct or clear a middle retained subset while keeping text on both hidden sides. |
| Hidden visible units | If retained words currently contain empty text, new text goes to the first retained word rather than an off-trim original word. |
| No trim / partial word | When all words remain visible, the same full-cue character mapping is used. A partly retained timed unit remains one editable unit, with its existing timing. |
| Project / per-clip trim | Both derive the editable IDs from the same snapshot's shared output map. |
| Undo / redo / save | Existing patches contain only changed words; the same session history and repository writer handle adoption, saves and reopen. |
| Invalid IDs | Missing, duplicate, foreign or reordered supplied IDs are rejected before changing state. |
| Manual caption | The existing manual-text branch returns before native cue editing. |

Validation: reviewed source, call sites, diff and whitespace, then verified the
published tree and PR base/head. No builds, typechecks, tests/fixtures, CI runs,
generation, native processing, playback, exports or device/UI execution were run.
Compilation and runtime acceptance remain unverified.
