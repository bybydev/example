# Phase 4 Handoff — Recording, Import, and Transcription

## Status

Phase 4 is implemented on PR #6.

The repo now has a complete local path from microphone/file input to a durable transcript document using the Phase 3 Whisper runtime and JobQueue 1.0.0.

## Delivered

### Recording

- app-scoped `MicrophoneRecorder`
- microphone permission flow
- Mac input-device discovery/default selection
- selected-input routing through the input audio unit
- record / pause / resume / stop / discard
- live level meter
- recorded-duration tracking
- durable CAF capture under app-owned media storage
- write/configuration failure cleanup
- Core Audio device enumeration uses the actual mutable device-ID buffer

### Import

- multi-file file picker
- drag/drop URLs
- audio and movie content types
- security-scoped source access limited to durable copy time
- UUID-named app-owned source files
- symlink resolution before copy so durable media owns bytes rather than an external link
- per-file failure collection
- shared language selection

### Media pipeline

- `DurableMediaStore` with path-containment checks
- local-file source enforcement
- partial-copy then final-move ingestion
- separate `Sources/` and `Recordings/` namespaces
- `AudioMediaDecoder` using the first audio track
- uncompressed 16 kHz mono Float32 output for Whisper
- audio extraction from supported video containers through the same decoder path

### Persistence

- `JSONTranscriptRepository`
- atomic transcript snapshot writes
- durable save/reload/delete
- newest-first ordering
- explicit snapshot version
- explicit duplicate-ID failure rather than a dictionary trap
- queue metadata, transcript documents, and media stored separately

### JobQueue integration

- exact existing `JobQueue` 1.0.0 dependency retained
- concrete persistent `TranscriptionJob`
- payload exactly: transcript UUID, durable media relative path, optional language
- single transcription concurrency
- registration before queue startup/restoration
- app-injected execution environment for restored jobs
- queue state mapped directly to Waiting / Transcribing / Pausing / Cancelling / Complete / Failed / Cancelled / Needs attention
- cancel/retry/remove/pause/resume delegate to JobQueue
- no feature-level scheduler/state machine
- privacy-safe lifecycle event bridge for diagnostics; raw queue failure text is not forwarded

### Execution

- resolve durable media
- decode media to Whisper input
- forward inference progress to JobQueue
- persist detected language, duration, raw text, timestamped segments
- keep edited text synchronized only until the user diverges from raw text
- advance transcript revision when synchronized edited text changes
- preserve manual edits/revision on re-transcription
- durable transcript write is the completion commit point

### Mac surfaces

- real Record view in the permanent shell
- real Import view in the permanent shell
- shared queue list
- per-job progress, cancel, retry, Open
- queue pause/resume only when active work exists
- main status bar reflects active/paused/persistence-issue state
- Record automatically opens its transcript route when its queued transcription completes

## Tests added/updated

- media durable copy and traversal rejection
- media decode to the Whisper sample-rate/channel contract
- transcript save/reload/delete/sort
- duplicate transcript IDs fail safely
- queue registration/restoration
- exact durable job payload shape and single-concurrency declaration
- complete decode → fake Whisper → durable transcript flow
- manual edits survive re-transcription
- cancellation propagates through JobQueue
- failed job retry → completion with privacy-safe lifecycle events
- app-state startup remains idempotent with an injected executor

## Important invariants for Phase 5+

1. `JobQueue` remains the only processing scheduler/state owner.
2. `JSONTranscriptRepository` is transcript-content truth.
3. Queue records never become a transcript cache.
4. Persistent jobs reference only app-owned media paths.
5. Retry updates the same transcript ID.
6. User-edited transcript text is not silently overwritten by re-transcription.
7. A job cannot report success before the transcript save succeeds.
8. Record/Import stay inside the Phase 1 shell geometry.
9. Shared packages remain free of AppKit and MacAppFoundation.
10. Queue diagnostics remain content-safe: IDs/status only, not transcript/audio/path/error payloads.
11. Transcript editor/library/search/playback belong to Phase 5, not this pipeline.

## Next phase

Phase 5 should build the transcript library/editor on top of this content:

- local transcript library
- recent/search/title rename/delete/sort/filter
- editable transcript text
- retained segments/timestamps
- playback and seek by segment
- current-segment highlighting
- transcript-local search
- clear raw-vs-edited behavior

It should consume the existing transcript repository and durable media reference rather than changing the queue contract.
