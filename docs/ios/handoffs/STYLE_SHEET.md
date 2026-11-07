# Style form — source handoff

2026-10-29. Existing PR #52, feat/ios-style-sheet-grid -> develop.
This revision extends first-implementation head 5f58ba83; keep open without auto-merge.

- [x] Export is an ordinary fifth bottom action after Media, opening the existing
  export sheet. All five use identical treatment with reduced spacing/insets/width;
  horizontal scrolling remains available for larger text or narrower widths.
- [x] Main-editor Undo/Redo are icon buttons in the toolbar, disabled when unavailable.
  Their main playback-row/menu duplicates are removed; contextual sheet/fullscreen
  history stays available. Export capture/queue/saved-file behavior is unchanged.
- [x] Removed the Timeline heading/header row; Clip X of Y now sits in the main
  playback row before fullscreen, retaining selected-clip numbering and the same
  Clips sheet action/accessibility. The compact-width playback fallback retains it.
  Preview geometry no longer reserves height for the removed header.
- [x] Removed the main editor project title and save-status subtitle from navigation.
  Back, Undo/Redo and the ellipsis remain. Rename/Project info, menu save status,
  automatic persistence and visible save-error/retry behavior are unchanged.
- [x] Native root Form with sample, Template and Text/Colors/Appearance/Layout/Motion
  sections. Labels/selected summaries replace horizontal category tabs.
- [x] Weight menu, inline Size, native color pickers and pushed Font/Animation,
  Spacing, Outline, Background, Shadow and Text-layout forms. Compound rows group
  related settings; secondary shadow offsets stay inside its detail form.
- [x] Shared CaptionStyleSample/CaptionSampleScenery supply the exact same authored
  words, timing, static sample frame and background for grid/Style views.
  Only the root Style form previews draft appearance live; pushed picker/detail
  forms contain settings only. Returning to Style reflects draft changes.
  Grid tiles remain static.
- [x] The shared sample cycles three meaningful sentences as separate four-second
  cues over 12 seconds, with authored word timings for highlight/motion review.
  Sample text, loop duration and initial thumbnail frame share one definition.
- [x] One visible sample clock at most, capped at 30 fps. Play/pause, Reduce Motion,
  scene, upsell, push/pop and view visibility control animation. No project media
  decode/player, transcript reparse, save or inference is used by the sample.
- [x] Remove Style's project time readout, scrubber/replay/prompt and all caption
  scope/override/reset-to-project controls. Appearance is project-wide.
- [x] Selected template still pushes a native lazy grid. Native Back without a
  selection changes nothing. Saved/unknown preset values stay authoritative.
- [x] Cancel/dismiss discard the local transaction. Done saves atomically before
  adopting, one ordinary settings Undo entry; failures preserve retry/Cancel.
- [x] Project-wide placement in Style under Layout: Top/Center/Bottom menu and
  inline precise X/Y. The draft accepts placement changes and the root sample
  renders them live; Cancel/Done owns saving. No caption controls remain in Media.
  Media retains its actual preview/scrubber through the single-player adapter.
- [x] Retain clip-specific framing/audio; their reset controls operate on media
  only and do not imply a caption inheritance hierarchy.
- [x] Live CaptionSnapshot defaults to project-wide styling. New export manifests
  strip obsolete clip-caption overrides after saved-state verification. Existing
  frozen MP4 requests use their captured clip styles; completed files are untouched.
- [x] Successful appearance/placement saves clear obsolete caption overrides while
  preserving clip media/name settings. No schema or request-format change, read-time
  migration/write, shared package, native renderer, Mac, speech/model/allowance,
  purchase, icon or CI change.

Source/call-site/diff/whitespace and publication review only. No builds/typechecks/
tests/fixtures, CI, generation/downloads, native playback/render/export or UI/device
execution ran. Compilation, actual layout and picker gestures, render legibility,
clock transitions, disk failures and device performance remain unverified.

The native form uses the real ten-template catalog and installed font families.
The live sample uses draft X/Y so placement changes can be reviewed in Style.
Static tiles alone are centered/enlarged for legibility, as in the prior grid;
chosen/project style values are never replaced by thumbnail values.

---

## Approved scope — archived brief (consolidated 2026-11-07)


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

