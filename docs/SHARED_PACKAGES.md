# Inkribe v1 — Shared Local Package Architecture

## Decision

Inkribe must be organized from the beginning so reusable product/domain code can be shared with a future iOS target without a later repo-wide extraction.

All reusable local Swift packages should declare these platform minimums:

```swift
platforms: [
    .macOS(.v15),
    .iOS(.v26),
]
```

The initial shipping app remains macOS-first. iOS is not part of v1 scope, but shared package boundaries must be iOS-ready from Phase 0.

## Core rule

Anything that can reasonably be reused by a future iOS target belongs in a shared local Swift package and must not depend on AppKit, MacAppFoundation, macOS windowing, or macOS-only UI concepts.

The macOS app target owns platform-specific UI and integration. Shared packages own portable domain/runtime behavior.

## Target repository structure

```text
Inkribe/
├── InkribeMac/                    # macOS app target
│   ├── App/
│   ├── Shell/
│   ├── Features/
│   ├── Developer/
│   └── Resources/
│
├── Packages/
│   ├── InkribeCore/               # shared domain types + policies
│   ├── InkribeAudio/              # shared audio abstractions + portable processing
│   ├── InkribeTranscription/      # JobQueue-backed transcription jobs/services
│   ├── InkribeAI/                 # cleanup/summarize prompt + chunking/domain logic
│   ├── InkribePersistence/        # shared transcript/library persistence contracts/models
│   ├── InkribeExport/             # TXT/Markdown/SRT/VTT generation
│   ├── WhisperRuntime/            # whisper.cpp wrapper
│   └── LLMRuntime/                # llama.cpp wrapper
│
├── Models/
├── testfixtures/
├── InkribeMacTests/
├── InkribeMacUITests/
├── scripts/
├── ci_scripts/
├── docs/
├── project.yml
└── Makefile
```

Exact package count may be consolidated during implementation if boundaries become artificially small, but the portability rules are mandatory.

## Package responsibilities

### InkribeCore

Own portable core types such as:

- transcript identifiers and metadata
- transcript/recording domain models
- language selection values
- transcription state
- AI action identifiers
- job/error domain types
- feature configuration that is not tied to StoreKit/macOS UI

Must not import AppKit or MacAppFoundation.

### InkribeAudio

Own portable audio-facing abstractions where practical:

- audio metadata
- portable decoding/normalization contracts
- buffer/file representations consumed by transcription
- duration/sample-rate/channel helpers

Platform capture implementations remain in the app target or thin platform adapters when APIs differ.

### InkribeTranscription

Own:

- transcription service contracts
- `TranscriptionJob` implementation
- JobQueue integration
- transcription job payload/state mapping
- segment/timestamp models
- language detection/request policy
- queue semantics exposed to app UI
- retry/cancellation rules

Dependencies:

```text
InkribeTranscription
├── JobQueue          # hoangbkit/JobQueue exact 1.0.0
├── WhisperRuntime
└── InkribeCore
```

Use `hoangbkit/JobQueue` exact version `1.0.0` for persistent scheduling, queue state, progress, pause/resume, cancellation, retry, restoration, and queue events. Do not implement a second queue scheduler/state machine inside Inkribe.

JobQueue `1.0.0` resolves to commit `e9046c09675b460f19fbc2bada5f8494b8def046`. It supports macOS 15+ and iOS 17+, so it is compatible with Inkribe's macOS 15+ / iOS 26+ package baseline.

The package must not import AppKit/SwiftUI presentation code.

### InkribeAI

Own:

- Clean / Polish / Summarize / Notes / Action Items action definitions
- prompt templates
- chunking/reassembly
- output validation/conservative transformation policy
- cancellation/progress domain behavior

The package may depend on `LLMRuntime`, but not on MacAppFoundation or macOS UI.

### InkribePersistence

Own shared persistence models/repositories where the implementation is available on both target platforms.

Do not leak macOS file-panel/bookmark/window assumptions into this package. Platform-specific file access adapters stay outside.

Transcript/library persistence remains distinct from JobQueue persistence: JobQueue stores processing records; Inkribe persistence stores transcript/media/domain content.

### InkribeExport

Own pure export generation for:

- plain text
- Markdown
- SRT
- VTT

Native save panels and clipboard integration remain platform-specific app-layer concerns.

### WhisperRuntime

Wrap `whisper.cpp` behind a narrow Swift API usable by both macOS 15+ and iOS 26+.

Requirements:

- no AppKit dependency
- model load/unload
- transcription
- language selection/detection
- segment timestamps
- progress/cancellation
- platform-specific acceleration selected internally where needed
- portable public API

### LLMRuntime

Wrap `llama.cpp` behind a narrow Swift API usable by both macOS 15+ and iOS 26+.

Requirements:

- no AppKit dependency
- model lifecycle
- generation/streaming
- sampling configuration
- progress/cancellation
- portable public API

## JobQueue dependency rule

Use:

```text
https://github.com/hoangbkit/JobQueue.git
exact version: 1.0.0
product: JobQueue
```

The dependency belongs in `InkribeTranscription`, not in the Mac UI layer merely for convenience.

The shared public abstraction should remain Inkribe-centric (`TranscriptionJob`, transcription services/state). UI code may observe queue-backed state, but should not scatter raw JobQueue details throughout unrelated features.

## macOS app target responsibilities

The macOS app target owns all explicitly Mac-only presentation/integration:

- custom NSWindow shell
- titlebar/sidebar/divider/sidebar-toggle animation
- MacAppFoundation integration
- macOS Settings scene
- onboarding window
- ProPlanButton / ProBadge / ProPaywallView / ProUpsellView
- Developer menu
- MacAppFoundation Developer Tools window
- Spokio-style Logs window UI
- microphone permission UI and macOS device selection
- drag/drop and NSOpenPanel/NSSavePanel integration
- durable import handoff into app-owned storage before queue enqueue
- Finder/menu commands
- macOS-specific shortcuts and lifecycle

These must not be pushed down into shared packages merely for convenience.

## Future iOS target

A future iOS app should be able to reuse the shared packages and provide only its own platform presentation/adapters:

```text
InkribeIOS
    ↓
InkribeCore
InkribeAudio
InkribeTranscription → JobQueue + WhisperRuntime
InkribeAI            → LLMRuntime
InkribePersistence
InkribeExport
```

The goal is not to force identical Mac/iOS UI. The goal is to share product logic, inference, data models, persistent transcription jobs, AI transforms, persistence contracts, and export logic.

## Package dependency direction

Keep dependencies one-way and acyclic:

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

Avoid package-to-app imports and avoid shared packages importing platform presentation frameworks.

## Phase 0 requirements

Phase 0 must:

- create the `Packages/` structure
- add local Swift Package manifests
- declare `.macOS(.v15)` and `.iOS(.v26)` on shared package manifests
- establish package dependency direction
- move portable domain types out of the app target from the beginning
- configure the project source to consume local packages
- add `hoangbkit/JobQueue` exact `1.0.0` through `InkribeTranscription`
- establish the app-scoped queue persistence/startup/registration wiring
- add package-level unit-test targets where useful
- keep all Mac-specific presentation and commerce dependencies out of shared packages

## Phase 3 requirements

`WhisperRuntime` and `LLMRuntime` must expose cross-platform Swift APIs and keep platform-specific acceleration details private.

Any macOS-only implementation detail must be behind internal conditional compilation rather than appearing in the public API.

## Phase 4 requirements

`InkribeTranscription` implements the durable `TranscriptionJob` backed by JobQueue.

Requirements:

- `Codable & Sendable` durable payload
- app-owned source media path/identifier, not a temporary file access handle
- progress reporting
- cancellation
- retry-safe transcript identity
- one concurrent Whisper transcription by default
- queue restoration across relaunch
- UI state derived from JobQueue records/progress rather than a duplicate state machine

See `docs/JOB_QUEUE.md` for the detailed contract.

## Feature-phase rule

During every later phase, before adding code directly to the macOS app target, ask whether the behavior is:

1. product/domain logic reusable on iOS, or
2. genuinely macOS-specific presentation/integration.

Reusable logic goes into the appropriate local package. Only category 2 remains in `InkribeMac`.

## Phase 0 architecture acceptance

Phase 0 is complete only when:

- shared package manifests use the macOS 15+ / iOS 26+ baseline
- no shared package imports AppKit
- no shared package imports MacAppFoundation
- `InkribeTranscription` owns the exact JobQueue `1.0.0` dependency
- the Mac app owns theme, commerce, onboarding, diagnostics, permissions, and platform UI concerns
- the dependency graph remains one-way and acyclic

## V1 acceptance criterion

Although Inkribe v1 ships only on macOS, its core product logic must already be organized so adding an iOS target later is primarily a new UI/platform-adapter effort rather than a domain/inference/job architecture rewrite.
