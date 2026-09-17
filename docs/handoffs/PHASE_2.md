# Phase 2 Handoff — Model Asset Pipeline

## Status

Phase 2 establishes the production model identity and asset-handling contract used by later native runtime work.

## Delivered

- Added cross-platform `InkribeModelAssets` package.
- Centralized both production model definitions in one bundled JSON manifest.
- Pinned immutable upstream revisions, filenames, exact byte counts, SHA-256 digests, and license identifiers.
- Added stable bundle lookup under one `Models/` root.
- Added explicit missing-model and integrity errors.
- Added streaming SHA-256 inspection so large files do not need to be loaded into memory at once.
- Added `ModelAssetTool` for deterministic production-model restore and integrity checks.
- Added retry, staging, digest checking, and atomic final publication behavior.
- Added tiny path-compatible fixtures under `testfixtures/Models/`.
- Added developer commands for restoring production assets, checking installed assets, and installing path fixtures.
- Connected `WhisperRuntime` and `LLMRuntime` to the shared asset descriptor contract.
- Kept production weights out of Git through the existing ignored `Models/` tree.

## Production model contract

Whisper:
- `Models/whisper/ggml-small.bin`
- Whisper Small multilingual
- revision `90a64d80ea254cf67575b41a5971f972c79f7b45`
- SHA-256 `1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b`

Local text model:
- `Models/qwen/Qwen3-1.7B-Q4_K_M.gguf`
- Qwen3 1.7B Q4_K_M
- revision `daeb8e2d528a760970442092f6bf1e55c3b659eb`
- SHA-256 `d2387ca2dbfee2ffabce7120d3770dadca0b293052bc2f0e138fdc940d9bc7b5`

`docs/MODEL_ASSETS.md` is authoritative for the detailed model-asset contract.

## Important implementation decisions

### One manifest

Download tooling and runtime-facing Swift code consume the same manifest. Future phases should update the manifest rather than duplicate model metadata in runtime code or scripts.

### No runtime model download

`ModelAssetTool` is developer/build tooling. The application runtime resolves bundled files only; it does not fetch weights at first launch or during normal use.

### Fixtures preserve paths, not inference

The committed fixtures intentionally preserve only the production path/filename contract. Phase 3 owns any inference-capable runtime fixtures needed by the native engine wrappers.

### Integrity before inference

Phase 3 should resolve each model through `InkribeModelAssets`, check it against the manifest, and only then pass its URL into whisper.cpp or llama.cpp.

## Deferred to Phase 3

- whisper.cpp source integration and model loading;
- llama.cpp source integration and model loading;
- Metal/CPU runtime policy;
- transcription/generation execution;
- inference progress and cancellation;
- native-runtime fixture strategy.
