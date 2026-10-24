> Historical snapshot before the 2026-10-24 consolidation. Current contracts are in [README](../../README.md); instructions and status here are superseded.

# Inkribe iOS v1.0 — start here

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

The user explicitly requested implementation of the visualized editor in PR #37 (fix/ios-window-recovery → develop), based on 525fae4. Accepted windows now publish usable captions incrementally; the visible transcript edits whole captions, footage previews real text, and inline gaps retry without replacing edits. Partial MP4/SRT export is allowed with a notice; only complete nonempty recognition charges. Schema v7 reads v1–v6 and records coverage/mapping versions; the version-1 sidecar remains for inference recovery. This supersedes the earlier complete-only policy and panel hierarchy. PR stays open without auto-merge. Source/diff/whitespace review only: no builds/typechecks/tests, CI/workflow triggers, generation, weights, inference or UI/device validation. See [phase](../../phases/TRANSCRIPTION_RECOVERY.md) and [handoff](../../handoffs/TRANSCRIPTION_RECOVERY.md).

The earlier status paragraphs below are historical and superseded by this request.

## Current transcription recovery — issue #36 (2026-10-23)

PR #35 was squash merged into develop as 525fae4. The user requested issue #36 recovery/checkpoints in one new fix/ios-window-recovery PR targeting develop, left open without auto-merge. Read [phases/TRANSCRIPTION_RECOVERY.md](../../phases/TRANSCRIPTION_RECOVERY.md), [handoffs/TRANSCRIPTION_RECOVERY.md](../../handoffs/TRANSCRIPTION_RECOVERY.md) and HANDOFF first. Source integration only; no builds/typechecks/tests, CI, generation, weights or device/UI validation. Earlier #35 open/continuation holds below are historical.

## Current workspace repair — PR #35 (2026-10-23)

All four user-requested repair passes are source-implemented on `fix/ios-transcription-and-workspace` → develop in [PR #35](https://github.com/hoangbkit/Inkribe/pull/35), open with auto-merge disabled. Read [handoffs/TRANSCRIPTION_WORKSPACE.md](../../handoffs/TRANSCRIPTION_WORKSPACE.md) and [HANDOFF.md](../../HANDOFF.md) first for the current workflow, limitations and prioritized user checks. No builds/typechecks/tests, UI/device/native validation, CI, generation or downloads ran; the affected video's exact failure is unverified. No next phase or merge is authorized. Earlier Pro branch/review instructions below are historical.

Current compact scope: 29 V1 acceptance items; P0–P7 source work is squash merged through [#30](https://github.com/hoangbkit/Inkribe/pull/30), commit eb89f0f. The user subsequently authorized **Pro locking and AppFoundation themes**. The earlier P5 Pro deferral and PR #30 review hold are historical.

Read root AGENTS, PLAN, FEATURES, WORKFLOW, HANDOFF, ARCHITECTURE, DESIGN and [phases/PRO.md](../../phases/PRO.md). The Pro phase was merged as #31; its branch/review hold is historical. Current repair work is PR #35 above.

| Document | Role |
|---|---|
| [PLAN.md](../../PLAN.md), [FEATURES.md](../../FEATURES.md) | Current scope and 29 acceptance items |
| [PHASES.md](../../PHASES.md) | Delivery history and assessment |
| [phases/PRO.md](../../phases/PRO.md), [handoffs/PRO.md](../../handoffs/PRO.md) | Approved commercial policy, source integration, remaining user checks |
| [HANDOFF.md](../../HANDOFF.md), [handoffs/P7.md](../../handoffs/P7.md) | Live continuation and prior final audit |
| [ARCHITECTURE.md](../../ARCHITECTURE.md), [DESIGN.md](../../DESIGN.md) | Ownership and UI contracts |
| [MODELS.md](../../MODELS.md) | Optional development download/cache versus bundled-only production packaging |
| [WORKFLOW.md](../../WORKFLOW.md) | PR, scope and execution rules |
| [DECISIONS.md](../../DECISIONS.md), [RISKS.md](../../RISKS.md), [VALIDATION.md](../../VALIDATION.md) | Decisions, risks and user-run scenarios |
| [ISSUE_21.md](../../ISSUE_21.md), phases/P0–P7 and earlier handoffs | Historical source evidence; not authority to expand scope |

The Pro source now integrates all 29 V1 items. Compilation, native runtime, StoreKit, rendering, accessibility and device behavior remain unverified. No builds/typechecks/tests, CI, generation, weights, deployment or device validation were run. User tests afterward. Preserve Mac.
