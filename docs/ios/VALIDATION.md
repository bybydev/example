# V1 review and user testing

Agent work is source/document review only. No builds/tests, CI, Xcode generation, model downloads or device checks. Do not execute fixtures or call source inspection a test pass. User tests afterward.

Review identities, ownership, persistence, cancellation, stale-result guards, genuine time/Unicode, preview/export parity and Mac preservation. Record actual findings and incomplete V1 items separately from unrun checks.

User acceptance scenarios: P1 Photos/Files/offline reopen/rapid rename/duplicate/delete/cleanup/recovery; P2 local languages/word timing/chunk boundaries/long clips/cancel/errors; P3 correction/timing/split/merge/undo/keyboard/reopen; P4 real-footage styles/animations/Unicode; P5 MP4/audio/SRT/Save/Share/cancel/approved Pro/restore; P6 trim/caption boundaries/crop/volume parity; P7 complete import-to-export and interrupted/low-storage recovery.

Compilation, media compatibility, runtime fidelity, purchase behavior and device performance remain unverified until user results. Missing required functionality stays incomplete. Do not build testing/deployment infrastructure to satisfy this document.

## P1 follow-up user scenarios

Rapidly change a name during an in-flight save, submit/dismiss during debounce/write, relink while typing, and reopen the final draft. For the existing extra URL path, cover oversized declared length, absent/misreported length, exact-limit EOF and one byte over, cancellation, disk/network errors and temporary cleanup. These are pending user checks; no scenario was executed by the agent.

## P2 source review and pending user scenarios

Review only: native opt-in preserves Mac defaults; <=28-second source windows, sample-PTS placement, Unicode BPE reconstruction/real intervals, core ownership/deduplication; JobQueue one-worker/cancel/retry/startup/storage failures; atomic result-before-success/idempotency; v1/v2/future-schema/duplicate mappings and immutable raw guard. These are source conclusions, not executed tests.

User checks: stage the exact model then regenerate/build separately; test English/Vietnamese/CJK, speech across 24-second seams, repeated words, silent/no-audio/offset audio, rotated/VFR and long clips. Cancel during decode/inference/load; retry with chosen language; terminate before/after result publication; rapid double tap; rename during recognition; missing/corrupt model; corrupt job storage; disk failures; reopen/duplicate/delete recognized v2 and old v1 projects. Confirm originals/manual edits survive. Measure device memory/latency yourself; no results claimed.

fixtures/p2/schema-v2-recognized.json and schema-v2-empty.json are illustrative review data, not model output and not executed fixtures. P1 schema-v1 fixture is retained unchanged. Their referenced illustrative source bytes are absent.
