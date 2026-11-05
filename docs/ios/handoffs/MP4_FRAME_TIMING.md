# MP4 frame timing repair

2026-11-05. Stacked branch `fix/ios-export-timing` targets PR #62's
`fix/ios-improvements`, from `bb4fd6f9e312746d42ed52b3e156c94a6520d67d`.
Scope: V1.MP4 / V1.EXPORT_JOB timing and failure diagnostics. Leave open without
auto-merge and preserve the parent branch.

## Problem and evidence boundary

A multi-clip project containing an iPhone screen recording failed with the generic
source-frame decoding message. The affected media/logs were not supplied and no
native export was executed. The exact failing branch is therefore unconfirmed.

Source review found that MP4Exporter applied source-clip-start and fixed 67 ms
freshness checks to already composed AVAssetReaderVideoCompositionOutput samples.
These checks did not use sample duration. A sample covering the requested output
time could be rejected merely because its PTS preceded a clip boundary or its
valid display interval exceeded the fixed age limit. The same generic error also
covered invalid video/audio timestamps and real reader failures.

## Source changes

- PreviewComposition explicitly uses frameDuration 1/30 with
  sourceTrackIDForFrameTiming set to kCMPersistentTrackID_Invalid. Preview and
  export still share the same graph, transforms, source intersections and audio.
- Select the latest composed sample with PTS <= output time; validate its
  half-open display interval using exact CMTime comparisons. A later sample takes
  over at its PTS even if the prior duration overlaps. Individual clip start
  timestamps are no longer treated as composed-sample timestamps.
- Honor positive declared sample durations, including durations above 67 ms.
  If duration is zero/invalid, allow only the composition's fixed frameDuration.
  Negative/nonfinite durations fail; no nominal-duration fallback is allowed for
  source-timed composition mode. Never extend a short frame to a distant next
  timestamp or to EOF just to make export finish.
- Validate every video timestamp on read, including lookahead. Invalid,
  duplicate or backward timestamps fail before they can leave an old frame held.
  Check reader failure immediately after video reads, including nil/EOF.
- Keep intentional black intervals and audio-only output, the 30 fps writer and
  caption clock, bounded current/lookahead buffers, audio mix/PTS policy,
  cancellation/teardown and final validation/publication paths.
- Reader setup/start/decode, missing video, uncovered video time and audio/video
  timestamp failures now have distinct descriptions with an output time when
  available. NSError retains the underlying native error, with its domain/code
  and description also included in the persisted job error. OSLog additionally
  records rational output/sample/next PTS, sample duration, active video interval
  and reader status. The log includes no file paths, project names or captions.

No originals are transcoded or changed. Existing completed outputs, manifests,
project schema, SRT, import behavior, queue limits and Mac code remain unchanged.
Failed frozen MP4 requests can be retried through the existing path.

## Source review matrix (not executed tests)

| Case | Expected behavior from the source |
|---|---|
| Ordinary 30 fps samples | Current sample covers its output tick; next takes over at its start |
| Sample at 1 s, duration 0.2 s, output 1.1 s | Accepted despite exceeding the old 67 ms limit |
| Non-grid clip boundary inside a composed sample's valid display interval | No rejection based solely on the new clip start |
| Overlapping durations | Latest sample with PTS <= output tick wins |
| Next sample is in the future | Never display it early |
| Positive short duration ends before next sample | Uncovered output time fails; no unlimited freeze |
| Missing/zero duration in fixed-cadence composition | One composition-frame fallback only |
| Missing duration in source-timed mode | Fails rather than guessing a VFR duration |
| Negative/indefinite duration | Fails coverage validation |
| Invalid/duplicate/backward lookahead timestamp | Immediate descriptive timestamp failure |
| EOF within a declared final frame duration | Final covered output ticks can render |
| EOF before remaining required video coverage | Missing/coverage failure; no stale tail |
| Intentional gap or audio-only interval | Black image with the existing caption overlay |
| Reader reports failure on read/EOF | Native error preserved; no masking as timing failure |
| Pause/cancel | Task cancellation and existing task-owned reader/writer teardown remain |
| Failed export | Existing caller removes partial file; originals/frozen inputs retained |

Validation: verified modified baseline blobs against the remote parent tree,
reviewed the diff/call sites and checked whitespace. No builds, typechecks, tests,
fixtures, CI, project generation, native exports or UI/device runs were performed.
Compilation and actual mixed-recording export/playback remain unverified. This PR
fixes the identified timing assumptions; it is not proof that the user's specific
recording has no separate decoder problem.

API references: Apple's [sample duration](https://developer.apple.com/documentation/coremedia/cmsamplebuffergetduration(_:))
and [composition frame timing](https://developer.apple.com/documentation/avfoundation/avvideocomposition/sourcetrackidforframetiming).
