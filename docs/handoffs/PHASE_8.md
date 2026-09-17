# Phase 8 Handoff — Settings, Performance, and Compatibility

## Status

Phase 8 is implemented on PR #10.

Inkribe now has a real Settings surface backed by persisted workflow preferences, explicit local model-memory policy, storage accounting/cleanup, and local runtime diagnostics. Runtime policy remains automatic and architecture-aware rather than exposing native inference knobs to users.

## Delivered

### Settings

MacAppFoundation `MacAppSettingsView` now hosts:

- General
- Transcription
- AI Cleanup
- Storage
- Appearance
- Plan
- Diagnostics
- About

General documents local privacy behavior and can reset workflow defaults without touching transcripts.

### Persisted workflow defaults

`InkribePreferences` is the single app-level owner for:

- default transcription language
- default microphone device ID / System Default
- keep-local-AI-model-loaded preference

Values normalize before persistence and survive new preference-store owners/relaunch.

### Shared language contract

`TranscriptionLanguageCatalog` moved language codes/names out of Mac UI so Record, Import, Settings, and transcription request mapping consume one contract.

Automatic maps to a `nil` Whisper language request; invalid persisted values fall back to Automatic.

### Recording / import integration

- Record starts from the persisted language default.
- Import starts from the persisted language default.
- Per-job language choices remain local overrides.
- Record exposes **System Default** microphone behavior.
- A specifically selected microphone is remembered by device ID.
- Temporarily unavailable saved microphones remain visible in Settings without blocking recording fallback.

### Runtime memory behavior

Whisper:

- `DefaultTranscriptionJobExecutor` now exposes `TranscriptionRuntimeManaging`.
- JobQueue keeps Whisper warm across an active batch.
- `TranscriptionQueueController` releases Whisper when the queue drains.

Local AI:

- Qwen is released after every completed/cancelled/failed AI action by default.
- Users can opt to keep it loaded for faster repeated AI actions.
- retention policy is injectable and directly testable.
- explicit unload refuses to run underneath active generation; a mid-run preference change is applied safely at completion.

No second scheduler or runtime state machine was introduced.

### Storage

The Storage pane reports:

- source-media bytes
- transcript-store bytes
- queue-store bytes
- transcript count
- combined mutable app-data size

Finished-source cleanup:

- preserves transcript content and derived AI results;
- clears `sourceMediaRelativePath` so playback state remains truthful;
- removes only media with no queue record or only completed queue records;
- skips unfinished/retryable/problem records;
- restores the old transcript media reference best-effort if deletion fails;
- cleans stale references when the media file is already missing.

### Diagnostics

The Diagnostics pane reports content-minimal local state:

- architecture
- processor count / physical memory
- Metal device
- effective Whisper backend/thread policy
- effective LLM backend/thread/context policy
- bundled model presence, identity, runtime version/build, pinned revision, expected size, and license
- JobQueue state/activity/record count
- startup and queue persistence issues

Diagnostics never includes transcript/audio/prompt/generated/exported content.

### Project wiring

The Mac target now directly links:

- `InkribeModelAssets`
- `WhisperRuntime`
- `LLMRuntime`

This is only for first-class runtime/model diagnostics; native C APIs remain encapsulated inside their runtime packages.

## Tests added

- transcription-language normalization / Automatic request mapping
- preference normalization, persistence, and reset
- AI model release-by-default behavior
- AI keep-loaded behavior and explicit unload
- safe source-media cleanup while preserving transcript content
- source-media cleanup skipping active queue work
- idle transcription runtime resource release contract

## Important invariants for Phase 9+

1. Settings owns durable product choices, not low-level native tuning knobs.
2. `InkribePreferences` remains the single owner of workflow defaults.
3. Record/Import may override language per job without silently changing the global default.
4. JobQueue remains the sole transcription scheduler.
5. Whisper remains warm only while useful queue work is active and is released on drain.
6. Qwen releases after local-AI work by default unless the user explicitly opts into retention.
7. Never unload a model underneath active inference.
8. Source-media cleanup must never destroy bytes needed by unfinished/retryable queue work.
9. Removing source media must not remove transcript text/timestamps/AI results.
10. Diagnostics remain local and content-minimal.
11. Apple Silicon/Intel runtime policy stays inside native runtime configuration, not feature UI branches.

## Next phase

Phase 9 should focus on final hardening and release polish: broaden important edge-case coverage, tighten remaining failure/recovery behavior, audit privacy/release surfaces, reconcile documentation, and prepare the product for shipping without changing the ownership contracts established in Phases 0–8.
