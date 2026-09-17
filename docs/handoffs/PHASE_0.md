# Phase 0 Handoff — Repository and Foundation

## Status

Phase 0 establishes the permanent repository and application foundation for later Inkribe phases.

The phase owns architecture and infrastructure boundaries only. Product shell, model assets, native inference implementations, recording/import workflows, persistent transcription jobs, transcript editing, local AI workflows, and exports remain assigned to their later phases.

## Delivered

### Repository and dependency foundation

- Added the project source configuration and root Makefile.
- Added repository ignore rules, including the production `Models/` directory.
- Pinned MacAppFoundation to exact version `1.0.0`.
- Pinned `swift-log` to exact version `1.11.0`.
- Pinned JobQueue to exact version `1.0.0` inside `InkribeTranscription`.
- Confirmed JobQueue `1.0.0` resolves to `e9046c09675b460f19fbc2bada5f8494b8def046`.
- Confirmed MacAppFoundation `1.0.0` resolves to `529e07d07e8370e8e1c78079fcd33b396e9160d1`.

### Shared package boundaries

Created the shared package layout targeting macOS 15+ and iOS 26+:

- `InkribeCore`
- `InkribeAudio`
- `InkribeTranscription`
- `InkribeAI`
- `InkribePersistence`
- `InkribeExport`
- `WhisperRuntime`
- `LLMRuntime`

Shared packages do not depend on AppKit or MacAppFoundation. Mac-specific presentation and commerce remain in `InkribeMac`.

### Core domain contracts

Added the first portable domain contracts:

- transcript identity and transcript model
- transcript segments and timestamps
- raw vs edited transcript content
- derived document kinds and source revision tracking
- portable language selection values
- durable media reference and audio metadata
- transcript repository protocol
- AI action identifiers
- export format identifiers
- Whisper runtime protocol/result boundary
- local LLM runtime request/protocol boundary

These are intentionally narrow foundations for later phases rather than partial feature implementations.

### JobQueue ownership

Added `TranscriptionQueueController` in `InkribeTranscription` with:

- a private JobQueue instance
- a private JobRegistry
- app-supplied durable queue storage URL
- queue-wide single-concurrency policy
- startup error state
- Inkribe-facing queue state mapping
- explicit persistent-job registration hook before queue startup

`TranscriptionJob` itself is intentionally deferred to Phase 4. No second Inkribe-owned scheduler or queue state machine was introduced.

### App-scoped foundation state

Added the Mac app foundation with one app-scoped owner for:

- `MacAppThemeStore`
- `MacAppSettingsRouter`
- `OnboardingState`
- `PurchaseManager`
- `InkribeAppState`
- the transcription queue controller

App startup is idempotent: repeated startup calls retain the same queue controller rather than creating competing owners for the same queue store.

### Commerce configuration

Configured the authoritative three-product catalog:

- Monthly: `com.hoangbkit.inkribe.pro.monthly`
- Yearly: `com.hoangbkit.inkribe.pro.yearly`
- Lifetime: `com.hoangbkit.inkribe.pro.lifetime`

Yearly is the preferred product. Debug purchase simulation uses the planned price points while release entitlement state remains backed by MacAppFoundation's production purchase path.

The exact Free/Pro feature matrix remains intentionally unset until product policy is finalized.

### Permissions and local storage

Added the app sandbox foundation for:

- microphone input
- user-selected read/write files

Added an app-owned Application Support directory and durable queue store location.

### Diagnostics

Added `swift-log` bootstrap before app service construction.

Debug builds include:

- normal console logging
- bounded 500-entry in-memory log storage
- dedicated Logs window
- whole-log copy
- per-row copy
- clear
- live append and auto-scroll
- MacAppFoundation Developer Tools window

The in-memory capture and Logs UI are excluded from release behavior. Logging conventions continue to prohibit transcript bodies, audio contents, and transcript-bearing prompts by default.

### Tests added

Added focused foundation tests for:

- transcript JSON round-trip including derived documents
- empty transcription queue startup
- app-state startup idempotence
- commerce product ordering and preferred product
- bounded debug log retention

## Architecture decisions carried forward

1. Transcript remains the central document model.
2. JobQueue is processing infrastructure owned through `InkribeTranscription`, not a UI dependency.
3. JobQueue uses exact `1.0.0`; later phases must not switch back to a moving branch.
4. Shared product logic remains portable to the future iOS target.
5. MacAppFoundation remains an app-layer dependency and does not own the Inkribe product shell.
6. Debug diagnostic state does not leak into release behavior.
7. App startup must keep one queue owner for one durable queue store.

## Deferred to later phases

### Phase 1

- final custom two-column Mac shell
- full-height structural divider
- animated divider-attached sidebar toggle
- Library / Record / Import navigation
- main-titlebar Pro control placement

### Phase 2

- production model manifest
- production/fixture asset layout
- download/checksum scripts

### Phase 3

- concrete `whisper.cpp` runtime
- concrete `llama.cpp` runtime
- model lifecycle, progress, cancellation, and acceleration behavior

### Phase 4

- durable `TranscriptionJob`
- media preparation before enqueue
- queue records/progress/actions for real transcription work
- retry-safe transcript persistence

Later phases continue with the Library/editor, local AI actions, export, settings/performance work, and release hardening described in `docs/V1_IMPLEMENTATION_PLAN.md`.

## Working rules

Repository phase workflow is recorded in `AGENTS.md`:

- one branch/PR per phase
- update docs and handoff before phase completion
- squash-merge only when the phase is genuinely complete
- do not merge blocked or materially incomplete work
- no GitHub Actions work as part of phase implementation
