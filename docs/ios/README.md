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
| [HANDOFF.md](HANDOFF.md), [handoffs/P7.md](handoffs/P7.md) | Current source, findings and continuation |
| [DECISIONS.md](DECISIONS.md), [RISKS.md](RISKS.md), [VALIDATION.md](VALIDATION.md) | Necessary choices, source risks and user testing |
| [BASELINE.md](BASELINE.md), [handoffs/P0.md](handoffs/P0.md) | Historical source evidence, not feature authority |
| [ISSUE_21.md](ISSUE_21.md) | Original 467-item snapshot: historical only, not a backlog |
| [phases/P0.md](phases/P0.md)–[P7.md](phases/P7.md) | Active briefs; P8–P13 retired |

Planning #22 and P0 #23 merged. P1 PR #24 was squash merged as 97d3645. P2 PR #25 was squash merged as 97d647e. P3 PR #26 was squash merged as 11902e6. P4 [PR #27](https://github.com/hoangbkit/Inkribe/pull/27) was squash merged as ab67747. P5 [PR #28](https://github.com/hoangbkit/Inkribe/pull/28) was squash merged as 3c09e32. P6 [PR #29](https://github.com/hoangbkit/Inkribe/pull/29) was squash merged as e2bb512. The optional speech-model request is on feat/ios-optional-speech-models from that develop; leave its PR open until asked to merge. The user subsequently requested P7 in the same PR #30; its hardening and handoff are source-integrated, with runtime validation unrun. The user explicitly deferred Pro. Source is uncompiled. The reported autosave race and URL size-limit findings were corrected in source after the scope reset; runtime verification is still pending. Preserve Mac. No builds/tests, CI, project generation, model downloads or device validation; user tests afterward.

Current optional-download/bundled model setup: [MODELS.md](MODELS.md). P2 historical source outcomes and native/runtime limitations: [handoffs/P2.md](handoffs/P2.md). P3 editor and persistence contracts: [handoffs/P3.md](handoffs/P3.md). P4 style/render contracts: [handoffs/P4.md](handoffs/P4.md). Schema v1–v4 reads remain supported; writes now use v5 for non-destructive media edits.

P5 export/persistence/delivery contracts and pending user checks: [handoffs/P5.md](handoffs/P5.md). Four export items are source-integrated; V1.PRO is deferred by user choice. P5 used project schema v4. No commercial limits/products/prices were introduced.

P6 trim/framing/volume, canonical/output timing, compatibility, preview races and user scenarios: [handoffs/P6.md](handoffs/P6.md). All three P6 items are source-integrated, with native API/render/runtime validation still unrun. Pro remains deferred.
