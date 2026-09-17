# Inkribe v1 — JobQueue Integration

## Decision

Inkribe v1 uses `hoangbkit/JobQueue` **exact version `1.0.0`** for persistent background job orchestration.

Do not build a second queue/scheduler/persistence layer inside Inkribe. Inkribe owns its job payloads and execution logic; `JobQueue` owns queue state, persistence, scheduling, retry/cancel/pause behavior, progress state, restoration, and queue events.

Dependency source:

```text
https://github.com/hoangbkit/JobQueue.git
version: 1.0.0
product: JobQueue
```

Tag `1.0.0` resolves to commit `e9046c09675b460f19fbc2bada5f8494b8def046`.

At planning time, `JobQueue` declares macOS 15+ and iOS 17+, so it is compatible with Inkribe shared packages targeting macOS 15+ and iOS 26+.

Use the stable tag rather than a moving branch. `Package.resolved` may still be committed for Xcode/Xcode Cloud reproducibility, but correctness must not depend on tracking `master`.

## Ownership boundary

### JobQueue owns

- persisted `Codable` job records
- pending / processing / cancelling / pausing / completed / failed / cancelled / unrecoverable states
- progress reporting
- queue and per-job-type concurrency limits
- priority
- pause/resume
- retry
- cancellation
- queue restoration after relaunch
- persistence failure reporting/recovery
- queue events
- record cleanup

### Inkribe owns

- `TranscriptionJob` payload schema
- media preparation before enqueue
- Whisper execution
- transcript persistence
- mapping queue records to Inkribe UI
- user-facing error copy
- transcript/library navigation after completion
- privacy-safe diagnostic logging

## Package placement

`InkribeTranscription` is the shared local package that integrates with `JobQueue`.

```text
InkribeMac
    ↓
InkribeTranscription
    ├── JobQueue
    └── WhisperRuntime
```

`InkribeTranscription` still targets:

```swift
.macOS(.v15)
.iOS(.v26)
```

It must not import AppKit or MacAppFoundation.

Suggested package dependency:

```swift
.package(
    url: "https://github.com/hoangbkit/JobQueue.git",
    exact: "1.0.0"
)
```

and target dependency:

```swift
.product(name: "JobQueue", package: "JobQueue")
```

For XcodeGen, use the equivalent exact-version package declaration rather than a branch dependency.

## Transcription job

Define one persistent v1 job type for the complete media-to-transcript operation.

Conceptually:

```swift
struct TranscriptionJob: Job {
    struct Payload: Codable, Sendable {
        let transcriptID: UUID
        let sourceMediaRelativePath: String
        let requestedLanguage: String?
    }

    static let maxConcurrentExecutions = 1

    let id: UUID
    let payload: Payload

    var title: String? { /* source/transcript title */ }
    var detail: String? { /* language / media detail */ }
    var priority: JobPriority { .userInitiated }

    func execute(progress: JobProgressReporter) async throws {
        // resolve app-owned media
        // normalize/decode if necessary
        // load/use WhisperRuntime
        // report progress
        // persist transcript result
    }
}
```

The concrete implementation may split media normalization into shared services, but v1 should avoid creating several tiny dependent queue jobs unless a real need appears.

### Concurrency

Start with:

```swift
TranscriptionJob.maxConcurrentExecutions = 1
```

Whisper is CPU/GPU/memory intensive, and parallel transcription would usually make the Mac less responsive rather than improve throughput. Revisit only after profiling.

The queue-wide policy may allow other job types in the future, but transcription remains single-concurrency by default.

## Durable payload rule

A queued job must remain executable after app relaunch.

Therefore the payload must contain only durable, `Codable`, portable identifiers/values. It must not capture:

- runtime objects
- `NSFileHandle`
- security-scoped access sessions
- model instances
- SwiftUI/AppKit state
- closures

For imported files, copy/normalize the source into Inkribe-controlled app storage before enqueueing, then store a stable relative path or asset identifier in the job payload. This avoids relying on a temporary drag/drop or file-picker security scope after relaunch.

## Registry and startup

Register all persistent job types before starting the queue:

```swift
try JobRegistry.shared.register(TranscriptionJob.self)
try queue.start()
```

Registration must occur early enough that persisted jobs can be restored correctly.

If a stored record references a job type that cannot be restored, surface the resulting unrecoverable state in developer diagnostics and an appropriate user-facing recovery path.

## Queue construction

Create one app-scoped queue with an app-owned persistence URL.

Conceptually:

```swift
let queue = JobQueue(
    fileURL: jobStoreURL,
    policy: JobQueuePolicy(maxConcurrentExecutions: 1),
    registry: .shared,
    maxRecords: 100,
    autoCleanupEnabled: true
)
```

The exact record limit can be adjusted after real usage testing.

## UI mapping

Use JobQueue state directly instead of duplicating queue state in a second model.

Suggested presentation mapping:

```text
JobStatus.pending        → Waiting
JobStatus.processing     → Transcribing
JobStatus.pausing        → Pausing
JobStatus.cancelling     → Cancelling
JobStatus.completed      → Complete
JobStatus.failed         → Failed
JobStatus.cancelled      → Cancelled
JobStatus.unrecoverable  → Needs attention
```

`JobProgress` drives the visible per-file progress bar/message.

The Import/Queue screen observes queue records and progress, then adds only Inkribe-specific display data/navigation.

## User actions

Use JobQueue's supported actions for:

- cancel job
- retry failed/cancelled job
- remove record where appropriate
- pause/resume queue if exposed in v1
- clear completed records where appropriate

Do not reimplement retry/cancel state transitions in feature view models.

## Completion behavior

On successful transcription:

1. persist the transcript and timestamped segments before the job returns success;
2. leave the queue record as completed according to JobQueue policy;
3. refresh/open the corresponding transcript from Inkribe's persistence layer;
4. never store the full transcript body inside queue metadata merely for UI convenience.

The transcript database/library remains the source of truth for completed transcript content. JobQueue is the source of truth for processing state.

## Logging

Attach a queue event handler and route lifecycle events to Inkribe's Debug logging pipeline.

Log:

- enqueue/start/completion/failure/cancellation
- progress milestones where useful
- persistence failures
- queue restoration issues

Do not log transcript text, audio contents, or prompts.

## Failure and recovery

- Failed and cancelled jobs remain retryable according to JobQueue state.
- Queue persistence failures must be visible in Debug diagnostics.
- A transcription job must be idempotent enough that retrying cannot silently create duplicate transcript records.
- Use `transcriptID`/job identity to update the intended transcript record rather than creating a new unrelated record on every retry.
- A partially written output must never be mistaken for a completed transcript.

## Testing

Add tests for:

- `TranscriptionJob` Codable round trip
- registry registration/restoration
- queue persistence across relaunch
- pending processing after restart
- progress propagation
- cancellation
- failure → retry → completion
- duplicate transcript prevention on retry
- multi-file ordering
- single-concurrency transcription behavior
- missing source media recovery
- JobQueue persistence failure handling
- macOS 15 build
- iOS 26 shared-package build

## Phase mapping

### Phase 0

- add `JobQueue` dependency pinned to exact `1.0.0`
- make `InkribeTranscription` depend on the `JobQueue` product
- create app-scoped queue storage/configuration
- establish startup registration pattern
- keep `Package.resolved` consistent with the exact tag for Xcode/Xcode Cloud reproducibility

### Phase 4

- implement `TranscriptionJob`
- copy imported media into durable app-owned storage before enqueue
- use JobQueue for multi-file processing, persistence, progress, cancellation, retry, pause/resume state, and restoration
- wire queue events into Debug logs
- build Queue UI from JobQueue records/progress instead of a duplicate state machine

### Phase 9

- test queue restoration and retry behavior in integration tests
- verify Xcode Cloud resolves JobQueue `1.0.0`
- verify a release can resume/recover persisted jobs without networking

## Acceptance criteria

JobQueue integration is complete when:

- no separate Inkribe queue scheduler/state machine exists
- multiple imports enqueue as persistent `TranscriptionJob` records
- queued/running/failed/completed state survives relaunch correctly
- progress is visible in UI
- cancel and retry work
- transcription concurrency defaults to one
- completed transcript content lives in Inkribe persistence, not queue metadata
- the shared transcription package builds for macOS 15 and iOS 26
- dependency is pinned to `hoangbkit/JobQueue` exact version `1.0.0`
