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
