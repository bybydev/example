# Inkribe iOS v1.0 — start here

**Scope reset, 2026-10-22:** focused native caption app, eight phases P0–P7 and 29 V1 acceptance items. Current PLAN/FEATURES replaces the exhaustive catalog. Do not implement archived features.

Read root AGENTS, WORKFLOW, HANDOFF, PLAN, FEATURES, ARCHITECTURE, DESIGN and the requested phase brief before work.

| Document | Role |
|---|---|
| [PLAN.md](PLAN.md) | Current inclusions/exclusions and dependencies |
| [FEATURES.md](FEATURES.md) | 29 current V1 acceptance items and honest source status |
| [PHASES.md](PHASES.md) | Eight-phase difficulty/value assessment |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Local ownership, storage, timing and rendering |
| [DESIGN.md](DESIGN.md) | Visual reference filtered to v1 screens |
| [WORKFLOW.md](WORKFLOW.md) | Scope, PR and execution rules |
| [HANDOFF.md](HANDOFF.md), [handoffs/P3.md](handoffs/P3.md) | Current source, findings and continuation |
| [DECISIONS.md](DECISIONS.md), [RISKS.md](RISKS.md), [VALIDATION.md](VALIDATION.md) | Necessary choices, source risks and user testing |
| [BASELINE.md](BASELINE.md), [handoffs/P0.md](handoffs/P0.md) | Historical source evidence, not feature authority |
| [ISSUE_21.md](ISSUE_21.md) | Original 467-item snapshot: historical only, not a backlog |
| [phases/P0.md](phases/P0.md)–[P7.md](phases/P7.md) | Active briefs; P8–P13 retired |

Planning #22 and P0 #23 merged. P1 PR #24 was squash merged as 97d3645. P2 PR #25 was squash merged as 97d647e. P3 is source-integrated in [PR #26](https://github.com/hoangbkit/Inkribe/pull/26), branch feat/ios-p3-caption-editor, held open for review; no merge/auto-merge. Source is uncompiled. The reported autosave race and URL size-limit findings were corrected in source after the scope reset; runtime verification is still pending. Preserve Mac. No builds/tests, CI, project generation, model downloads or device validation; user tests afterward.

P2 source outcomes, model placement and native/runtime limitations: [handoffs/P2.md](handoffs/P2.md). P3 editor and persistence contracts: [handoffs/P3.md](handoffs/P3.md). Schema v1/v2 reads remain supported; writes now use v3 for manual timing and hidden text.
