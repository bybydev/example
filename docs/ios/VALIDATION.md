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

## P3 source review and pending user scenarios

Source inspection only: pure edit commands/full-document validation, native anchor preservation, optional manual source mapping, v1/v2/v3 guards, duplication, atomic save sequence/revision handling, in-flight newer edits/undo, explicit failure retry/discard, history coalescing/selection, half-open cue lookup and overlap tie-break, media-key caching, source/track offsets/orientation/gaps, late load/seek/item guards and observer teardown. No compiler/runtime/UI checks were run.

User scenarios: prepare/regenerate/build yourself; correct English/Vietnamese/CJK and emoji/combining text; replace all text in a field, preserve spaces, clear/restore, enter phrases; cue/word timing inside/outside clip and zero/reversed values; split/merge and undo/redo before/during/after saves; redo branching and 50-command history; rapid title/caption typing then Back/background/reopen; simulated stale revision, disk failure and explicit retry/discard; ensure no draft replacement or original/raw changes. Verify schema-v1/v2 opening, v3 edits and duplicates. Use rotated/VFR/offset audio/audio-only/multi-clip media, missing originals/relink and gaps; seek rapidly, scrub, pause/resume/end/replay, open/collapse panels and change selection without player reset/focus theft. Validate SE2 keyboard, Dynamic Type/VoiceOver/reduced motion and long caption lists. Source fixtures are illustrative, not executed; runtime/media/model bytes are not supplied.
