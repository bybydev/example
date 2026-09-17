# Inkribe v1 — Architecture

## Architecture goals

Inkribe ships first as a native macOS 15+ app while organizing reusable product logic so a future iOS 26+ target can reuse the same domain, inference, persistence, job, and export layers.

Key constraints:

- fully offline core workflow
- bundled production models
- `whisper.cpp` for speech recognition
- `llama.cpp` for local text processing
- `hoangbkit/JobQueue` exact version `1.0.0` for persisted job orchestration
- XcodeGen-driven project
- Xcode Cloud test/archive workflows
- MacAppFoundation for shared Mac commerce/theme/settings/onboarding surfaces
- shared local Swift packages support macOS 15+ and iOS 26+

## High-level system

```text
┌─────────────────────────────────────────────────────────────────┐
│                         InkribeMac                               │
│  App lifecycle · custom shell · Settings · StoreKit · menus     │
│  recording UI · file panels · player UI · developer windows     │
└──────────────────────────────┬──────────────────────────────────┘
                               │
                  shared Swift package APIs
                               │
       ┌───────────────────────┼────────────────────────┐
       │                       │                        │
┌──────▼──────┐        ┌───────▼────────┐       ┌──────▼───────┐
│ InkribeCore │        │ Transcription  │       │  InkribeAI   │
│ domain data │        │ jobs/segments  │       │ prompts/tools│
└──────┬──────┘        └───────┬────────┘       └──────┬───────┘
       │                       │                        │
       │             ┌─────────┼──────────┐      ┌──────▼───────┐
       │             │                    │      │  LLMRuntime  │
       │      ┌──────▼───────┐    ┌──────▼────┐ │  llama.cpp   │
       │      │   JobQueue   │    │ Whisper   │ └──────────────┘
       │      │ persistence  │    │ Runtime   │
       │      │ scheduler    │    │whisper.cpp│
       │      └──────────────┘    └───────────┘
       │
┌──────▼──────────┐    ┌────────────────┐    ┌─────────────────┐
│   Persistence   │    │  InkribeAudio  │    │  InkribeExport │
│ local library   │    │ media contracts│    │ TXT/MD/SRT/VTT  │
└─────────────────┘    └────────────────┘    └─────────────────┘
```

`JobQueue` is infrastructure inside the shared transcription layer. It is not a UI framework and does not own transcript content.

## Repository layout

```text
Inkribe/
├── InkribeMac/
│   ├── App/
│   ├── Shell/
│   ├── Features/
│   │   ├── Library/
│   │   ├── Recorder/
│   │   ├── Import/
│   │   └── TranscriptEditor/
│   ├── Settings/
│   ├── Developer/
│   └── Resources/
│
├── Packages/
│   ├── InkribeCore/
│   ├── InkribeAudio/
│   ├── InkribeTranscription/   # depends on JobQueue + WhisperRuntime
│   ├── InkribeAI/
│   ├── InkribePersistence/
│   ├── InkribeExport/
│   ├── WhisperRuntime/
│   └── LLMRuntime/
│
├── Models/                  # gitignored; production/fixture substitution point
│   ├── whisper/
│   └── qwen/
├── testfixtures/
├── scripts/
├── ci_scripts/
├── docs/
├── project.yml
└── Makefile
```

Package count may be consolidated if implementation proves some boundaries artificially small. Dependency direction and portability matter more than exact package count.

## Platform boundaries

Shared package manifests declare:

```swift
platforms: [
    .macOS(.v15),
    .iOS(.v26),
]
```

Shared packages must not import:

- AppKit
- MacAppFoundation
- macOS window/menu APIs
- `NSOpenPanel` / `NSSavePanel`
- Mac-only entitlement/StoreKit presentation code

The future iOS app consumes the same shared packages and supplies new UI/platform adapters rather than duplicating or extracting domain logic.

JobQueue `1.0.0` supports macOS 15+ and iOS 17+, so using it from `InkribeTranscription` is compatible with Inkribe's iOS 26 baseline.

## Dependency direction

Dependencies remain acyclic and flow inward:

```text
InkribeMac
   ↓
feature/domain packages
   ↓
InkribeCore

InkribeTranscription → JobQueue
InkribeTranscription → WhisperRuntime
InkribeAI            → LLMRuntime
```

Forbidden patterns:

- shared package importing the app target
- runtime wrapper importing feature UI
- persistence layer knowing about window/sidebar state
- domain layer checking StoreKit entitlement directly
- MacAppFoundation referenced by cross-platform packages
- app feature view models implementing their own queue scheduler/state machine beside JobQueue

## JobQueue dependency

Use:

```text
https://github.com/hoangbkit/JobQueue.git
exact version: 1.0.0
product: JobQueue
```

Tag `1.0.0` resolves to commit `e9046c09675b460f19fbc2bada5f8494b8def046`.

`InkribeTranscription` declares the dependency and exposes Inkribe-specific job/service APIs to the app. The stable tag is intentional: Inkribe does not follow a moving JobQueue branch.

See `docs/JOB_QUEUE.md` for the complete integration contract.

## Domain model

The central product object is a **Transcript**.

Conceptual entities:

```text
Transcript
├── id
├── title
├── createdAt / updatedAt
├── sourceMedia
├── language
├── duration
├── rawText
├── editedText
├── segments[]
├── derivedDocuments[]
└── processingMetadata

TranscriptSegment
├── id
├── start
├── end
└── text

DerivedDocument
├── kind: summary | notes | actionItems | cleanedCopy | polishedCopy
├── content
├── createdAt
└── sourceRevision
```

Recordings and imported files become transcript source media. They are not a second competing document model.

## Job architecture

The v1 persistent processing unit is `TranscriptionJob: Job`.

Its payload contains only durable Codable values such as:

```text
transcriptID
sourceMediaRelativePath
requestedLanguage
```

Do not capture runtime objects, file handles, security scopes, SwiftUI/AppKit state, model instances, or closures in job payloads.

Imported media should be copied or normalized into app-owned durable storage before enqueueing. This guarantees that a queued job can execute after relaunch without depending on a temporary file-picker or drag/drop security scope.

Register job types before starting the queue:

```swift
try JobRegistry.shared.register(TranscriptionJob.self)
try queue.start()
```

Start with `TranscriptionJob.maxConcurrentExecutions = 1`. Whisper inference is resource-heavy, and parallel transcription should not be enabled unless profiling proves it improves the product.

JobQueue remains the source of truth for processing state. Inkribe transcript persistence remains the source of truth for completed transcript content.

## Queue state/UI mapping

The Import/Queue UI observes JobQueue records and live progress rather than maintaining a second state machine.

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

Retry/cancel/pause/resume semantics come from JobQueue.

A successful job persists transcript output before returning success. Retry must update the intended `transcriptID` instead of silently creating duplicate transcript records.

## Transcription pipeline

```text
record/import media
      ↓
copy/normalize into app-owned storage
      ↓
create/enqueue TranscriptionJob
      ↓
JobQueue persists + schedules
      ↓
WhisperRuntime.loadModel
      ↓
WhisperRuntime.transcribe
      ↓
JobProgressReporter updates UI
      ↓
segments + detected language
      ↓
persist transcript
      ↓
JobQueue marks completion
      ↓
open/refresh Transcript Editor
```

Required behavior:

- expensive work off the main actor
- progress callbacks
- cancellation propagation
- deterministic queue transitions
- persistent queue restoration
- one safe owner for model runtime state
- actionable errors
- structured diagnostics without transcript/audio contents

## Local AI pipeline

```text
Transcript revision
      ↓
selected action
      ↓
prompt builder
      ↓
chunking if needed
      ↓
LLMRuntime generation
      ↓
reassembly / validation
      ↓
preview or derived document
      ↓
explicit user apply/save
```

Rules:

- prompts are versioned
- instructions emphasize meaning preservation and no invented facts
- long transcripts are chunked explicitly rather than silently truncated
- cancellation/progress are supported
- Clean/Polish never silently overwrite the original
- Summary/Notes/Action Items are stored as derived outputs

V1 does not need to force AI transforms through JobQueue unless later requirements need persisted/background AI jobs. Keep JobQueue's initial responsibility focused on durable transcription/import processing.

## Model asset architecture

Production and test CI use the same runtime paths:

```text
Models/
├── whisper/<model>
└── qwen/<model.gguf>
```

Test workflows:

```text
testfixtures/
      ↓ copy
Models/
      ↓
build + tests
```

Release/archive workflows:

```text
pinned model URLs
      ↓
temporary downloads
      ↓
SHA-256 + shape validation
      ↓
Models/
      ↓
archive
```

Application code never branches on fixture-vs-production paths.

## Model downloader requirements

`scripts/download-models.sh` must:

- use `set -euo pipefail`
- use immutable/pinned model revisions
- download to temporary files
- retry transient failures
- validate SHA-256
- move atomically only after validation
- reuse an existing file only if its checksum is valid
- redownload corruption automatically

`scripts/validate-models.sh` independently verifies required names/paths/checksums and fails the build on mismatch.

## XcodeGen / package resolution / Xcode Cloud

`project.yml` is authoritative, but the generated `.xcodeproj`, shared schemes, and resolved package state required by Xcode Cloud are committed.

Do not rely on generating the project in `ci_post_clone.sh`; Xcode Cloud may resolve packages before that point.

`ci_post_clone.sh` prepares model assets, not project structure.

JobQueue is pinned to exact version `1.0.0`; correctness does not depend on a moving branch.

## MacAppFoundation boundary

MacAppFoundation is used only by the Mac application layer for:

- `MacAppThemeStore`
- `MacAppSettingsView` / routing
- onboarding window/state/view
- `PurchaseManager`
- `ProPlanButton`
- `ProBadge`
- `ProPaywallView`
- `ProUpsellView`
- Debug Developer Tools

Inkribe still owns:

- custom main shell geometry
- navigation hierarchy
- transcript/editor/product workflows
- feature policy
- model/inference architecture
- JobQueue integration through shared product packages

## Commerce architecture

StoreKit product IDs:

```text
com.hoangbkit.inkribe.pro.monthly
com.hoangbkit.inkribe.pro.yearly
com.hoangbkit.inkribe.pro.lifetime
```

`PurchaseManager` verified StoreKit state is the production entitlement source of truth.

Feature access flows through centralized app-layer policy rather than direct entitlement checks spread through shared packages.

## Persistence

Persistence is local-only in v1.

Architecture rules:

- repository/service APIs hide database details from feature UI
- persistent models stay portable between macOS/iOS where practical
- JobQueue persists processing state; Inkribe persistence stores transcript/library content
- distinguish original/raw transcript from edited/derived content
- deletion semantics are explicit for source media vs transcript metadata
- queue retry cannot create duplicate transcript records
- persistence implementation may evolve without changing feature-domain APIs

## Concurrency

Use Swift concurrency deliberately:

- UI state updates on `@MainActor`
- JobQueue owns serialized queue state
- media decode, Whisper inference, and LLM inference stay off the main actor where appropriate
- runtime wrappers own synchronization of native C/C++ state
- cancellation propagates UI → JobQueue job → service/runtime
- transcription defaults to one concurrent execution
- avoid detached tasks with unclear lifetime

## Logging

Bootstrap `swift-log` before app services.

Debug builds multiplex logs to:

1. normal development console output
2. bounded in-memory `LogStore`
3. standalone Logs window

Release builds do not retain the Debug in-memory log buffer or expose the Logs window.

JobQueue events should feed privacy-safe diagnostics for enqueue, start, progress milestones, completion, failure, cancellation, persistence failure, and restoration issues.

Never log transcript bodies, raw audio, or prompts containing transcript content by default.

## Window/scene architecture

Mac app scenes:

```text
Main Window
Settings
Onboarding Window
Pro Paywall surface/window
Developer Tools Window      # Debug only
Logs Window                 # Debug only
```

The custom main shell uses native `NSWindow` behavior underneath a custom visible titlebar/sidebar arrangement.

## Testing architecture

### Unit tests

Cover:

- domain state transitions
- timestamp math
- prompt generation
- chunking/reassembly
- export formatting
- persistence repositories
- model manifest/path/checksum logic
- `TranscriptionJob` Codable round trip
- JobQueue status-to-UI mapping

### JobQueue integration tests

Cover:

- registration/restoration
- persisted pending jobs across relaunch
- failure → retry → completion
- cancellation
- progress propagation
- multi-file ordering
- transcription single-concurrency
- missing source media
- queue persistence failure handling
- duplicate transcript prevention on retry

### Runtime tests

Cover:

- fixture model discovery/load paths
- missing/corrupt model failures
- cancellation
- real local Whisper smoke test
- real local Qwen cleanup smoke test where practical

### Integration tests

Cover:

- media → durable app storage → JobQueue → decode → transcription → persisted transcript
- app relaunch with queued work
- transcript → AI transform
- transcript → subtitle export
- persistence round trip

### UI tests

Cover:

- shell geometry
- sidebar animation/collapse persistence
- Library/Record/Import/Editor flows
- queue state/progress/cancel/retry presentation
- Settings routing
- Pro routing
- Debug Developer Tools and Logs windows

## Future iOS target

The architecture succeeds if adding `InkribeIOS` later primarily requires:

- iOS navigation/UI
- iOS microphone/file-picker adapters
- iOS lifecycle/permissions
- iOS commerce/foundation integration

while reusing:

- transcript domain types
- `TranscriptionJob` and JobQueue orchestration
- Whisper runtime
- AI actions and llama runtime
- persistence layer/contracts
- export generation
- model manifests/validation concepts

No v1 Mac-only UI requirement should leak into those shared package APIs.
