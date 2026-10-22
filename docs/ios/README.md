# Inkribe for iOS — start here

This directory is the self-contained implementation handoff for [issue #21](https://github.com/hoangbkit/Inkribe/issues/21). It plans the complete caption/video product in the existing repository. The Mac app keeps its existing behavior and product identity.

**Status (2026-10-22):** Planning PR [#22](https://github.com/hoangbkit/Inkribe/pull/22) was squash merged into `develop`. P0 was separately authorized and is implemented in source in [draft PR #23](https://github.com/hoangbkit/Inkribe/pull/23), targeting `develop`, **held open for review**. It has not been built, tested, regenerated or device-validated. P1–P13 have not started.

## Reading order

1. Read root [AGENTS.md](../../AGENTS.md) and [WORKFLOW.md](WORKFLOW.md).
2. Read [HANDOFF.md](HANDOFF.md) for current state and resumption instructions.
3. Read [PLAN.md](PLAN.md), [BASELINE.md](BASELINE.md), [ARCHITECTURE.md](ARCHITECTURE.md) and [DESIGN.md](DESIGN.md).
4. Open the requested [phase brief](phases/P0.md), its mapped items in [FEATURES.md](FEATURES.md), and the relevant existing source.
5. Consult [DECISIONS.md](DECISIONS.md), [RISKS.md](RISKS.md) and [VALIDATION.md](VALIDATION.md) as needed.

## Documents

| File | Role |
|---|---|
| [PLAN.md](PLAN.md) | Scope, phase index, dependencies and scope accounting |
| [PHASES.md](PHASES.md) | Full original phase plan, difficulty/value table and large-phase units |
| [FEATURES.md](FEATURES.md) | All 467 original feature items with stable IDs and primary owners |
| [ISSUE_21.md](ISSUE_21.md) | Complete verbatim issue-body snapshot, including all rationale and criteria |
| [BASELINE.md](BASELINE.md) | Inspected develop commit, existing code and differences from the issue baseline |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Ownership, domain/time/render/persistence contracts and proposed boundaries |
| [DESIGN.md](DESIGN.md) | Embedded reference image, screen flow, design decisions and approval points |
| [WORKFLOW.md](WORKFLOW.md) | Branch/PR/merge procedure, authorization and no-CI/no-device rules |
| [VALIDATION.md](VALIDATION.md) | Allowed review, deferred user testing and honest completion reporting |
| [DECISIONS.md](DECISIONS.md) | Fixed decisions and unresolved implementation choices |
| [RISKS.md](RISKS.md) | Risks, owners, evidence required and unresolved platform/provider limitations |
| [HANDOFF.md](HANDOFF.md) | Live progress, next authorized action and continuation/review prompts |
| [handoffs/TEMPLATE.md](handoffs/TEMPLATE.md) | Completion/resumption record to fill during each phase |
| [handoffs/P0.md](handoffs/P0.md) | Actual P0 changes, source evidence, unresolved assumptions and user checks |
| [phases/P0.md](phases/P0.md)–[P13.md](phases/P13.md) | Specific implementation briefs for all 14 phases |

The historical Mac v1 phases in `docs/handoffs/PHASE_*.md` and `docs/V1_IMPLEMENTATION_PLAN.md` are a separate sequence. Do not mark iOS phases complete because the Mac README says its phases are complete.

## Authority and maintenance

Current explicit user instructions take precedence. Root AGENTS.md applies. WORKFLOW.md records current execution rules; the archived issue snapshot is evidence, not a source of permission to run builds/CI or change apps.

FEATURES.md is the editable feature ledger; phase briefs own implementation detail. Update these documents and the phase handoff in the same phase PR. Keep ISSUE_21.md unchanged as a dated snapshot. Keep issue #21 as the GitHub roadmap and link relevant PRs rather than depending on a chat for missing requirements.
