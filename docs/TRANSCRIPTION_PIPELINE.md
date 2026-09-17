# Inkribe — Recording, Import, and Transcription Pipeline

## Product flow

Phase 4 implements the first complete local content path:

```text
Record or Import
  → durable app-owned media
  → persistent transcription job
  → local media decode
  → local Whisper inference
  → durable transcript document
  → transcript route
```

There is no cloud fallback and no alternate feature scheduler.

## Durable storage

Phase 4 uses three independent stores under the app support directory:

```text
jobs.json                 JobQueue metadata/state
transcripts.json          transcript documents
Media/
  Sources/                copied imports
  Recordings/             recordings written in-place
```

`DurableMediaStore` generates UUID filenames, validates relative paths, rejects traversal, copies imports through a partial file before the final move, and removes failed ingestion artifacts.

## Import

The Import surface supports:

- Finder file selection
- drag/drop URLs
- multiple files
- audio and movie containers
- per-import language choice
- queue progress
- cancel/retry
- queue pause/resume

Each external file is accessed only long enough to copy it into Inkribe-owned storage. Jobs keep only the resulting relative path.

`AudioMediaDecoder` reads the first audio track from the durable source and requests uncompressed 16 kHz mono Float32 samples. The same path therefore handles common audio containers and audio embedded in video files.

A media file with no audio track fails as a processing error instead of producing an empty transcript.

## Recording

`MicrophoneRecorder` is app-scoped rather than owned by the Record view. Navigating between shell destinations therefore does not destroy an active capture session.

The recorder provides:

- microphone permission handling
- Mac input-device enumeration and selection
- record
- pause/resume
- stop
- discard
- live level meter
- accumulated recorded duration
- durable CAF output
- cleanup after write/configuration failures

Pause stops writing incoming buffers rather than closing/reopening the file. Stop leaves the completed source media in its durable location and immediately creates/enqueues the transcript target.

If the audio sink fails, the recorder tears down the engine and the app state removes the stale recording before another session can start.

## Transcription execution

`TranscriptionJob` is the only persistent v1 transcription job type and has concurrency 1.

`DefaultTranscriptionJobExecutor`:

1. resolves the existing transcript target;
2. resolves durable media;
3. decodes to Whisper's 16 kHz mono buffer contract;
4. calls the shared Whisper runtime;
5. maps inference progress into queue progress;
6. stores detected/requested language, duration, raw text, timestamped segments, and updated time;
7. keeps edited text synchronized only while the user has not diverged from raw text;
8. saves the transcript durably before returning success.

The executor protocol uses an Inkribe-owned progress closure. JobQueue's reporter type does not leak into the app or execution service boundary.

## Retry semantics

Retry always targets the original transcript ID and original durable media path.

When edited text still mirrors old raw text, the new transcription replaces both and advances the revision. If edited text has been manually changed, new raw transcription/segments can refresh without overwriting the manual edit or its revision.

This is the key idempotence rule that Phase 5 and Phase 6 can build on.

## Shell behavior

Record and Import fill the existing main-content region; they do not change the permanent two-column shell.

Both surfaces reuse the same queue presentation. The main status bar shows:

- Ready
- Transcribing
- Queue paused
- Needs attention

A completed recording that originated from the Record surface automatically navigates to its transcript route. Import queue rows expose an Open action for completed transcripts.

The actual transcript editor remains Phase 5 work.

## Failure boundaries

- External source unavailable: import fails before enqueue.
- Durable copy failure: no job is created.
- Enqueue failure: newly-created transcript/media are cleaned up.
- Missing audio track: job fails and remains retryable.
- Missing transcript target: job fails instead of creating an unrelated document.
- Cancellation before content commit: job becomes cancelled according to JobQueue.
- Transcript save failure: job fails; completion is never reported.
- Cancellation after a successful transcript save does not convert committed content into a cancelled record.
- Duplicate transcript IDs in persistence fail explicitly instead of trapping.

## Phase 5 contract

Phase 5 may add library/search/editor/playback behavior, but must keep these Phase 4 boundaries intact:

- JobQueue remains processing-state truth.
- Transcript persistence remains document-content truth.
- Source media stays app-owned by relative path.
- Manual edits must not be overwritten by retries.
- Feature UI must not create a parallel processing state machine.
