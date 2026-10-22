# V1 decisions

## Settled, 2026-10-22

- Compact v1 list replaces the exhaustive catalog. Current V1 IDs and P0–P7 briefs are authoritative; old Fxx totals are superseded.
- Local native caption workflow, AppFoundation and useful existing portable packages. Preserve Mac.
- Stable identities/revisions, safe originals, atomic project persistence, honest raw/edited timing and deterministic preview/export.
- P7 now means hardening. P8–P13 retired. Incoming share extension removed.
- Existing P1 extras are recorded source, not requirements. This update removes no app/UI code.
- PR #24 was subsequently squash merged; P2 #25 was subsequently squash merged. P3 stays open. No builds/tests/CI/project generation/model downloads/device checks.

## Necessary owning-phase choices

| Phase | Choice | Boundary |
|---|---|---|
| P2 | Compatible local model, packaging and word-timing method | No automatic Mac Qwen/diarization or downloads |
| P3 | Compact preview/transport, overview scrubber, correction/list, timing disclosures and undo | Source-integrated after user request/stated plan; runtime unverified |
| P4 | Curated fonts/templates and four effect defaults | No marketplace/custom font/brand system |
| P5 | Free limits, offered plans, product IDs and prices | Actual user decision; no invented trials/watermarks/credits |
| P6 | Trim boundary, crop/ratio and volume interactions | No advanced transforms/multi-track |

P0 source evidence remains in BASELINE/handoffs/P0. P1 schema-v1 JSON and actor repository are source facts, not runtime proof. Record date/PR, compatibility impact and unverified assumptions as choices resolve.

## P1 correctness follow-up — 2026-10-22

The user explicitly requested fixes for the autosave race and existing URL-download cap. Retained URL UI and hardened it; did not remove/add product features. Autosave consumes committed revisions while preserving the active draft. URL input uses ephemeral uncached streaming, the existing 16 GiB limit on headers/actual bytes, 64 KiB disk-write buffering and cancellation/temporary cleanup. No schema/layout/Mac/shared-package changes. Source inspection only; builds/tests/runtime validation remain unrun. PR #24 was later squash merged; that prior hold is historical.

## P2 source decisions — 2026-10-22, PR #25

- Reuse the already-pinned Whisper Small Multilingual asset and b5130 XCFramework wrapper. No asset or binary download was performed; iOS slices/linking remain unverified. Do not bundle Mac LLM or diarization models.
- File Models/whisper/ggml-small.bin (487,601,967 bytes) is copied as ggml-small.bin into the iOS app bundle. Runtime checks existing manifest size/SHA before native load. No in-app downloader/cloud fallback.
- Conservative iOS CPU configuration, no GPU/flash attention, at most four threads. This is a bounded-ownership source choice, not a measured performance recommendation. Model memory/latency on supported phones, including SE2, remain unmeasured.
- One JobQueue-backed durable operation at a time. Decoder/core windows are <=28/24 seconds with two-second context. Token bytes opt-in preserves existing Mac call sites/default results.
- Genuine native token intervals produce approximate word unions; no forced alignment. Missing usable timing is an error, not synthesized uniform timing.
- Schema v2 optional recognition with v1 read compatibility. Strict revisions/idempotent job completion and immutable raw layer prevent replacing edited text. P3 owns correction/playback synchronization.
- PR #24 merged; #25 stays open for review. No builds/tests/CI/regeneration/models/device actions.

## P3 source decisions — 2026-10-22

- The user requested this phase after squash merging #25. One branch feat/ios-p3-caption-editor from develop 97d647e; review hold/no auto-merge.
- Correction is per timed unit: a field can contain a corrected phrase or be cleared; no fabricated new word timing. Explicit manual cue scaling/word timing is separate from native source anchors. Schema v3 prevents old clients silently ignoring these corrections; v1/v2 remain readable.
- One session replaces the old detail viewer's separate title writer, owns atomic caption history and feeds one repository save drain. History stays in memory (50 commands), edited content is durable. No history/version product added.
- One native composition/player remains stable across caption and panel edits; caption/list/timeline evaluation shares a pure project-time snapshot. P3 is plain-caption preview only; full styled preview/export parity belongs to P4/P5.
- No Mac/shared-package/project.yml/generated-project/CI changes needed. No builds/tests/model downloads/device evidence.
