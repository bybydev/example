# Inkribe — Transcription Queue Contract

## Dependency

Inkribe uses `hoangbkit/JobQueue` at exact version `1.0.0` for durable transcription orchestration.

```text
source: https://github.com/hoangbkit/JobQueue.git
version: 1.0.0
commit: e9046c09675b460f19fbc2bada5f8494b8def046
product: JobQueue
```

Do not replace this with a moving branch and do not create a second feature-level scheduler or queue state machine.

## Ownership

JobQueue owns:

- durable job records and restoration
- scheduling and single-concurrency enforcement
- pending / processing / pausing / cancelling / completed / failed / cancelled / unrecoverable states
- progress
- retry and cancellation
- queue pause/resume
- persistence issue state
- record retention/cleanup

Inkribe owns:

- the `TranscriptionJob` payload schema
- durable media paths
- media decoding/normalization
- Whisper execution
- transcript document persistence
- presentation mapping and navigation
- privacy-safe lifecycle diagnostics
- transcription-runtime resource lifetime around queue drain

Queue metadata is processing truth. `JSONTranscriptRepository` is transcript-content truth.

## Persistent job

Phase 4 implements one complete media-to-transcript job:

```swift
struct TranscriptionJob: Job {
    struct Payload: Codable, Sendable {
        let transcriptID: UUID
        let sourceMediaRelativePath: String
        let requestedLanguage: String?
    }

    static let maxConcurrentExecutions = 1
}
```

The payload intentionally contains no transcript body, audio bytes, runtime object, security-scoped access, model instance, view state, or closure.

`sourceMediaRelativePath` points into Inkribe-owned media storage, so a restored job never depends on the original picker/drop URL remaining accessible.

## Startup and restoration

`TranscriptionQueueController` creates an app-scoped registry and queue. Startup order is fixed:

1. install the app-scoped transcription executor;
2. register `TranscriptionJob`;
3. start JobQueue and restore persisted records.

Unknown/unrestorable records remain queue-owned unrecoverable records and map to **Needs attention**.

The queue persistence file and transcript store are separate:

```text
Application Support/Inkribe/jobs.json
Application Support/Inkribe/transcripts.json
Application Support/Inkribe/Media/...
```

This separation prevents queue metadata from becoming a shadow transcript database.

## Enqueue transaction

Record and Import both follow the same durable boundary:

1. create/copy source media under `Media/`;
2. create the target `Transcript` with its final `TranscriptID`;
3. persist that transcript target;
4. enqueue `TranscriptionJob` using the same ID and durable media path.

If enqueue fails, the newly-created transcript target and media file are removed so the operation does not leave orphaned content.

Imported files are resolved to their filesystem target before copying so a symlink cannot leave the queue dependent on an external target. Recording writes directly to its durable destination, so Stop never has to move a temporary capture into place.

## Execution

`DefaultTranscriptionJobExecutor` executes the job as one durable unit:

```text
resolve media
  → decode audio track to 16 kHz mono Float32
  → Whisper transcription
  → map language + timestamped segments
  → update transcript by transcriptID
  → durable transcript save
  → job success
```

Audio and video containers use one decoder path; video files contribute their audio track only.

Whisper progress is mapped into queue progress. Cancellation is checked before the durable content commit.

The transcript write is the commit point: after it succeeds the job returns success rather than turning already-saved content into a cancelled queue record.

## Runtime resource lifetime

Phase 8 keeps inference resource ownership inside the transcription layer rather than teaching feature UI how to manage Whisper.

`DefaultTranscriptionJobExecutor` conforms to `TranscriptionRuntimeManaging` and exposes only an async model-release capability. `TranscriptionQueueController` keeps the executor/runtime warm while JobQueue is processing a batch. When JobQueue emits `queueDrained`, the controller asks a managed executor to release idle transcription resources.

This has two consequences:

- multiple files in the same queue batch can reuse the loaded Whisper model;
- once the queue is drained, Whisper does not remain resident indefinitely while the user switches to editing/export/local-AI work.

The release hook never changes JobQueue scheduling, progress, restoration, retry, or cancellation semantics. Executors that do not implement `TranscriptionRuntimeManaging` continue to work unchanged.

## Retry and idempotence

Retries always update the same `TranscriptID`; they never create a second transcript.

If `editedText` still mirrors the previous raw transcript, a successful re-transcription updates both raw and edited text and advances the transcript revision. If the user has manually changed `editedText`, retry replaces only raw transcription data and preserves the user edit/revision.

A failed or cancelled JobQueue record is retried through JobQueue itself; Inkribe does not synthesize a second processing state machine.

## UI state mapping

The Mac feature surfaces derive presentation directly from JobQueue records:

```text
pending        → Waiting
processing     → Transcribing
pausing        → Pausing
cancelling     → Cancelling
completed      → Complete
failed         → Failed
cancelled      → Cancelled
unrecoverable  → Needs attention
```

Per-job progress comes from JobQueue live progress. Cancel/retry and queue pause/resume delegate directly to JobQueue. Pause/resume is shown only while active work exists.

Record and Import share the same queue surface. The main status bar reflects queue pause/activity/persistence issues rather than tracking its own processing state.

## Diagnostics and privacy

`TranscriptionQueueController` maps JobQueue lifecycle events into an Inkribe-owned event enum. The bridge includes job IDs and queue status only; it intentionally drops JobQueue's raw failure/persistence strings and progress-message stream.

The app logs enqueue/start/pause/cancel/completion/failure/removal/status/drained/persistence-failure lifecycle events without transcript text, audio contents, source paths, prompts, or generated content.

Queue records likewise do not contain transcript text or audio contents. Generated media paths use UUID filenames rather than source filenames. User-visible import errors may identify the file the user selected, but durable queue metadata and diagnostics remain content-minimal.

## Tests

The queue/transcription contract is covered for:

- durable queue restoration with registered `TranscriptionJob`
- exact stable job payload shape
- single-concurrency declaration
- successful media decode → Whisper result → transcript persistence
- preservation of manual edits on re-transcription
- queue cancellation propagation
- failure → retry → completion
- privacy-safe lifecycle event forwarding
- durable media copy/path containment
- 16 kHz mono decode contract
- durable transcript save/reload/delete/sort
- corrupt duplicate transcript IDs failing safely
- app startup remaining idempotent with an injected executor
- idle managed-runtime release without introducing a second scheduler

## Later-phase rule

Library/editor, local AI, export, Settings, and release hardening all consume the queue contract defined here. They may present or diagnose queue state, but they must not introduce another transcription scheduler or take ownership of native Whisper context lifetime away from the transcription layer.
