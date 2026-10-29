# Style form and shared template sample

2026-10-29. Latest user-approved mockup in existing PR #52,
feat/ios-style-sheet-grid -> develop. This revision extends 5f58ba83.
Keep open without auto-merge. Scope: V1.STYLE/PRESETS and necessary Media/output integration.

- One large Style sheet with a native form. Sample preview above the selected
  template; Text, Colors, Appearance, Layout and Motion sections follow it.
- Main editor bottom actions are Clips/Captions/Style/Media/Export, all using the
  same button treatment with tighter spacing. Undo/Redo move from the main playback
  row/actions menu to its toolbar; contextual sheet/fullscreen history remains.
- Remove the visible Timeline header. Move its Clip X of Y button into the main
  playback row before fullscreen, keeping its selected-clip list entry behavior.
- The main editor navigation bar has no project title or saved-status subtitle.
  Keep Back, Undo/Redo and the actions menu; existing rename/status/error UI remains.
- Labels left, selected/compound values right. Weight uses a menu; Size expands
  inline. Font/Animation and Spacing/Outline/Background/Shadow/Text layout push
  native forms/pickers. Secondary shadow offsets are disclosed inside Shadow.
- Use the same procedural backdrop, sample words and authored timing as the grid.
  Cycle three meaningful sentences as separate four-second cues in a 12-second loop.
  Render all draft appearance changes live. Overlay play/pause only; no project
  player, scrubber, time readout, replay action or conditional Preview-a-caption row.
- Only the visible sample animates, capped at 30 fps. Pause on navigation, upsell,
  inactivity and scene disappearance. Reduce Motion starts still with explicit play.
- Preview appears only on the root Style form. Pushed pickers/detail forms show
  settings only; returning to Style reflects the current draft appearance.
- Keep the native lazy Templates grid. Its tiles stay static at the sample frame;
  selecting a template returns to Style and preserves project caption placement.
- Caption appearance is project-wide. Remove caption scope and inheritance/reset
  UI. New live previews and new exports use one project style across all clips.
- Keep caption placement in Style under Layout: Top/Center/Bottom menu and inline
  precise X/Y adjustments, rendered live in the root sample. Placement uses the same
  Cancel/Done transaction; Media contains no caption controls. Clip framing/audio
  and the actual Media preview/scrubber remain separate.
- Cancel and dismissal discard local edits; Done durably saves before adopting,
  with one settings history entry. A failure stays local and permits retry/Cancel.
- Expected caption state and current Pro access are rechecked on Done. Unknown
  template ancestry never replaces saved resolved appearance or invents a reset.
- Keep old clip-caption fields readable for frozen export compatibility. Live
  snapshot construction defaults to project style; already-frozen MP4 requests
  explicitly retain recorded clip styles. New request capture strips caption
  overrides after validating the saved project, keeping all media/name settings.
  Successful live appearance/placement edits likewise remove obsolete overrides.
- Keep catalog, schema/request versions, native renderer, shared packages, models,
  speech/allowance, queue, purchase products, originals, completed files and Mac.
  No saved-template library or new templates are in scope.

Source-only: no builds/typechecks/tests/fixtures, CI/generation/downloads, native
processing/exports, UI/device execution or deployment. Compilation and actual
appearance, transitions, gestures, performance and output acceptance are unverified.
