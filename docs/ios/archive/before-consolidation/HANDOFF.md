> Historical snapshot before the 2026-10-24 consolidation. Current contracts are in [README](../../README.md); instructions and status here are superseded.

# Live Inkribe iOS v1 handoff — 2026-10-22

## Current work — issue #38 production passes 1–5 (2026-10-24)

The user authorized pass 5 in existing [PR #39](https://github.com/hoangbkit/Inkribe/pull/39)
(`feat/ios-project-packages` → develop), retaining passes 1–4. All five source passes
are integrated: packages, processing, home/native flow, scrolling editor and now
versioned caption values/catalog, ten curated looks, renderer/layout/motion extensions,
independent resets, compatibility/access and production metadata source review.
Read [phase](../../phases/CAPTION_PRODUCTION.md), [handoff](../../handoffs/CAPTION_PRODUCTION.md)
and [readiness record](../../PRODUCTION_READINESS.md). Canonical schema 8 reads 1–7;
existing queue/checkpoint/request wrappers and working transcription are retained.
Shared style/catalog/motion values are consumed by iOS without changing Mac APIs.

Source/call-site/diff/whitespace and publication review only. Shared regression
specifications are authored, unexecuted. No builds/typechecks/tests/fixtures, CI,
generation, model downloads, native inference/exports, UI/device/accessibility or
deployment. Production verification and owner inputs remain pending, including the
placeholder privacy URL, live commerce, licensed footage/device/preview-export
acceptance and archive privacy report. Leave PR open without auto-merge. Earlier
pass-specific holds below are historical; source integration is not release readiness.

## Device-report follow-up — transcription still empty (2026-10-23)

Native segment text/timing must remain usable when a word timestamp is unavailable. Mapping 2 uses exact segment/token byte associations, retains usable word unions, and falls back to one phrase at the model's actual segment interval. Mapping 1 remains reproducible for existing accepted IDs; schema v7 protects new mapping metadata. Failed-range errors include reasons/counts and explicitly identify zero saved captions. The user's screenshot confirms an empty transcript after 1 of 4 windows, but does not identify those failures or prove this source fix works on that video. See [the recovery handoff](../../handoffs/TRANSCRIPTION_RECOVERY.md). Source review only; device replay remains unrun.

## Current work — caption editor and usable partial captions (2026-10-23)

The user explicitly requested implementation of the visualized editor in PR #37 (fix/ios-window-recovery → develop), based on 525fae4. Accepted windows now publish usable captions incrementally; the visible transcript edits whole captions, footage previews real text, and inline gaps retry without replacing edits. Partial MP4/SRT export is allowed with a notice; only complete nonempty recognition charges. Schema v7 reads v1–v6 and records coverage/mapping versions; the version-1 sidecar remains for inference recovery. This supersedes the earlier complete-only policy and panel hierarchy. PR stays open without auto-merge. Source/diff/whitespace review only: no builds/typechecks/tests, CI/workflow triggers, generation, weights, inference or UI/device validation. See [phase](../../phases/TRANSCRIPTION_RECOVERY.md) and [handoff](../../handoffs/TRANSCRIPTION_RECOVERY.md).

## CI follow-up — home type-check timeout and decoder label (2026-10-23)

User-run [Build Release 39899733122](https://github.com/bybydev/example/actions/runs/39899733122) built head `7e074ca` and reported two iOS archive errors: a type-check timeout at `ProjectsView.swift:26:25` and a missing `otherRange:` label in `SpeechDecoder.swift:30`. The previous editor-body timeout is not reported in this run; the archive still failed with exit 65.

The same PR now splits home layout, navigation, dialogs, lifecycle, toolbar, header, grid/cards, empty states and issues into separate opaque expressions while retaining the parent state, bindings, modifier order, cached query behavior and callbacks. The decoder uses `CMTimeRangeGetIntersection(trackRange, otherRange: range)`, matching the existing composition call. Source/diff/whitespace reviewed only; no agent build/typecheck/test or CI run. User rebuild confirmation remains pending; keep PR #35 open targeting develop with auto-merge disabled.

## CI follow-up — editor type-check timeout (2026-10-23)

The user asked to inspect failed [bybydev/example Build Release run 39896890203](https://github.com/bybydev/example/actions/runs/39896890203), building PR #35 head `0e30f68`. Dependency resolution/resource preparation completed, but the iOS archive failed with exit 65: `ProjectDetailView.swift:36:25`, compiler unable to type-check the body expression in reasonable time. This is observed user-run build failure, not runtime evidence.

The same PR now splits the editor into opaque layout/navigation/dialog/presentation expressions plus a separate ToolbarContent builder and actions-menu expression. State/session ownership, modifier order and actions remain in the parent view. Source/diff/whitespace inspection only; no agent build/typecheck/test or CI rerun. A new user build is still required to confirm the compiler fix and reveal any subsequent diagnostics. PR #35 stays open targeting develop with auto-merge disabled.

## Final integration review — pass 4 in PR #35 (2026-10-23)

The user requested the next pass in the same PR, authorizing pass 4. All four repair passes are source-implemented on `fix/ios-transcription-and-workspace` → develop. Keep [PR #35](https://github.com/hoangbkit/Inkribe/pull/35) open with auto-merge disabled; no next phase/merge is authorized. Historical earlier pass holds below are superseded by this request.

Pass 4 fixes recognition/playback audio policy parity: the shared preview/MP4 graph includes every source audio track in separate lanes with retained source offsets; volume changes update every included lane. Editor/transcription operation errors now have an editor presenter while the hidden home view yields; Back's save drain blocks new editor actions. Source review also covered import/cache/revision ordering, caption/trim/export boundaries and legacy-empty recovery/allowance. Mac, schema, originals, native word anchors, Pro policy, model assets and shared runtime are unchanged.

Read [handoffs/TRANSCRIPTION_WORKSPACE.md](../../handoffs/TRANSCRIPTION_WORKSPACE.md) for the integration table and prioritized user validation. No builds/typechecks/tests, UI/device validation, native inference/exports, CI runs, generation or downloads ran. The affected video's exact no-words cause is still unverified; all-track mixing can mix alternate-language tracks. Start user validation with that file, the SE2 layout/keyboard workflow and later-track speech at mute/intermediate/full volume in preview/MP4.

## Home and import redesign — pass 3 in PR #35 (2026-10-23)

The user requested the next pass in the same PR. Pass 3 is source-implemented: summary-cache search/filter/sort with no per-keystroke disk/storage refresh, bounded card image loading, live transcription/saved/empty/missing states, revision-aware card rename/duplicate/Trash actions, accessible filters/grid, explicit project/settings routes and post-dismissal import navigation. A successful single project opens directly; a batch returns to a recent unfiltered grid. Partial failures keep error/retry controls and existing input identities; background thumbnails/storage do not delay success navigation.

Read [handoffs/TRANSCRIPTION_WORKSPACE.md](../../handoffs/TRANSCRIPTION_WORKSPACE.md). No builds/typechecks/tests, UI/device validation, CI, generation or downloads ran. Pass 4 remains pending. Keep PR #35 targeting develop open with auto-merge disabled. Historical pass-1/pass-2 scope holds below are superseded for pass 3 by this request; they do not authorize pass 4.

## Editor redesign — pass 2 in PR #35 (2026-10-23)

The user requested the next pass in the same PR. Pass 2 is source-implemented on `fix/ios-transcription-and-workspace`: canvas/viewport-based preview sizing and in-editor expansion, one transport area, compact keyboard thumbnail, inline selected-caption correction using word chips/one field, timing/split/merge retention, accessible panel picker, and a dedicated project-details/relink sheet. Undo/redo and normal save status move into the actions menu; error recovery stays visible. Canonical caption ordering preserves Merge next semantics. Existing session/player, commands, persistence, timing/rendering and pass 1 recovery remain.

Read [handoffs/TRANSCRIPTION_WORKSPACE.md](../../handoffs/TRANSCRIPTION_WORKSPACE.md) for source behavior and pending user checks. No builds/typechecks/tests, UI/device validation, CI, generation or downloads ran. Passes 3 and 4 remain pending; keep PR #35 targeting develop open with auto-merge disabled.

## Transcription and workspace repair — pass 1 (2026-10-23)

At that point the user approved pass 1 of the four-pass review plan in one new PR from develop `565efe0`, branch `fix/ios-transcription-and-workspace`, targeting develop. Leave open without auto-merge. Continue future passes in this PR only when requested. IDs: V1.LOCAL_STT/JOB/RECOVERY/PRO; minimal retry/status UI belongs to this pass. That pass-1-only hold is superseded for pass 2 by the subsequent request above. Home/import redesign (pass 3) and final cross-surface review (pass 4) remain pending.

See [handoffs/TRANSCRIPTION_WORKSPACE.md](../../handoffs/TRANSCRIPTION_WORKSPACE.md) for exact source changes, failure/recovery semantics, limitations and user validation. Empty output can no longer be published or charged. Existing zero-word/zero-cue results have an explicit archived/refunded retry path; nonempty recognition/manual edits remain immutable. PCM is mixed from source audio tracks, checked for actual Float32 mono 16 kHz output and placed by source PTS. Decode counts/levels and model/mapped counts go to local numeric-only diagnostics.

No builds/typechecks/tests, UI/device validation, CI runs, project generation or model downloads were performed. This repairs confirmed source defects; it does not establish which native failure produced the user's particular empty transcript. Reproduce with the affected video and inspect the new failure classification/diagnostics. Mac/shared runtime and project schema remain unchanged.

## Settings and AppFoundation follow-up — PR #34

Crown flow follow-up: the Projects crown uses Spokio's single Pro-sheet route. Free users see AF ProPaywallView; active Pro users see AF ProCelebrationView. A successful purchase or restore that grants Pro presents celebration after the paywall finishes dismissing; cancelling while still Free does not celebrate. The crown switches between outline/filled according to access. Settings' plan action uses the same root route, and Debug Developer Tools can replay both real screens. Source review only; purchase/restore/dismissal/device checks remain unrun.

The user requested iOS Settings matching Spokio, with AppFoundation paywall, simulated purchases and Developer Tools. The gear now pushes a native Settings list with AF's Pro plan/restore/subscription actions, weekly caption usage, inline theme picker, speech-model and storage sheets, support/legal links, version and a Debug Developer Tools destination. Appearance previews remain disabled and locked themes still show the contextual upsell.

AppFoundation is pinned to 1.6.4, matching Spokio iOS. The real paywall uses AF ProPaywallView and the same shared PurchaseManager used by gates, settings, theme access and AF FoundationDeveloperView. Four PurchaseFeature definitions feed paywall, plan comparison and upsells. Existing monthly/lifetime IDs, local prices, persistence keys and live expiry rules are retained. Debug simulation uses AF's effective entitlement because its simulated monthly records have no real subscription expiry; Release still uses live StoreKit and contains no Developer Tools/simulation controls.

Settings → Developer Tools provides AF's purchase mode toggle, simulated entitlement/catalog/price editing, pending/cancel/failure/restore controls, diagnostics and a replay of the real paywall. It starts in live mode unless the existing launch environment explicitly opts into simulation. The user explicitly requested a dummy privacy URL: https://example.com/inkribe/privacy is centralized in Commerce for Settings and paywall. Apple's standard EULA remains the terms destination. Replace the dummy before public release.

Source/API review only. No agent builds/typechecks/tests, UI/device validation, workflow runs, project generation or downloads. User validation remains: compact iPhone Settings/navigation and sheet dismissal, Debug simulated Free/monthly/lifetime/reset and failure flows, shared gate/theme updates, and live StoreKit purchase/restore.

P0–P7 and optional models are squash merged through PR #30, develop eb89f0fb3cd0f67054e6d29de2375342718c1651. The user's current request authorizes the previously deferred **V1.PRO** and AppFoundation premium themes. Work lives on feat/ios-pro-access-themes → develop; keep its PR open, no auto-merge.

**All 29 V1 acceptance items have source integration. None are claimed compilation/runtime/device verified.** See [phases/PRO.md](../../phases/PRO.md) for the exact approved offer and [handoffs/PRO.md](../../handoffs/PRO.md) for implementation, recovery behavior and pending user validation.

Free: 5 captioning minutes/week, basic caption look, 720p video, AF default theme. Pro: unlimited captioning, all existing caption fonts/templates/animations, 1080p and premium AF themes. Monthly $6.99; lifetime $24.99. Existing documents/styles/captions/export files and free editing/media/SRT remain available after expiry.

Current source uses pinned AppFoundation 1.6.4 for purchase lifecycle, live verified entitlements, contextual upsell/paywall/restore and theme picker/state. iOS has its own local StoreKit configuration and Debug simulator persistence. Mac is unchanged even though the approved monthly/lifetime product strings also exist in Mac's catalog. Live product configuration/prices and an actual Inkribe privacy destination remain release inputs; no store or website changes were made.

The repository owns a separate atomic weekly usage ledger and durable job reservations. Failed/cancelled work is released after terminal status; publication is charged exactly once with recognition-ID reconciliation. Accepted jobs survive expiry/reset, and pre-policy payloads remain readable. Default new export is 720p; access is checked before replacing the retained artifact. Theme changes affect app chrome, never footage or caption artwork.

Schema remains v5, reading v1–v4. Canonical timing, raw recognition and originals remain unchanged; retained-range preview/export mapping, bounded undo, serialized latest-draft saves, model selection/download/cache and export pins/delivery leases are retained. [MODELS.md](../../MODELS.md) and earlier handoffs retain these contracts. [handoffs/P7.md](../../handoffs/P7.md) records the previous source audit; its 28/29 accounting and Pro deferral are historical.

No builds/typechecks/tests, CI setup/triggers, generation, model downloads, inference, media exports, deployment or native/device/UI validation were performed. User runs [Pro scenarios](../../handoffs/PRO.md) and existing VALIDATION/P7 scenarios before release.

## Current naming and bundle correction — PR #33

The iOS source root is now Inkribe/ and the entry point is InkribeApp. Redundant IOS type/file prefixes are removed (the domain canvas is ProjectCanvas). Project specs, resource/StoreKit paths and source references follow the move. Both iOS configurations use com.hoangbkit.inkribe. Two legacy JobQueue adapters retain IOSSpeechJob/IOSExportJob as persisted type names; new work uses SpeechJob/ExportJob. No storage/default keys, encoded document/queue payload fields, model IDs, product IDs or Mac files change. Source review only; no builds/tests/generation/workflow/device actions. Keep #33 open.
