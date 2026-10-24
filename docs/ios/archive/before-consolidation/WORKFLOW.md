> Historical snapshot before the 2026-10-24 consolidation. Current contracts are in [README](../../README.md); instructions and status here are superseded.

# V1 working agreement

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

> Current request (2026-10-23): PR #35 is merged as 525fae4. Issue #36 is explicitly authorized in one new fix/ios-window-recovery PR from latest develop targeting develop, held open without auto-merge. All passes remain in this PR. The progress/range/retry/discard UI is in scope. Read phases/TRANSCRIPTION_RECOVERY and handoffs/TRANSCRIPTION_RECOVERY; preserve source-only execution limits. Earlier #35 holds below are historical.

> Current repair (2026-10-23): all four requested passes are source-implemented in open PR #35 targeting develop; no auto-merge. Read [handoffs/TRANSCRIPTION_WORKSPACE.md](../../handoffs/TRANSCRIPTION_WORKSPACE.md) and [HANDOFF.md](../../HANDOFF.md) for current behavior and user validation. Builds/runtime/device checks are unrun. Earlier phase/Pro branch holds below are historical; no next phase or merge is authorized.

> Current amendment (2026-10-22): PR #30 is squash merged as eb89f0f. The user has now authorized Pro locking and AF themes; [phases/PRO.md](../../phases/PRO.md) and [handoffs/PRO.md](../../handoffs/PRO.md) supersede historical Pro deferral, 28/29 accounting and PR #30 review holds below. The new phase stays open on feat/ios-pro-access-themes → develop. All 29 V1 items are source-integrated; compilation/runtime/user validation is unrun.

## Scope

Current user instructions, root AGENTS and PLAN/FEATURES control work. Only current V1 items in the requested phase are required. Old catalog/phase prompts, images, frameworks and existing extra code do not expand scope. State included IDs and concrete result before implementation; ask about actual scope expansions before adding them.

## PR procedure

1. Read current scope/architecture/design/handoff; refresh latest develop.
2. Start one new branch and one PR targeting develop per requested phase.
3. Keep all passes, fixes and integrations in that PR; no stacked PRs.
4. Preserve Mac; no unrelated service/infrastructure work.
5. Update FEATURES, phase brief, HANDOFF and handoffs/Pn with actual outcomes.
6. Incorporate relevant latest develop and resolve conflicts. Leave phase PRs open for review until the user explicitly requests merging.
7. Start no next phase without request.

Planning #22 and P0 #23 are merged. P1 PR #24 was squash merged as 97d3645. P2 PR #25 was squash merged as 97d647e on user instruction. P3 PR #26 was squash merged as 11902e6 on user instruction. P4 PR #27 was squash merged as ab67747 on user instruction. P5 PR #28 was squash merged as 3c09e32 on user instruction. P6 #29 was subsequently squash merged as e2bb512 on user instruction. The user then explicitly requested optional speech-model bundles/download/cache/selection. Keep this follow-up in one new PR from that develop, open until asked to merge. The user subsequently requested P7 in the same PR #30, overriding the usual one-new-PR-per-phase rule.

## Execution limits

No builds/tests unless asked; no CI setup/repair/triggers, project generation, model downloads, deployment, paid services/media uploads or device validation. User tests afterward. Source inspection is not a test/build pass.

Present a short plan and obtain relevant new UI approval. Existing approvals cover their requested phases, not unrequested scope/UI removal. Do not re-ask for settled routine details. The P4 request covered Style/Templates and the four effects; the current P6 request and stated Media plan are recorded below.

Blocked required behavior stays incomplete; no mock output, fake timestamps or extra services. Keep necessary model/commerce choices explicit rather than inventing them.

## Fresh-agent prompt

> Implement only current Inkribe iOS v1 phase Pn. Read AGENTS, docs/ios/README, PLAN, FEATURES, WORKFLOW, HANDOFF and phases/Pn first. State the V1 IDs and short plan. Old 467-item catalog is historical. One PR from latest develop targeting develop; all passes in it. Preserve Mac. No builds/tests, CI, project generation, model downloads or device validation. Follow current UI approval and merge hold. Do not expand scope or start another phase.

## P5 authorization — historical phase, Pro deferral persists

The P5 request covered the stated Export sheet, format/resolution controls, progress/cancel/retry, native Photos/Files/share delivery, storage accounting and current-export access. The user explicitly selected **Defer Pro**. Its four export items were source-integrated; V1.PRO stays deferred, with no invented commercial policy, IDs, restrictions or prices. P6 was separately requested after P5 merge, as recorded below.

## P6 authorization and scope

The user requested the next phase after merging P5. The stated Media panel covers V1.TRIM/CROP/VOLUME: non-destructive whole-project trim, aspect presets, fit/fill/zoom/pan and original-audio volume. Keep all passes in feat/ios-p6-media-editing. Preserve original clips/recognition and use one derived retained-range map in preview/MP4/SRT, with revisioned undo/autosave. Pro remains deferred by prior explicit choice. Do not start P7 or expand into advanced media tools.

## Current optional model authorization

The user explicitly requests retaining bundled support while making weights optional for development, adding app downloads/cache and model variants, with the option to hard-bundle for production later. The stated sheet and scope in DESIGN/MODELS cover this work. No agent model downloads, CI, builds/typechecks/tests, generation or device validation are authorized. Default development packaging and the opt-in bundled spec are source changes only. Preserve Mac; Pro is still deferred.

## P7 — explicit same-PR authorization

The user requested finishing the last phase in this PR. P7 source audit/fixes and handoff therefore stay on feat/ios-optional-speech-models in PR #30 targeting develop; no new branch/PR or merge is authorized. This supersedes earlier P7-not-started instructions. V1.RECOVERY/BOUNDS/ACCESS/HANDOFF are source-integrated with no compilation/runtime/device evidence. Pro remains deferred. No build/typecheck/test, CI, generation, weights, deployment, hardware or UI validation work. User runs the scenarios in handoffs/P7.md.

## Current Pro authorization

The user has now supplied the policy/plans/IDs/prices and requested implementation, including AF themes. This overrides the historical Pro deferral in the phase notes above. All Pro work stays in one new feat/ios-pro-access-themes PR from merged develop eb89f0f, targeting develop and held open until asked to merge. No builds/typechecks/tests, CI, generation, weights or device validation. Update phases/PRO, handoffs/PRO and current V1 accounting; do not add another phase or change Mac.
