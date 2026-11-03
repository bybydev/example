# Editor playback controls — source handoff

2026-11-01. User-authorized follow-up in PR #58, fix/ios-improvements -> develop,
extending b371be7c. Keep this PR open without auto-merge.

- [x] Main editor uses Start, Play/Pause, End on the left, current/total time
  between flexible spaces, then speed and Fullscreen. Transport icons and speed
  have complete 44-point targets and accessible labels. The existing two-row
  fallback accommodates narrow widths and larger text.
- [x] Remove Clip X of N and its unused label builder; the dedicated Clips action,
  selected-clip routing and timeline selection remain intact. Captions-sheet
  controls retain their existing buttons/history; new controls are main-only.
- [x] Boundary jumps pause and use the existing guarded seek path. End targets
  the last sample on the shared 30 fps preview clock, including short/non-frame-
  aligned durations, rather than seeking beyond the last visible frame. Play from
  that frame restarts at zero. Rapid seeks retain the existing generation guard.
- [x] Five preview speeds (0.5/1/1.25/1.5/2) update the shared AVPlayer's
  defaultRate; the active rate changes only when playback is already requested.
  Paused selection stays paused, and later Play retains the chosen speed. Positive
  native rate changes synchronize the readout/default rate, and default-rate KVO
  follows native speed choices while paused; stop removes both observations.
- [x] Speed is session-only presentation state. Project documents, revisions,
  history, media/export compositions, SRT, frozen requests and completed-file
  players are unchanged. The fullscreen caption clock and equal bottom columns
  from earlier #58 commits remain intact.

Sizing follow-up: the user reports speed text too small and the fullscreen glyph
too large relative to the correctly sized Start/Play/End icons. Enlarge speed
from caption to title3/medium and reduce only the fullscreen glyph from title3
to body. Keep Start/Play/End typography and all 44-point tap targets. Match the
fullscreen speed choices: 0.5/1/1.25/1.5/2.

Validation is source/call-site/lifecycle review, diff/whitespace checks and remote
tree preservation only. No builds/typechecks/tests, CI, generation or native/UI/
device execution. Compilation and runtime playback/layout acceptance are unverified.
