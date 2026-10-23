# Issue #36 — caption editor and incremental recovery handoff

Baseline: develop 525fae48857c58c9e787184c8bdf527537365f86 (#35 merged). [PR #37](https://github.com/hoangbkit/Inkribe/pull/37), `fix/ios-window-recovery` → `develop`, stays open without auto-merge. The user explicitly requested implementation of the visualized editor and rejected hiding accepted captions until every window resolves. **This contract supersedes the earlier complete-only policy.**

## Device report — no transcript after 1 of 4 windows (2026-10-23)

The user supplied IMG_0863.jpeg: a 74.8-second project, Small multilingual/English, empty caption lane, no generated transcript, and an incomplete 1-of-4 result. The screenshot does not include raw output or individual failure classifications, so it does not prove the exact native/decoder failure. It demonstrates that the previous source-only completion did not establish working transcription.

Source inspection found a concrete defect: WordMapper required a usable token timestamp for every lexical word before accepting any text in a window. Whisper's own segment text/time could be valid while one word's experimental token timestamp was absent or zero-duration. The pinned upstream [README](https://github.com/ggml-org/whisper.cpp/blob/927cfce34f31707e17f2bff35c349632fb9e2c3a/README.md#word-level-timestamp-experimental) and [implementation](https://github.com/ggml-org/whisper.cpp/blob/927cfce34f31707e17f2bff35c349632fb9e2c3a/src/whisper.cpp) identify token timing as experimental; strict word timing must not be a prerequisite for showing valid segment-timed captions.

Mapping 2 pairs segments and token slices only when exact UTF-8 byte boundaries match. Valid segments retain token-union word timing. If token mapping fails, or the streams cannot be paired safely, use the model's native segment text and bounded native segment interval as one phrase unit with whisper-segment provenance. Never distribute a phrase across fabricated word timestamps. Reject malformed segment intervals/replacement-character text when fallback is needed, and retain fatal handling of nonfinite raw output. Existing core-midpoint ownership and native/source/output maps still apply.

Missing mappingVersion means legacy mapping 1; its accepted IDs/text/anchors are reconstructed with the unchanged strict mapper. New accepted entries record mapping 2 in both sidecar and canonical coverage. Mixed old/new entries resume, reset/reconstruct and duplicate without remapping old edits. Schema v7 protects these new mapping fields from older writers. Retry reruns previously failed cores because their rejected native output was not saved by the earlier build; no project/progress discard is required.

The editor identifies phrase timing and explains why per-word split/alignment is unavailable inside that unit. Incomplete errors now report failure classes/counts and explicitly say when zero captions were created; resolved silence/empty windows are not claimed as saved speech. Numeric mapping diagnostics include segment-timed-unit counts, without logging recognized text.

Source/diff/whitespace review only. No build/typecheck/test/fixtures/inference/device replay was run. The exact screenshot failure and this video's successful output remain unverified. User validation must cover valid segment text with missing/zero-duration word timing, mixed precise/phrase segments, multibyte UTF-8 boundaries/mismatches, invalid segment timing, old mapping-1 partials plus new mapping-2 retries, reconstruction/duplicate, native phrase editing/preview/MP4/SRT and allowance idempotency.

## Editor

Compact footage remains above transport, clocks, undo and the slim caption/gap overview. A caption selected from the transcript seeks slightly inside its real interval, so fade-in boundaries do not produce an apparently empty paused preview. First available captions are revealed on paused footage when the current playhead has no caption. The shared StyledCaptionOverlay/CaptionRenderer remains responsible for actual preview text.

The readable transcript is the main editor surface. Selecting a row exposes a multiline whole-caption field and timestamp, Timing and Split/Words. Advanced native-word correction, split/merge and timing remain in the Words & timing sheet. Captions/Style/Timing controls replace the old panel picker; Style retains existing controls/templates/Pro gates. Media tools and project details/relink remain in actions. A smaller footage strip keeps context while typing or in short workspaces. Native theme, Dynamic Type and accessibility semantics are retained; actual device fit is unverified.

Missing cores appear inline as orange ranges with Retry and as dashed orange overview bars. Partial status is compact and does not replace the transcript. Retry missing ranges handles all gaps; per-range retry restricts inference to that core. Available captions remain editable and exportable. Export presents a gap notice without a completion gate. No demo footage, captions or synthetic speech output are inserted.

Whole-caption edits keep changed characters on existing timed units. Unchanged character ownership and native separators remain; a replacement phrase can occupy one existing unit, with cleared units hidden. No word IDs/timestamps are fabricated. This preserves native anchors, but replacing a whole phrase does not create newly aligned karaoke words.

## Inference and publication

- Primary ownership cores remain 24 seconds with up to two seconds context. Explicit timing/text/decode/native-transcription failures get one recovery using two half cores, context min(two seconds, one quarter of each half). No recursive retry.
- Exhausted recoverable cores are recorded; later cores continue. Fatal model/source/storage/unclassified errors and cancellation stop execution. Successful prior publications remain usable.
- Opening the editor also publishes valid compatible accepted words retained only in an earlier complete-only checkpoint, without model loading or repeated inference. Checkpoint errors stay visible while the project remains open.
- Each accepted window is saved to the atomic sidecar, then merged into canonical Recognition immediately when at least one native word exists. Each publication atomically includes coverage/raw output/words/cues; a job is still explicitly incomplete while gaps remain.
- Existing raw windows, edited words and cues retain IDs and values. New units are deduplicated against native versions of existing units, so correcting/hiding/retiming text does not reintroduce overlap duplicates. New cues are inserted while preserving existing cue order.
- Repository serialization merges new inference into the current saved edits. Editor writes may narrowly rebase across append-only speech publication. Concurrent unrelated user edits still conflict. Returned saves merge new units into the latest in-memory draft, and caption undo patches preserve subsequently published cues.
- Model/language remain fixed for partial recognition even if the preference changes. Retry only missing cores; accepted digital silence stays resolved. All-empty nonzero model responses can run again, and no empty Recognition publishes.
- The main-actor controller increments resultGeneration after each publication, refreshing the editor independently of final JobQueue completion. JobQueue remains the scheduling/status owner; individual native progress callbacks retain inference scoping.

## Persistence and compatibility

Project schema v6 introduced optional RecognitionProgress (version/policy/runtime, total cores, accepted core indices, raw/native identities, attempts/recovery reason and decode metrics). Schema v7 additionally preserves each accepted core's mapping version. v1–v6 remain readable; absent coverage means a legacy complete result. New saves use v7 so older builds cannot silently erase the mapping version and later fail to reconstruct accepted captions. Native/manual source intervals and raw output remain canonical.

SpeechCheckpoint stays schema 1/policy 1, capped at 64 MiB and 20,000 cores. Owned-path/symlink checks, finite-time/core/source validation and raw-to-word rechecking before reuse remain. No PCM persists. The sidecar binds job/project/source graph/model/hash/runtime/language/policy. Before any canonical captions, exact revision still controls reuse; with partial captions, title/style/media/text changes can advance revisions without discarding accepted source inference. Immutable source graphs must match.

Canonical progress/raw output can rebuild accepted checkpoint entries after sidecar loss/reset or project duplication. Progress retains native IDs even for overlap-suppressed words; duplication remaps those IDs plus canonical/raw/clip identities. Sidecar attempts that ran ahead of publication are combined with canonical coverage on resume. Corrupt sidecars fail explicitly; Reset retry progress removes only that sidecar and reconstructs accepted work on the next retry. Runtime/model/policy incompatibility remains an explicit limitation: existing captions stay usable/exportable, but resuming requires the original compatible setup. Reset does not discard canonical captions to evade that requirement.

Sidecars follow Trash/restore, count toward project storage, survive derived-cache cleanup, and are removed with the project. Duplicate copies canonical partial captions/coverage rather than the sidecar. Complete publication ignores/removes leftover sidecars. A crash before queue acknowledgement recognizes the completed operation and reconciles allowance without inference or double charging.

Free reservations precede enqueue/retry. Incomplete/failed/cancelled terminal jobs release reservations through existing reconciliation; only complete nonempty recognition is charged. Explicit retry obtains current access/reservation. Legacy empty-result archive/refund remains separate. If a partial job's terminal record aged out, enqueue reuses its canonical operation ID. A retained record that JobQueue cannot retry still requires queue-level recovery; no canonical captions are cleared to bypass it.

## User validation still required

1. Build using the user-controlled flow. On a small iPhone, open a captioned project: footage shows actual text, transcript is immediately readable, selecting/editing a cue updates preview and export. Exercise keyboard, large text, VoiceOver, Style/Pro, Words/Timing, Media, project details and presentation/dismiss paths.
2. Fail a first/middle/last core with deterministic native fixtures: malformed UTF-8, missing/nonfinite timing, malformed overlap context or explicit decode/inference failure. Check bounded recovery, later-window continuation, immediately usable accepted captions and truthful gap status.
3. Edit/hide/retime/split/merge captions while later inference publishes. Save/undo/redo/relaunch must preserve edits and newly appended units. Retry one gap, then all gaps; old raw/word identities must remain and overlap duplicates must not return.
4. Check speech–silence–speech, all-empty output, fully silent audio, short/final cores, multiple clips, source offsets and trimmed ranges. Caption/gap display uses output time; numeric timing corrections use original project time.
5. Cancel/background/terminate during inference, sidecar writes, document publication, allowance settlement and queue acknowledgement. Reopen/retry without duplicate units, lost accepted work or double charges.
6. Corrupt/remove/reset sidecar; duplicate partial projects; Trash/restore; clear caches. Accepted canonical work must reconstruct, runtime/policy mismatches must remain explicit, unsafe paths must still reject. Exercise size limits.
7. Free/Pro/expiry/week reset/exhausted allowance, legacy empty recovery, complete recognition idempotency and frozen MP4/SRT exports. Partial export must be usable with an informational notice, and incomplete work must not charge.

## Evidence

Source/diff/whitespace review only. No builds, typechecks, tests, fixtures/inference, UI/device/accessibility validation, workflow dispatches, project generation, model downloads, benchmarks or deployment. No runtime-success claim: actual malformed-output recovery probability, latency and original-video diagnosis remain unverified. Mac/shared runtime/model assets/product IDs/project specs are unchanged.
