# Phase 9 Handoff — Release Hardening and Regression Coverage

## Status

Phase 9 is implemented on PR #11.

This is the final implementation phase in the Inkribe v1 plan. The source tree now has explicit recovery behavior for damaged queue storage, stronger durable-state and model-integrity regressions, an enforced offline application boundary, and bundled third-party notices.

## Delivered

### Offline boundary

- outgoing application network access removed from release configuration
- incoming network access remains disabled
- App Sandbox, hardened runtime, microphone, and user-selected file access remain explicit
- regression scan prevents direct network client APIs from quietly entering shipped Inkribe source layers
- developer-only model download tooling remains outside the app runtime boundary

### Queue and recovery hardening

- pending queue restoration completes after relaunch
- interrupted processing records recover without duplicate records
- exact transcription job Codable round trip
- missing durable media fails/retries without duplicate transcript creation
- FIFO multi-file execution remains single-concurrency
- corrupt persisted queue state fails closed
- repaired queue storage can be retried without recreating the pipeline
- failed startup retains queue/repository/media ownership for recovery
- Diagnostics exposes Retry Queue Storage
- Diagnostics exposes explicitly destructive Reset Queue Storage
- queue reset preserves transcript documents

### Transcript persistence hardening

- unsupported store versions fail without rewriting the file
- corrupt transcript JSON fails without silent empty fallback
- duplicate IDs continue to fail explicitly
- failed durable writes do not poison the loaded repository cache

### Model and asset hardening

- missing model path regression
- non-regular-file regression
- byte-count mismatch regression
- SHA-256 mismatch regression
- exact production license identifiers pinned
- committed fixtures verified to use production-relative paths while remaining intentionally non-production weights

### Notices and release source contract

- bundled `ThirdPartyNotices.txt`
- SwiftLog upstream NOTICE retained
- exact pinned software/model inventory
- Third-Party Notices browser in Settings → About
- release identity/privacy/sandbox regression tests
- `docs/RELEASE_HARDENING.md`
- queue recovery contract documented in `docs/JOB_QUEUE.md`
- README updated for the final v1 hardening boundary

## Important final invariants

1. Inkribe's core Record → Transcribe → Edit → Local AI → Export path has no direct network fallback.
2. Corrupt durable state fails closed; it is never silently replaced with an empty store.
3. Queue recovery never deletes transcript documents implicitly.
4. Reset Queue Storage is explicit and affects JobQueue records only.
5. A retry never creates a second transcript for the same persisted transcription job.
6. Production model files are accepted only at pinned paths with exact size and SHA-256.
7. Tiny fixtures may exercise path/error contracts but must never pass production integrity checks.
8. Raw Whisper text remains separate from Edited text through retry, AI, export, and recovery.
9. User content is excluded from default diagnostics.
10. Third-party license/version provenance is shipped with the app and accessible from About.

## V1 implementation state

There is no Phase 10 in the current v1 implementation plan. Future product work should start from the contracts established by Phases 0–9 rather than weakening their ownership, privacy, persistence, or offline guarantees.
