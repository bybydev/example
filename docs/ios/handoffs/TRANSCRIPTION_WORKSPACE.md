# Transcription and workspace repair

## Scope and state

Base: develop `565efe0719e53645d829856c029da2f8c15d4024`. Branch: `fix/ios-transcription-and-workspace`, [PR #35](https://github.com/hoangbkit/Inkribe/pull/35) targeting develop, open with auto-merge disabled. The user authorized pass 4 with the next-pass request. All four passes are source-implemented; no next phase or merge is authorized. Preserve Mac and all existing user data. No builds/typechecks/tests, CI runs, project generation, weights, deployment or UI/device validation.

| Pass | Scope | State |
|---|---|---|
| 1 | Empty transcription diagnosis, decoding, retry/recovery, allowance | Source implemented; native/user validation unrun |
| 2 | Preview/layout/caption correction/keyboard redesign | Source implemented; layout/device validation unrun |
| 3 | Home cards/status/actions, import navigation, search efficiency | Source implemented; native/user validation unrun |
| 4 | Cross-surface correctness and final handoff | Source review/fixes complete; native/user validation unrun |

## User CI follow-up — 2026-10-23

[Build Release run 39896890203](https://github.com/bybydev/example/actions/runs/39896890203) on bybydev/example built PR head `0e30f682db9125791f24b85e575a78eed133e91a`. It passed package/resource setup, then failed compiling the iOS archive: `ProjectDetailView.swift:36:25`, compiler unable to type-check the body expression in reasonable time (exit 65). No runtime/UI acceptance can be inferred.

The source follow-up in the same PR extracts separate opaque workspace/navigation/dialog/presentation properties, a ToolbarContent builder and an actions-menu property. It retains the same parent-owned State/FocusState/EditorSession, modifier order, view content and callbacks. Source/diff/whitespace reviewed; no agent builds/typechecks/tests, CI dispatch/rerun or device checks. User rebuilding is pending; this is not a claimed passing compile.

## Second user CI follow-up — 2026-10-23

[Build Release 39899733122](https://github.com/bybydev/example/actions/runs/39899733122) built `7e074ca` and failed the iOS archive with two reported errors: `ProjectsView.swift:26:25` exceeded the type-check budget and `SpeechDecoder.swift:30` omitted the required `otherRange:` label. The editor-body timeout is not reported in this run. Source follow-up in the same PR splits the home into opaque layout/navigation/dialog/lifecycle/toolbar and content-section expressions, keeping parent-owned state/bindings/callbacks and modifier order. The decoder's intersection call now includes `otherRange:`, matching the shared composition API usage. No agent builds/typechecks/tests or CI reruns; user build confirmation remains pending.

## Pass 1 behavior

- SpeechDecoder uses AVAssetReaderAudioMixOutput across source audio tracks, including narration on later tracks. It requests Float32 mono 16 kHz, verifies the actual ASBD and frame/data lengths, and retains absolute source-PTS placement in one bounded buffer. An expected audio intersection with no copied frames fails as unreadable audio; intentional gaps stay padded. Pass 4 aligns preview/export with this all-source-audio-track policy. Recognition still uses the full original clip independently of output trim/volume; no track selector is added.
- Counts, source-window timing, peak/RMS, native segment/token counts and mapped-word counts use local OSLog categories SpeechDecoder/LocalTranscriber under com.hoangbkit.inkribe. No filenames, source paths, samples, transcript or token text is logged. Digital-zero windows are skipped; quiet nonzero audio is not discarded by a speech-energy threshold.
- Whole-project failure distinguishes no audio track, unreadable audio, digital silence, model returned no words, invalid text and unusable native timing. Never infer that audible speech was absent from an empty word array. Empty native/word output fails retryably before publication. WordMapper rejects nonempty text with no lexical tokens rather than silently returning an empty result.
- ProjectRepository independently refuses new zero-word results. Legacy empty results still decode normally, preserving schema v5/v1–v4 reads. Successful nonempty jobs retain the prior revision, raw provenance and job-ID publication/charge idempotency.
- Explicit Retry transcription on a legacy result requires zero words AND zero cues. The repository saves its raw Recognition to Projects/<project-id>/RecognitionRecovery/<recognition-id>.json, then refunds only its exact ID in the current ledger's charged set and removes any matching reservation. Old-week usage is not added to the new week; duplicated uncharged IDs cannot refund another project's usage. Refund occurs before clearing, so a crash can retry without losing refund evidence or refunding twice. All originals, title, trim/framing/volume and caption style remain intact. Ordinary commitEdit still cannot clear raw recognition or alter native word anchors.
- Recovery clears recognition through a private, narrowly guarded writer, increments the existing revision and retains the prior document backup. The controller refreshes the editor even if later quota/model/queue authorization fails. There is no automatic replacement of results containing any word, including manually hidden words.
- UI closes typing, pauses playback and drains the latest draft before starting a request. It blocks conflicting editor/toolbar actions until the external revision is reloaded. Model/language selection, real job progress/cancel/retry and contextual Pro upsells remain available. A failed request with no result remains retryable. Wordless legacy projects do not remain stuck behind a completed-result branch.
- Reconciliation and finishSpeechAllowance charge only published nonempty recognition. Failed/cancelled/unpublished reservations remain subject to the existing terminal reconciliation. Empty legacy results no longer get charged by publication reconciliation. An already charged legacy result is refunded when its user explicitly retries, not by an implicit library rewrite.

## Pass 2 behavior — editor redesign

Scope: V1.TEXT/TIMING/SPLIT_MERGE/UNDO/PREVIEW/ACCESS, retaining Style/Templates/Media access. This updates the earlier P3 layout contract without changing domain commands, timing, rendering, schema, export or purchase policy.

- The normal preview fits the canvas aspect into available width and a 46%-of-workspace height budget, capped at 360 pt. Accessibility text sizes use 30% to reserve control space. An expand action devotes the workspace to preview/playback; returning uses the same EditorSession/AVPlayer/item and keeps the playhead. This is an in-editor expansion, not a separate playback session or modal player.
- Play/pause, the cue overview, scrubber and clocks share one transport area. Keyboard focus uses a 64 pt thumbnail beside transport, hides the overview and panel picker, and leaves the remaining workspace scrollable. Workspaces shorter than 420 pt (including compact landscape) also use the thumbnail strip, retaining tool choice when not typing. Transport clocks fall back to stacked lines when they cannot fit side by side. Focus and keyboard-safe-area height changes target the actual word/timing/trim fields. Done ends typing and flushes through the existing save drain.
- Caption correction now expands inside the selected list row. Horizontal, bounded-width word chips select stable timed units; only the selected unit has an editable field. Hidden units remain selectable. Clearing text, corrected phrases, native separators and timing retain their existing command behavior. Cue ordering remains the session's canonical order so Merge next continues to match the next displayed row. There is no jump to a separate correction block above the list.
- Cue and selected-word timing disclosures, split, merge and session undo/redo are retained. Cue selection scrolls to that row; playback follows active captions only when not typing and never replaces editing selection. Large surrounding text uses a menu for panel choice rather than four compressed segments.
- The navigation bar keeps Back, Export and the actions menu. Undo/redo, save state and project details move into that menu; errors still have visible save/reload/dismiss actions and the menu icon signals errors. Error actions use horizontal/vertical fallback. Normal save state no longer consumes a permanent editor row.
- Project details opens a dedicated sheet for rename/original information/relink instead of sitting below every tool panel. It owns the file picker, error alert and discard/reload confirmation. Done waits for pending saves; unsaved drafts prevent interactive dismissal. Full presentation does not stop the parent session; leaving the editor still detaches playback and flushes normally.
- Pass 1 transcription/recovery entry points and protection during request preparation remain. Pure panel, focus and preview expansion do not call composition preparation or replace the player item.

Source and diff review only. No compilation, native UI inspection, screenshots, accessibility run, device validation, tests, CI, generation or model downloads. Actual fit, focus retention, player-layer reattachment and sheet presentation remain user-validation items, not measured claims.

## Pass 2 user validation still required

1. On iPhone SE and a larger iPhone, check portrait/landscape/square/audio-only projects in normal and expanded preview; expand/return while playing and scrubbing. Confirm the same playhead/audio/captions and no duplicate playback or item rebuild.
2. Select several caption rows, choose/clear/correct words and phrases, split/merge and undo/redo. Check hidden words, Unicode/separators, manual timing and trim-boundary units. Next displayed row must match Merge next.
3. Focus word, timing and trim fields with the keyboard shown/hidden/interactively dismissed. Verify the selected field and caret remain usable, the compact preview does not crowd it, and panel switching/Done preserve drafts.
4. Check large/accessibility text sizes, long labels/titles, VoiceOver, Reduce Motion and all Style/Templates/Media controls.
5. Rename and relink through project details, including missing media and picker cancellation/failure. Exercise save failure, retry/reload/discard, Done and interactive dismissal. Reopen the same project and verify saved edits.
6. Retry a legacy empty result through the pass 1 UI; check foreground/background, export, Pro sheet and details-sheet presentation do not strand the session or reset its media clock.

## Pass 3 behavior — home and import

Scope: V1.PROJECTS/RENAME/DUPLICATE_DELETE/IMPORT/BOUNDS/ACCESS. PR #35 stays open targeting develop; pass 4 review is recorded below. Existing models, recognition, export, Pro and Mac policy are unchanged.

- ProjectsModel retains an unfiltered summary snapshot. Search (trimmed title query), media/missing filters and selected sort project that snapshot in memory; no query/filter/sort observer starts a repository/storage scan. Sort ties use the project UUID for stable ordering. Snapshot refreshes keep their latest-generation guard; edits/imports/relinks/thumbnail publication/transcription completion/navigation/explicit refresh update the library. Storage accounting remains separate and still runs for its existing explicit events.
- ProjectSummary adds transient revision and caption-state fields; nothing new is persisted into document schema v5. Cards distinguish missing originals, queued/running/paused/cancelling transcription, cancelled/failed retry, empty legacy result, saved captions and no audio. Real finite progress is clamped for display. Saved captions are not mislabeled absent because an old job acknowledgement failed; saved/hidden/trimmed-out captions are not claimed ready for export.
- Cards use a bounded 4:3 image viewport, duration overlay, title/status/date and a visible actions menu plus context menu. Large text uses a wider one-column minimum. Thumbnail file reads use a separate actor and a 2 MiB byte bound, then decode once per mounted card URL/cache generation; body/status recomputation performs no image file read. Placeholders handle absent/invalid data. Duplicate in-flight thumbnail generation for the same project is suppressed. This is no measured scrolling/frame-rate claim.
- Card Rename submits the captured content revision and refreshes after conflict; it never opens a fresh document and blindly overwrites a newer title. Rename/duplicate require available originals; active transcription blocks rename/trash, and queue storage problems block trash. Per-project mutation guards prevent repeated operations, and busy cards cannot be opened midway through a mutation. Trash still uses confirmation and the existing recoverable repository operation.
- Readable horizontal filters replace compressed segments; empty search/filter results provide a clear reset. Global library issues appear outside a filtered view, with links for known projects. The current-export entry remains accessible in content. Explicit project/settings routes own navigation; root toolbar items are hidden on pushed screens so they do not crowd editor controls.
- A completion token carries committed import IDs only. All-success one-project imports dismiss the sheet and then push that project; batches dismiss to a recent-first unfiltered grid with a count notice. Route handoff occurs from sheet onDismiss, not during presentation. New import sessions clear old completion/message/selection. No route is reused on a later dismiss.
- Completion does not wait for thumbnail generation or storage accounting. Partial failures keep the sheet, selected input identities, error details and an explicit Open/View imported projects action, preserving the importer's idempotent retry behavior. Cancellation keeps already committed projects; a cancellation observed after commit/snapshot publication suppresses automatic navigation. Direct URL import remains under a disclosure with its existing permission/format/size policies. This is no new importer/backend/extension.

## Pass 3 user validation still required

1. On SE/larger iPhone and accessibility sizes, inspect one/two-column cards, long titles, filters, image crops, action targets and VoiceOver. Check missing/corrupt/cleared thumbnails and scrolling during live transcription; inspect actual frame rate separately.
2. Search/filter/sort while a library refresh/thumbnail/job completion is in flight. Verify current-query results, stable sort ties and latest published metadata. Confirm typing itself starts no disk/storage refresh, including after returning from an editor or Settings.
3. Rename/duplicate/trash from both menus; check stale-revision refusal, double taps, active jobs, unavailable originals, persistence errors and Trash restoration. Busy navigation must remain disabled until publication/refresh finishes.
4. Import one file, one combined project, multiple separate projects and a direct URL with filters/search already active. Check dismissal-before-push, exactly one navigation, recent grid/batch count and reopening after Done/interactive dismissal. Open Settings then return; only the intended toolbar should show.
5. Mix valid/invalid batch inputs, retry, cancel at different stages and close/reopen import. Committed files stay, completed input IDs are not duplicated on retry, failure details remain accessible and stale completion tokens never reopen an old project. Derived JPEG/storage failures must not turn a committed import into an import failure.
6. Exercise each card status including a legacy empty result, digital-silence failure, hidden/trimmed captions, resumed job and queue storage failure. Return from pass 2 editor, verify labels update, and confirm export/Pro/Settings remain reachable.

## Pass 4 behavior — integration review and final handoff

Scope: V1.PREVIEW/MP4/VOLUME/JOB/RECOVERY/BOUNDS/ACCESS/HANDOFF across the repaired workflow. The user requested this final pass in PR #35. Source review is complete; builds/runtime/device acceptance remain unrun.

- Corrected the audio policy mismatch introduced by reading every source track for speech: the shared preview/MP4 graph now inserts every source audio track into an independent composition lane, reusing lanes across sequential clips. Each intersection keeps the existing source offset and retained-range placement; unused lanes are removed. Both surfaces use one mix containing every populated lane. Volume-only edits replace gain parameters for all included track IDs without rebuilding the player. Single-track/no-audio/audio-only/intentional-gap behavior still follows the same graph and black-clock path. This is an all-track mix, not a track editor or alternate-language selector.
- Editor operation/transcription/cancel errors now have a presenter on the editor itself. The hidden home view presents shared model errors only while its grid is active with no root sheet; it cannot compete with import or editor/details alerts. Editor presentation yields to its details/export/Pro sheets. Closing an error-owning sheet leaves any unacknowledged shared error available to the next visible owner.
- During Back's save drain, editor fields, Export and the actions menu are disabled alongside Back, preventing a new editor action/sheet while the pending leave is deciding whether to dismiss. A failed save keeps the editor/draft and re-enables existing recovery controls.
- Reviewed import completion publication/dismissal ordering, partial-input identity, cached summary generations, revision-aware rename, active-job/trash guards, caption row/merge order, trim-derived preview/SRT/MP4 clocks, recognition publication/recovery/allowance ordering and source/runtime boundaries. Those inspections are source evidence, not executed race/audio/layout checks. No schema, native word anchors, original-media ownership, Pro policy, shared runtime, model assets or Mac code changed in pass 4.

| Flow | Source evidence | User check still required |
|---|---|---|
| Add → home/editor | Committed IDs published after summary refresh; route after sheet dismissal; partial errors retained | Single/batch/partial/cancel and exactly one route |
| Search → edit → return | Query/filter/sort only project summaries; actual changes refresh snapshots | Current results after edits/jobs/imports and in-flight refresh |
| Transcribe → retry | No new empty publication/charge; explicit legacy archive/refund; latest saved revision captured | Affected video, native timing, crash/relaunch and exact refund |
| Correct → trim → export | Canonical cue order, guarded merge, retained-range mapping, frozen export snapshot | Hidden/boundary words, manual timing, undo/save and output parity |
| Multi-track speech → playback/MP4 | Every source audio track now participates; each populated lane gets volume gain | Later-track narration, differing offsets/formats, trim, mute/reset/undo and AAC output |
| Failure → recovery | Visible owner for model errors; Back waits for save and blocks conflicting actions | Sheet/alert presentation and save-failure retention on device |

## Priority user validation after all four passes

1. First reuse the affected video on the actual phone: Auto and the explicit spoken language; verify real captions/timing or record the precise error and numeric SpeechDecoder/LocalTranscriber diagnostics. The original failure has not been reproduced by the agent.
2. On iPhone SE2 and a larger supported iPhone, run import → editor → transcribe → correct text/timing → style → trim/crop/volume → MP4/SRT → save/share → reopen. Check keyboard, compact/expanded preview, focus/scroll, large text and VoiceOver. No agent UI/device validation occurred.
3. Use a source with silence on track 1 and speech on track 2, then sources with offset/mixed-format tracks and clips with different track counts. Compare heard preview with MP4 at volume 1, 0 and an intermediate value, including undo/reset and trim into a gap. Recognition intentionally ignores output volume/trim. Multiple simultaneous/alternate-language tracks are mixed; track selection remains outside scope.
4. Retry legacy zero-word/zero-cue results, including exhausted allowance, relaunch and weekly reset; protect real/hidden/edited words and charge/refund only once. Force interruption and storage failures through the existing user scenarios below.
5. Trigger transcription/duplicate/trash/relink failures with home, import, editor and details visible in turn. Each error must appear on the visible owner. Back during an unsaved edit must wait; a save failure must retain the editor/draft and recovery actions.
6. Run the pass 2/3 scenarios above for import cancellation/partial retries, stale rename, saved statuses, current export, Settings/crown/Pro and returning from sheets. Builds/typechecks/tests and all native acceptance are for the user; no CI run was triggered.

## Evidence and limits

Source review and whitespace/diff inspection only. No compilation, test, model execution, audio extraction, pixel/UI inspection or device evidence. The existing auto-language runtime already sets detect_language=false with language="auto"; this pass does not claim to fix that setting. Model variants, binary pin, CPU policy, original media and native timing contracts are unchanged.

The specific reason the user's video returned no words is still not reproduced. These changes remove confirmed publication/retry/quota defects and fix first-track-only speech input; actual decode/inference behavior must be checked with the affected file. Mixing alternate language tracks can reduce recognition quality; there is no track selector in this pass. Pass 4 aligns preview/export to the all-track source-audio policy in source; decoded waveform, rendered pixels and exported-file parity are unverified. No fabricated words, timings, cloud fallback or success placeholders.

## User validation still required

1. Reuse the affected video with Auto and its explicit spoken language. Capture the exact failure and decoder/inference/mapping counts if empty output persists. Confirm audible speech produces real captions.
2. Check mono/stereo, 44.1/48 kHz, Photos/Files, narration on a second track, offset audio, genuine silence, track gaps and a >28-second recording. Confirm source/project word timing across window boundaries; no duplicate overlap or lost trailing speech.
3. Retry a legacy zero-word project at exhausted free allowance. Verify same-week usage is refunded exactly once, source/style/media settings remain, and successful new recognition charges once. Repeat after relaunch and a weekly reset; retry a duplicate and ensure it cannot refund the original.
4. Force decode/empty inference/timing failure, cancellation and background/relaunch: no empty committed recognition or consumed terminal reservation; model/language retry still works.
5. Exercise failed archive/document/ledger writes and queue persistence; verify no data is discarded and retry remains available. Check process death before/after refund, document reset, reservation, publication and queue acknowledgement.
6. Confirm nonempty, edited, hidden-word and trimmed-out captions cannot be reset through this recovery path. Pending title/media saves must complete before enqueue, and the reloaded revision must accept later edits without stale-save errors.
