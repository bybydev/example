# V1 decisions

## Settled, 2026-10-22

- Compact v1 list replaces the exhaustive catalog. Current V1 IDs and P0–P7 briefs are authoritative; old Fxx totals are superseded.
- Local native caption workflow, AppFoundation and useful existing portable packages. Preserve Mac.
- Stable identities/revisions, safe originals, atomic project persistence, honest raw/edited timing and deterministic preview/export.
- P7 now means hardening. P8–P13 retired. Incoming share extension removed.
- Existing P1 extras are recorded source, not requirements. This update removes no app/UI code.
- PR #24 stays open. No builds/tests/CI/project generation/model downloads/device checks.

## Necessary owning-phase choices

| Phase | Choice | Boundary |
|---|---|---|
| P2 | Compatible local model, packaging and word-timing method | No automatic Mac Qwen/diarization or downloads |
| P3 | Preview/list/simple-timeline and keyboard layout | Short UI plan/approval |
| P4 | Curated fonts/templates and four effect defaults | No marketplace/custom font/brand system |
| P5 | Free limits, offered plans, product IDs and prices | Actual user decision; no invented trials/watermarks/credits |
| P6 | Trim boundary, crop/ratio and volume interactions | No advanced transforms/multi-track |

P0 source evidence remains in BASELINE/handoffs/P0. P1 schema-v1 JSON and actor repository are source facts, not runtime proof. Record date/PR, compatibility impact and unverified assumptions as choices resolve.

## P1 correctness follow-up — 2026-10-22

The user explicitly requested fixes for the autosave race and existing URL-download cap. Retained URL UI and hardened it; did not remove/add product features. Autosave consumes committed revisions while preserving the active draft. URL input uses ephemeral uncached streaming, the existing 16 GiB limit on headers/actual bytes, 64 KiB disk-write buffering and cancellation/temporary cleanup. No schema/layout/Mac/shared-package changes. Source inspection only; builds/tests/runtime validation remain unrun. PR #24 stays open.
