# V1 working agreement

## Scope

Current user instructions, root AGENTS and PLAN/FEATURES control work. Only current V1 items in the requested phase are required. Old catalog/phase prompts, images, frameworks and existing extra code do not expand scope. State included IDs and concrete result before implementation; ask about actual scope expansions before adding them.

## PR procedure

1. Read current scope/architecture/design/handoff; refresh latest develop.
2. Start one new branch and one PR targeting develop per requested phase.
3. Keep all passes, fixes and integrations in that PR; no stacked PRs.
4. Preserve Mac; no unrelated service/infrastructure work.
5. Update FEATURES, phase brief, HANDOFF and handoffs/Pn with actual outcomes.
6. Incorporate relevant latest develop and resolve conflicts. Honor explicit review holds first; otherwise standing workflow is squash merge when finished.
7. Start no next phase without request.

Planning #22 and P0 #23 are merged. P1 PR #24 was squash merged as 97d3645. P2 PR #25 was squash merged as 97d647e on user instruction. **P3 PR #26 stays open for review, no merge/auto-merge.** The user requested this phase after merging P2.

## Execution limits

No builds/tests unless asked; no CI setup/repair/triggers, project generation, model downloads, deployment, paid services/media uploads or device validation. User tests afterward. Source inspection is not a test/build pass.

Present a short plan and obtain relevant new UI approval. Existing P1 approval covers routine implementation, not unrequested scope/UI removal. Do not re-ask for settled routine details. The current P3 request and stated plan cover the scoped compact preview, transport, simple timeline, caption/word correction, timing, split/merge and undo/redo layout.

Blocked required behavior stays incomplete; no mock output, fake timestamps or extra services. Keep necessary model/commerce choices explicit rather than inventing them.

## Fresh-agent prompt

> Implement only current Inkribe iOS v1 phase Pn. Read AGENTS, docs/ios/README, PLAN, FEATURES, WORKFLOW, HANDOFF and phases/Pn first. State the V1 IDs and short plan. Old 467-item catalog is historical. One PR from latest develop targeting develop; all passes in it. Preserve Mac. No builds/tests, CI, project generation, model downloads or device validation. Follow current UI approval and merge hold. Do not expand scope or start another phase.
