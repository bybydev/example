# Inkribe

Inkribe is a macOS-first, fully offline speech-to-text workspace built around durable transcript documents.

The v1 product flow is:

```text
Record or Import → Transcribe → Review/Edit → Clean/Polish/Summarize → Export
```

Core transcription uses bundled local models. The architecture keeps reusable domain, persistence, transcription, AI, export, and runtime logic in shared packages so a future iOS target can reuse the same product core without a repo-wide extraction.

## Repository structure

```text
InkribeMac/                  Mac app lifecycle, UI, commerce, diagnostics
Packages/
  InkribeCore/               Transcript and domain types
  InkribeAudio/              Portable audio contracts
  InkribeTranscription/      JobQueue-backed transcription orchestration
  InkribeAI/                 Local AI action/domain layer
  InkribePersistence/        Transcript repository contracts
  InkribeExport/             Export-domain contracts
  WhisperRuntime/            whisper.cpp runtime boundary
  LLMRuntime/                llama.cpp runtime boundary
docs/                        Product, architecture, and phase documentation
```

Shared packages target macOS 15+ and iOS 26+ and must not depend on AppKit or MacAppFoundation.

## Foundation dependencies

- `hoangbkit/JobQueue` exact `1.0.0`
- `hoangbkit/MacAppFoundation` exact `1.0.0`
- `apple/swift-log` exact `1.11.0`

JobQueue belongs to `InkribeTranscription`, not the app UI layer. MacAppFoundation belongs to the Mac application layer for themes, commerce, onboarding, settings, and developer surfaces.

## Product identity

- Bundle identifier: `com.hoangbkit.inkribe`
- Monthly Pro: `com.hoangbkit.inkribe.pro.monthly`
- Yearly Pro: `com.hoangbkit.inkribe.pro.yearly`
- Lifetime Pro: `com.hoangbkit.inkribe.pro.lifetime`

See `docs/PRODUCT_CONFIGURATION.md` for the authoritative catalog configuration.

## Architecture rules

- Transcript is the central document model.
- Record and Import are creation paths, not separate product silos.
- JobQueue owns persisted processing state; Inkribe persistence owns transcript/library content.
- Reusable product logic stays in shared packages.
- Mac-only presentation and integration stay in `InkribeMac`.
- User transcript/audio contents are not written to diagnostic logs by default.
- Debug diagnostics are isolated from release behavior.

See `docs/ARCHITECTURE.md`, `docs/SHARED_PACKAGES.md`, and `docs/JOB_QUEUE.md` for the detailed contracts.

## Development workflow

Implementation proceeds phase by phase. Each phase uses its own pull request, updates its documentation and handoff before completion, and is squash-merged only when genuinely complete.

See `AGENTS.md` for the repository working rules and `docs/V1_IMPLEMENTATION_PLAN.md` for the implementation sequence.
