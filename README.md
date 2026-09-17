# Inkribe

Inkribe is a macOS-first, fully offline speech-to-text workspace built around durable transcript documents.

The v1 product flow is:

```text
Record or Import → Transcribe → Review/Edit → Clean/Polish/Summarize → Export
```

Core transcription and transcript AI use bundled local models. The architecture keeps reusable domain, persistence, transcription, AI, export, runtime, and model-asset logic in shared packages so a future iOS target can reuse the same product core without a repo-wide extraction.

## Repository structure

```text
InkribeMac/                  Mac app lifecycle, shell, UI, commerce, diagnostics
Packages/
  InkribeCore/               Transcript and domain types
  InkribeAudio/              Durable media, decoding, and recording services
  InkribeTranscription/      JobQueue-backed transcription orchestration
  InkribeAI/                 Local AI prompts, chunking, merge, result contracts
  InkribePersistence/        Durable transcript repository
  InkribeExport/             Transcript text/subtitle formatting contracts
  InkribeModelAssets/        Pinned model metadata, paths, integrity, tooling
  WhisperRuntime/            actor-isolated whisper.cpp inference boundary
  LLMRuntime/                actor-isolated llama.cpp generation boundary
scripts/                     Model asset developer commands
testfixtures/                Tiny path-compatible model fixtures
docs/                        Product, architecture, shell, and phase documentation
```

Shared packages target macOS 15+ and iOS 26+ and must not depend on AppKit or MacAppFoundation.

## Foundation dependencies

- `hoangbkit/JobQueue` exact `1.0.0`
- `hoangbkit/MacAppFoundation` exact `1.0.0`
- `apple/swift-log` exact `1.11.0`

JobQueue belongs to `InkribeTranscription`, not the app UI layer. MacAppFoundation belongs to the Mac application layer for themes, commerce, onboarding, settings, window chrome, and developer surfaces.

## Bundled model assets

Production model metadata is centralized in `Packages/InkribeModelAssets/Sources/InkribeModelAssets/Resources/ModelAssets.json`.

Current v1 assets:

- Whisper Small multilingual → `Models/whisper/ggml-small.bin`
- Qwen3 1.7B Q4_K_M → `Models/qwen/Qwen3-1.7B-Q4_K_M.gguf`

Use `make download-models` to restore production weights, `make verify-models` to check their pinned size and SHA-256, and `make install-model-fixtures` to populate the same paths with tiny development fixtures.

See `docs/MODEL_ASSETS.md` for the authoritative asset contract.

## Native inference

The reusable native runtime packages pin upstream Apple inference artifacts and keep direct C APIs internal:

- `WhisperRuntime` → whisper.cpp `1.9.4` / binary `b5130`
- `LLMRuntime` → llama.cpp `0.4.1` / binary `b10964`

Both runtimes own model/context lifetime explicitly and serialize mutable native state through actors. Recommended policy uses Metal on Apple Silicon and CPU inference on Intel. Runtime diagnostics record operational metadata only, never transcript, audio, prompt, or generated content.

See `docs/NATIVE_RUNTIMES.md` for native dependency pins, lifecycle, cancellation, sampling, audio, and prompt-layer boundaries.

## Local transcription pipeline

Record and Import feed the same durable pipeline:

```text
app-owned media
  → persistent TranscriptionJob
  → 16 kHz mono decode
  → WhisperRuntime
  → durable Transcript
```

Record supports input-device selection, pause/resume, metering, and durable capture. Import supports multi-file selection and drag/drop for audio and video sources. JobQueue remains the single processing-state owner, while `InkribePersistence` remains transcript-content truth. Retries update the same transcript and preserve user-edited text once it has diverged from raw transcription.

See `docs/TRANSCRIPTION_PIPELINE.md` and `docs/JOB_QUEUE.md` for the durable storage, retry, cancellation, and ownership contracts.

## Local transcript workspace

The Library and transcript editor operate directly on durable transcript documents produced by the transcription pipeline.

Library capabilities include local title/content search, newest/oldest/title sorting, rename, delete with active-job protection, source-media cleanup, and direct navigation to transcript documents.

The transcript editor keeps Raw Whisper output separate from user/AI Edited text, persists edits with revision tracking, retains timestamped segments, supports transcript search, and plays the original app-owned audio/video source with seek, scrub, ±10 second skip, segment seeking, and current-segment highlighting. Missing media disables playback without making transcript content unavailable.

See `docs/TRANSCRIPT_WORKSPACE.md` for the Library/editor ownership, persistence, deletion, playback, and local-AI integration contracts.

## Offline local AI

The transcript editor includes five constrained local AI actions using the bundled Qwen model through `LLMRuntime`:

- Clean
- Polish
- Summarize
- Notes
- Action Items

AI generation uses the current Edited text when available, otherwise Raw text. Prompts are versioned and treat transcript content as untrusted data. Long transcripts are chunked in source order, with adaptive re-splitting when the runtime reports that a token-dense prompt exceeds context capacity.

Results are always previewed before mutation. Clean and Polish may replace Edited text or be saved as a copy. Summary, Notes, and Action Items are stored as revision-tagged derived documents. Raw Whisper text is never overwritten, and stale AI results are rejected if the transcript changes while generation is running.

Generation is cancellable and fully local: no account, API key, cloud service, remote provider, or network fallback is part of the AI path.

See `docs/LOCAL_AI.md` for prompt, chunking, merge, progress, revision, persistence, privacy, and entitlement-boundary contracts.

## Export and finishing

The active transcript can be copied or exported without leaving the local document workflow:

- Copy Edited transcript
- Copy Raw transcript
- TXT from Edited or Raw text
- Markdown from Edited or Raw text
- SRT from timestamped transcript segments
- WebVTT from timestamped transcript segments

Text export preserves the selected source exactly; there is no hidden Raw/Edited fallback. Subtitle export stays segment-based because Edited prose does not have timestamp alignment. Valid overlapping cue timestamps are preserved, malformed durations are minimally repaired, and filenames are generated safely from the transcript title and creation date.

Formatting lives in the cross-platform `InkribeExport` package. Clipboard and save-panel presentation remain Mac-only, and export never mutates the durable transcript.

See `docs/EXPORT.md` for source-selection, filename, subtitle, privacy, and Mac finishing-workflow contracts.

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
- The main Mac window uses one permanent two-column shell; feature phases fill its content rather than recreating navigation/window geometry.
- Production model identities, paths, revisions, byte counts, and digests come from one manifest.
- Native model/context state stays inside actor-isolated runtime packages.
- Raw Whisper transcript text remains separate from user/AI edited text.
- AI generation never mutates transcript content until the user explicitly applies or saves a previewed result.
- Generated AI results are revision-aware so stale work cannot overwrite newer transcript edits.
- Text export uses explicit Edited/Raw source selection; subtitle export uses timestamped segments.
- Export never mutates transcript persistence or routes work through JobQueue/model runtimes.
- User transcript/audio/prompt/generated/exported contents are not written to diagnostic logs by default.
- Debug diagnostics are isolated from release behavior.

See `docs/ARCHITECTURE.md`, `docs/SHARED_PACKAGES.md`, `docs/JOB_QUEUE.md`, `docs/SHELL.md`, `docs/MODEL_ASSETS.md`, `docs/NATIVE_RUNTIMES.md`, `docs/TRANSCRIPTION_PIPELINE.md`, `docs/TRANSCRIPT_WORKSPACE.md`, `docs/LOCAL_AI.md`, and `docs/EXPORT.md` for the detailed contracts.

## Development workflow

Implementation proceeds phase by phase. Each phase uses its own pull request, updates its documentation and handoff before completion, and is squash-merged only when genuinely complete.

See `AGENTS.md` for the repository working rules and `docs/V1_IMPLEMENTATION_PLAN.md` for the implementation sequence.
