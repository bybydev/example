# Inkribe iOS — current plan

2026-10-24. Expanded Pass 1 of #40 is tracked by #41. The user authorized all source
implementation in one new PR from develop 4a9780f, left open targeting develop.

| Work | Source status |
|---|---|
| One-project creation | Photos/Files/direct URL; review/remove/order; failed-item handling; atomic single project |
| Project details/editor | Shared session; combined preview; clip strip/transcript groups; explicit entry points |
| Defaults/overrides | Sparse caption/framing/audio patches; section/all inheritance reset; bounded undo; preview/export wiring |
| Project exports | Existing durable inventory; in-place/queued generation; real-file preview and native delivery |
| Saving/consolidation | Existing atomic writer/error retention across routes; docs and eight unrun regression specifications |

All rows are source-integrated, **not compiled or accepted on device**. Exact files,
limits and pending user scenarios are in [the marked handoff](handoffs/PROJECT_EXPERIENCE.md).

## Product contracts

New Project always creates one project with one/multiple ordered files. No separate
projects option. Project defaults update inheriting fields; explicit clip overrides
remain. Reset removes overrides without touching text, timing, original media or trim.
Output aspect, resolution and existing 30fps stay project/output-wide.

Both export entry points capture the saved document and use the same durable queue,
worker and resource gate. Export now follows progress in-place; it does not bypass
accepted work, user pause or foreground requirements. Completed files share one
project export collection and remain immutable after later edits.

Keep the approved Free/Pro rules and pricing. Existing saved premium work survives
expiry; no new watermark, trial, backend quota or product is introduced. Canonical
schema 9 reads 1–8; no migration job or editor-sidecar workflow is added.

## Remaining parent passes

#40 Pass 2: deeper transcription/queue reliability. Pass 3: manual missing captions
and correction/style quality. Pass 4: output/audio/timing parity and delivery acceptance.
Pass 5: first-use, accessibility, commerce and supported-iPhone performance acceptance.
Do not automatically start another pass. Metadata remains excluded.

No post-creation sequencing, new per-clip trim, transitions, multitrack, accounts,
cloud inference/sync, dubbing/translation, share extension, iPad or Mac expansion.
Existing model packaging policy remains unchanged. See [readiness](PRODUCTION_READINESS.md).
