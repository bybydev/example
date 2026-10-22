# Inkribe iOS — complete implementation plan

## Product scope

Build Inkribe for iOS as a creator-grade caption/video editor in this repository. Rename the existing macOS target to `InkribeMac`; the new iOS target is `Inkribe`. Both display the product name Inkribe. Do not reuse the abandoned experimental product name.

The full inventory includes import/recording, local and optional cloud recognition, word editing, animated captions, export, video/audio editing, AI enhancement, localization/dubbing, templates/brands, batch/publishing, organization/collaboration, commerce and accessibility. This is not a reduced v1 scope.

All 467 source items are in [FEATURES.md](FEATURES.md); the complete issue is in [ISSUE_21.md](ISSUE_21.md). The source phase descriptions and assessment are retained in [PHASES.md](PHASES.md).

## Phase index

P0 was explicitly authorized, and its implementation source is in draft [PR #23](https://github.com/hoangbkit/Inkribe/pull/23), awaiting review and user-run checks. P1–P13 remain not started. Planning PR #22 was already squash merged.

| Phase | Brief | Primary result | Prerequisites / later integrations |
|---|---|---|---|
| P0 | [Target isolation and feasibility](phases/P0.md) | Separate targets, preservation audit, domain/render contracts | No feature phase required |
| P1 | [Media and projects](phases/P1.md) | Durable projects/imports, basic library/autosave | P0; direct recording in P9 |
| P2 | [Speech and word timing](phases/P2.md) | Bounded pipeline, durable timed words/speakers | P1; cloud features require explicit opt-in |
| P3 | [Editor](phases/P3.md) | Synchronized caption list/timeline/preview, undo | P1/P2; reuses P0 rendering contract |
| P4 | [Caption styling/animation](phases/P4.md) | Deterministic caption scene evaluation | P0/P3; template sharing in P10 |
| P5 | [Export/delivery/commerce](phases/P5.md) | Real video exports and individual entitlements | P1–P4; localization needs P7, batches P11 |
| P6 | [Video/audio composition](phases/P6.md) | Non-destructive multi-track editing | P1/P3/P5 contracts; extends render engine |
| P7 | [AI/localization](phases/P7.md) | Reviewed styling, translation and dubbing | P2/P4; dubbing needs relevant P6 audio support |
| P8 | [AI video edits](phases/P8.md) | Reversible suggested edits and enhancements | P2/P6; supported primitives precede orchestration |
| P9 | [Recording/prompter](phases/P9.md) | Recoverable capture into normal project pipeline | P1/P2; script AI uses approved provider/runtime |
| P10 | [Overlays/templates/brands](phases/P10.md) | Reusable designs, graphics, tracking/masking | P4/P6; shared brands need P12 |
| P11 | [Batch/creator/publishing](phases/P11.md) | Reusable pipelines, variants, permitted publishing | Existing relevant engines; teams/scheduling may need P12/backend |
| P12 | [Organization/sync/teams/billing](phases/P12.md) | Optional cloud/team workflows and advanced billing | Durable schemas and P5 individual commerce |
| P13 | [Hardening/accessibility](phases/P13.md) | Whole-inventory audit and code hardening | Continuous obligations; final pass across implemented phases |

P0–P13 are workstreams, not unconditional strict-waterfall release cuts. A user can request a dependency-ready phase; do not start another phase on your own.

## Dependency accounting

1. The first complete captioning proof is import → timed words → correction → styled preview → matching exported video.
2. A rendering feasibility prototype belongs to P0; the full caption engine belongs to P4 and production delivery to P5. Anticipate multi-track composition without implementing P6 in P0.
3. Basic library, app-owned media and autosave are P1. Individual-user commerce/restoration and export validation arrive by P5 before any paid release.
4. P5 owns delivery plumbing for language tracks, but translated content arrives in P7. P10 owns reusable template/brand workflows; P4 owns basic saved caption styles.
5. P1 import adapters route to P9 capture when it exists. A planning reference to recording in import does not require full camera implementation during P1.
6. P11 owns comprehensive batch pipelines. Earlier engines own reliable single-job operations and queue adapters. P12 owns collaboration, not compulsory accounts for local use.
7. For a later dependency, record the exact feature ID and integration owner in both phase handoffs. Label it “dependency pending”; do not show a nonfunctional control or mark the feature complete. When that dependency lands, complete and verify the integration in its phase PR.
8. If a dependency invalidates a core contract, explain the change and update the relevant brief before implementing it. Do not silently shrink a phase.

## Execution boundaries

Follow [WORKFLOW.md](WORKFLOW.md): one PR per requested phase from latest develop, all passes in it. Planning PR #22 has been merged. The newer explicit instruction for P0 PR #23 is to **leave open for review, without merge or auto-merge**.

Do not set up/trigger CI or perform device validation. Root AGENTS.md also prohibits builds/tests unless asked. The user tests finished implementation. Static reasoning and source/document review should identify correctness risks without claiming runtime validation.

## Completion accounting

Track separately: implementation status, allowed verification evidence, user-device testing status, dependencies pending and accepted limitations. An implementation-complete phase may be merged with user testing pending; unavailable essential behavior must be reported as partial/blocked rather than fabricated as complete. API/legal/platform limitations need specific documented evidence and user acceptance before closing a feature.

Refresh each phase brief against the actual latest develop code at its start. Current source paths are inspection entry points, not promises that future code keeps the same filenames.
