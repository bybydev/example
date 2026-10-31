# Media Form — approved scope

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
