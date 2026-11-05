# MP4 frame timing repair

2026-11-05. PR #67, `fix/ios-export-timing` -> `fix/ios-improvements`, is
stacked on PR #62. Scope: V1.MP4 / V1.EXPORT_JOB. Leave both PRs open without
auto-merge; do not modify the parent branch.

## Problem and current correction

A multi-clip project containing an iPhone screen recording failed during export.
The initial implementation replaced a 67 ms freshness/source-clip-start guard
with exact sample-duration coverage. The user then reported that this replacement
still failed at output time 260.100 s. That message identifies the app's coverage
guard, after a decoded image was found; it does not establish a native decoder
failure. The exact sample/next timestamps and duration were not supplied.

The follow-up removes duration coverage from interior frame selection. The reader
loop already selects the latest composed sample whose PTS is <= the output tick,
with a validated lookahead PTS greater than that tick. Hold this decoded frame
until that next PTS, including when reported sample duration ends earlier.
Do not reject a frame because of its age, source clip start, or duration metadata.
Do not display a future sample early. AVFoundation applies source cuts, trim and
transforms before these samples reach the exporter.

EOF has no lookahead timestamp, so it has a separate completeness check. Compare
the terminal sample's end with the final required video interval, using its
positive declared duration or the fixed composition cadence (whichever is longer).
Missing/nonpositive/nonfinite duration uses the known fixed cadence when available.
Allow a remaining shortfall strictly smaller than one 30 fps output frame for
the final partial frame. Larger missing tails fail explicitly instead of extending
the last image across the remaining movie. Do not require video to extend through
a trailing intentional audio-only/black region.

## Preserved behavior

- Shared preview/export composition explicitly uses a 1/30 frameDuration and
  kCMPersistentTrackID_Invalid source timing. Original files are not normalized.
- Every decoded video PTS, including lookahead, must be numeric and strictly
  increasing; reader failures are checked immediately after video reads/EOF.
- Missing images still fail; intentional black regions stay black with captions.
- Current/lookahead sample ownership remains bounded. The writer/caption clock
  stays 30 fps, with unchanged audio mix/timestamps and H.264/AAC settings.
- Native errors, output time and failure-stage descriptions survive in job
  errors; OSLog includes rational PTS/duration/interval/status diagnostics without
  file paths, project titles or caption text.
- Cancellation, task-owned teardown, partial cleanup, immutable requests and
  atomic output validation/publication remain unchanged.
- No import/UI, Mac, schema, SRT, queue-policy or completed-output changes.

## Source review matrix (not executed tests)

| Case | Expected behavior |
|---|---|
| Current PTS <= tick < next PTS, duration ends before tick | Hold current decoded frame; no coverage error |
| Interior duration zero/invalid/nonfinite | Does not affect selection; consecutive PTS are authoritative |
| Next PTS equals output tick | Advance to that next frame |
| Next PTS is later than output tick | Never display the next frame early |
| Clip cut between output ticks | Use composed sample sequence; no source-start comparison |
| Invalid/duplicate/backward lookahead PTS | Descriptive timestamp failure on read |
| Missing decoded image at required video tick | Missing-frame failure |
| EOF and terminal duration reaches final video interval end | Accept terminal frame |
| EOF terminal duration missing or shorter than fixed cadence | Use fixed composition cadence |
| EOF shortfall smaller than one output frame | Accept final partial-frame alignment |
| EOF shortfall >= one output frame after terminal duration/cadence | Fail explicitly as early EOF |
| EOF with neither valid duration nor fixed cadence | Fail instead of guessing |
| Trailing intentional black/audio-only region | Completeness is based on last video interval, not whole project duration |
| Reader reports failure on sample/EOF read | Preserve underlying native error |
| Cancel or render failure | Existing teardown and partial cleanup; no output publication |

The 260.100 s report is evidence of the initial implementation's failure, not a
successful reproduction of the revised code. No affected media or detailed timing
logs were available. Source/call-site and publication content review only; builds,
typechecks, tests, fixtures, CI, native exports and UI/device checks were not run.
The follow-up was prepared through the GitHub connector because the local execution
environment was unavailable. Actual export/playback of the user's project remains
unverified.
