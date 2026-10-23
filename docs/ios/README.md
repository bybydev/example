# Inkribe iOS v1.0 — start here

## Current workspace repair — PR #35 (2026-10-23)

All four user-requested repair passes are source-implemented on `fix/ios-transcription-and-workspace` → develop in [PR #35](https://github.com/hoangbkit/Inkribe/pull/35), open with auto-merge disabled. Read [handoffs/TRANSCRIPTION_WORKSPACE.md](handoffs/TRANSCRIPTION_WORKSPACE.md) and [HANDOFF.md](HANDOFF.md) first for the current workflow, limitations and prioritized user checks. No builds/typechecks/tests, UI/device/native validation, CI, generation or downloads ran; the affected video's exact failure is unverified. No next phase or merge is authorized. Earlier Pro branch/review instructions below are historical.

Current compact scope: 29 V1 acceptance items; P0–P7 source work is squash merged through [#30](https://github.com/hoangbkit/Inkribe/pull/30), commit eb89f0f. The user subsequently authorized **Pro locking and AppFoundation themes**. The earlier P5 Pro deferral and PR #30 review hold are historical.

Read root AGENTS, PLAN, FEATURES, WORKFLOW, HANDOFF, ARCHITECTURE, DESIGN and [phases/PRO.md](phases/PRO.md). The Pro phase was merged as #31; its branch/review hold is historical. Current repair work is PR #35 above.

| Document | Role |
|---|---|
| [PLAN.md](PLAN.md), [FEATURES.md](FEATURES.md) | Current scope and 29 acceptance items |
| [PHASES.md](PHASES.md) | Delivery history and assessment |
| [phases/PRO.md](phases/PRO.md), [handoffs/PRO.md](handoffs/PRO.md) | Approved commercial policy, source integration, remaining user checks |
| [HANDOFF.md](HANDOFF.md), [handoffs/P7.md](handoffs/P7.md) | Live continuation and prior final audit |
| [ARCHITECTURE.md](ARCHITECTURE.md), [DESIGN.md](DESIGN.md) | Ownership and UI contracts |
| [MODELS.md](MODELS.md) | Optional development download/cache versus bundled-only production packaging |
| [WORKFLOW.md](WORKFLOW.md) | PR, scope and execution rules |
| [DECISIONS.md](DECISIONS.md), [RISKS.md](RISKS.md), [VALIDATION.md](VALIDATION.md) | Decisions, risks and user-run scenarios |
| [ISSUE_21.md](ISSUE_21.md), phases/P0–P7 and earlier handoffs | Historical source evidence; not authority to expand scope |

The Pro source now integrates all 29 V1 items. Compilation, native runtime, StoreKit, rendering, accessibility and device behavior remain unverified. No builds/typechecks/tests, CI, generation, weights, deployment or device validation were run. User tests afterward. Preserve Mac.
