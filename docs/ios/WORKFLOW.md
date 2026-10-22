# V1 working agreement

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

Planning #22 and P0 #23 are merged. P1 PR #24 was squash merged as 97d3645. P2 PR #25 was squash merged as 97d647e on user instruction. P3 PR #26 was squash merged as 11902e6 on user instruction. P4 PR #27 was squash merged as ab67747 on user instruction. P5 PR #28 was squash merged as 3c09e32 on user instruction. The user requested P6 next from that latest develop. **Leave P6 PR #29 open for review; no merge/auto-merge until asked.**

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
