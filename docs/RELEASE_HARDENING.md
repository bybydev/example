# Inkribe Release Hardening Contract

Phase 9 hardens the v1 source tree around offline execution, durable recovery, model integrity, persistence safety, and bundled notices.

## Offline application boundary

The shipping Inkribe application does not require direct network access for its core product workflow.

Release configuration keeps:

- App Sandbox enabled;
- hardened runtime enabled;
- incoming network connections disabled;
- outgoing network connections disabled;
- microphone access enabled;
- user-selected file access limited to read/write.

The app entitlement file contains no network client or network server entitlement.

A release regression scans Inkribe's shipped Swift source layers for direct use of `URLSession`, Network.framework connection APIs, WebKit network surfaces, and CFNetwork. The developer-only `ModelAssetTool` is intentionally outside that shipped-source scan because it restores pinned production assets before packaging and is not part of the app runtime.

## Queue recovery

`TranscriptionQueueController` remains the only Inkribe wrapper around JobQueue.

If persisted queue storage cannot load during application startup:

1. the transcript repository, durable media store, and queue controller remain owned by `InkribeAppState`;
2. the error remains visible through Diagnostics instead of silently resetting queue state;
3. **Retry Queue Storage** retries the same persisted store after it has become readable again;
4. **Reset Queue Storage** is an explicit destructive fallback for queue records only.

Resetting queue storage does **not** delete transcript documents, raw or edited text, timestamps, revisions, or saved AI results. It does remove persisted unfinished/retryable queue records, so Diagnostics requires explicit confirmation.

Regression coverage pins:

- pending jobs surviving relaunch;
- processing jobs recovering as pending work and completing once;
- cancellation propagation;
- failure → retry → completion;
- missing durable media failing repeatably without duplicate transcript creation;
- FIFO ordering with one transcription execution at a time;
- corrupt queue storage failing closed and recovering after repair;
- exact `TranscriptionJob` Codable payload round-trip.

## Transcript persistence safety

The JSON transcript repository fails closed on unreadable or unsupported durable state.

Phase 9 coverage verifies:

- unsupported snapshot versions do not rewrite or reset the original store;
- corrupt JSON is not interpreted as an empty library;
- duplicate transcript IDs fail explicitly;
- a failed durable write does not mutate the already-loaded in-memory cache;
- save/reload/delete semantics remain durable.

The durable transcript write remains the transcription commit point.

## Model integrity

Production model identity remains owned by `InkribeModelAssets`.

Phase 9 pins failure behavior for:

- missing model files;
- non-regular-file model paths;
- byte-count mismatch;
- SHA-256 mismatch;
- stable production relative paths;
- exact upstream license identifiers.

Committed tiny fixtures under `testfixtures/Models/` use the same public relative paths as production assets. They intentionally fail production integrity checks rather than impersonating real model weights.

## Third-party notices

`InkribeMac/Resources/ThirdPartyNotices.txt` is the bundled notice resource and is readable from Settings → About → Third-Party Notices.

The inventory covers the exact pinned releases/revisions used by v1:

- JobQueue 1.0.0 — MIT;
- SwiftLog 1.11.0 — Apache-2.0 plus upstream NOTICE;
- whisper.cpp 1.9.4 / b5130 — MIT;
- llama.cpp 0.4.1 / b10964 — MIT;
- Whisper Small multilingual model at revision `90a64d80ea254cf67575b41a5971f972c79f7b45` — upstream repository declares MIT;
- Qwen3 1.7B Q4_K_M at revision `daeb8e2d528a760970442092f6bf1e55c3b659eb` — upstream repository declares Apache-2.0.

MacAppFoundation 1.0.0 is first-party application infrastructure maintained by the Inkribe developer. Its pinned repository does not publish a separate license file, so Inkribe does not invent or assign one in third-party notices.

## Release identity

The source-level release contract pins:

- Release bundle identifier `com.hoangbkit.inkribe`;
- marketing version `1.0`;
- non-exempt encryption declaration disabled;
- microphone privacy usage description present;
- bounded privacy-safe diagnostics;
- no transcript, audio, prompt, generated AI result, or exported content in default logs.

## Ownership boundaries preserved

Phase 9 does not introduce a second scheduler, persistence layer, document representation, model downloader, or online fallback.

- JobQueue owns processing state.
- InkribePersistence owns transcript documents.
- InkribeModelAssets owns production model identity and integrity.
- WhisperRuntime and LLMRuntime own native inference state.
- InkribeAI owns transcript-AI prompt/chunk/merge semantics.
- The Mac application layer owns user-facing recovery, Settings, and notice presentation.
