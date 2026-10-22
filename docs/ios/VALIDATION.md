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

## P4 source review and pending user scenarios

Inspection only: optional-style/v1–v4/future-schema handling, color/size/position validation, duplicate preservation, interleaved text/style undo/redo, continuous-control grouping, in-flight newer style saves, unchanged player media keys, project-coordinate layout and effect boundary math, one-cue cache/fit-error bounds, Core Text UTF-16 spans/glyph direction, UIKit/bitmap coordinate adaptation and the shared CI overlay path.

User checks: regenerate/build separately; open v1/v2/v3 and nil-style v4, style/save/reopen/duplicate, reject malformed/future styles; change every font/color/opacity/outline/background/position control, all four templates and reset. Interleave timing/text/style/template commands with undo/redo and rapid saves, leave/background/error/retry/reload, confirm originals/raw/native anchors remain identical. Keep playback position and selection when switching tools or editing styles. Try SE2 keyboard, Dynamic Type/VoiceOver/Reduce Motion, no-speech and hidden words.

Use English/Vietnamese combining marks, CJK/Thai/Arabic/Hebrew mixed bidi, punctuation/ligatures/emoji/ZWJ, long unbroken text and wrapped words. Inspect active-word rectangles, RTL/multiline karaoke progression, pop headroom, fade endpoints, overlaps/gaps, pause/seek/replay and exact cue/word boundaries. Check extreme placements/size and clear split/reduce-size errors; no silent truncation. Compare captured preview and renderer bitmap output at matching project timestamps in portrait/square/landscape and 720p/1080p, including transparency and orientation/letterboxing. Measure real memory/latency yourself. No such checks, exported files, models or runtime media were produced here.

## P5 source review and pending user scenarios

Reviewed source paths only: canonical saved-document freeze and ISO-date precision; same-actor hard-link/copy pinning against Trash/deletion; versioned manifest/small durable payload; media graph reuse, actual track intersections/black gaps/orientation/project aspect; output-frame PTS and shared P4 overlay; H.264/AAC settings; bounded frame/audio references and pool backpressure; writer finalization/validation/atomic publication; partial cleanup/retry/idempotence; scene interruption/restart; one retained file and delivery tokens; add-only Photos description; SRT edited cue order/Unicode/rounding/hidden text. No scripts/fixtures/compilers/tests were executed to verify runtime behavior.

User checks: separately regenerate/build; export 720p and 1080p portrait/square/landscape/custom, small/rotated/mirrored/HDR/VFR video, audio-only/silent/multi-clip/gap/offset media, all four templates and multilingual/RTL/emoji captions. Compare preview and decoded output at matching project timestamps; inspect actual dimensions/codecs/duration, AV sync, original-audio offsets, AAC priming and black frames. Test sub-frame clips and first/last frames; hide all captions and overlong/nonfitting captions; edited SRT including overlaps, manual times, phrases, blank text, newlines and very short intervals. Originals/raw anchors must remain unchanged.

Cancel/retry during staging/render/finalization, pause/background/return and terminate before/after publication/queue acknowledgement. Retry must use the original frozen revision; later edits or source-project Trash/empty Trash must not affect pinned bytes. Test low space, missing/corrupt input/output/manifest/job file and storage retry without destructive reset. Check replacement/discard/orphan cleanup and one retained artifact. Use a project titled partial to check working/result filename separation. Complete delivery from Projects even after deleting the last source project.

Save MP4 to Photos with allow/deny and an existing authorization; verify SRT offers Files/share only. Save via local/iCloud/third-party Files providers, cancel pickers, share/cancel/fail activities, dismiss/reopen sheets and attempt concurrent replacement/discard while a delivery holds its file. Check SE2 layout, Dynamic Type/VoiceOver and main-thread responsiveness; measure memory/thermal/render time yourself. Pro/StoreKit tests are deferred with V1.PRO by user choice. No scenarios above have been run by the agent.
