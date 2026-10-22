# Working agreement

## Current authorization

The user authorized a **planning-only PR targeting develop** containing the full roadmap and implementation handoff. **Do not merge this planning PR until the user explicitly says to merge it.** Do not start P0 or another feature phase from this request.

For later implementation, start a phase only when requested. Refresh current user instructions and root [AGENTS.md](../../AGENTS.md). Session instructions take precedence over historical issue text.

## One PR per phase

1. Read the relevant phase brief, architecture/design contracts, feature IDs and latest handoff.
2. Refresh remote develop and branch from its latest head. Use a new phase branch and one PR with base develop.
3. Keep every internal unit, pass, correction and dependency integration for that phase in the same PR. No stacked PRs or PR per pass. Do not reuse a completed phase's branch for the next phase.
4. Focus on functioning implementation. Keep changes scoped; do not refactor the Mac app or add backend/accounts/infrastructure just because a later phase mentions them.
5. Before merge, incorporate latest develop as necessary, resolve conflicts and review the complete diff. Do not force-update develop or overwrite someone else's work.
6. Update FEATURES.md, the phase brief, HANDOFF.md and `handoffs/Pn.md` with actual outcomes, decisions, checks and remaining limitations.
7. Squash merge when the requested phase is implementation-complete. The user's standing instruction authorizes this for implementation phases without a separate merge confirmation, unless a newer instruction puts that PR on hold.
8. Do not advance to another phase until requested.

The present planning PR remains on hold regardless of the standing phase merge instruction. Do not enable auto-merge for it.

## Implementation and validation limits

- **No CI setup or triggers.** Do not add/configure/enable/dispatch/rerun CI or spend effort repairing workflows. Do not require CI results as a completion gate.
- **No device validation.** No physical-device installation/testing, device benchmarks or performance campaigns. The user will test finished work.
- **No builds/tests unless asked.** Root AGENTS.md is stricter than the historical issue's permission to use focused local compilation. Reading this plan is not a request to run a build/test. Report unrun checks honestly.
- **UI changes/tests:** present the relevant layout or concise UI plan and obtain the user's approval before UI alterations or manual UI tests, consistent with the existing working agreement. An already-approved exact design need not be reapproved without a material change.
- No unsolicited deployment, model downloads, paid cloud usage, source-media uploads or external publishing.
- Respect XcodeGen ownership. Modify project.yml when target work is authorized; do not hand-edit generated .xcodeproj files.

If a required integration is unavailable, do independent implementation that remains valid, document the blocker and report the incomplete portion. Do not fake completion, substitute demo outputs for functioning features, or weaken the feature inventory to make a phase appear finished.

## Review allocation

The user may use GPT-6 Sol High for implementation and GPT-6.1 Sol High for critical review/fixes. Suggested reviews: P0/P1 boundaries and persistence, P2 word timing/memory, P3 editor state, P4/P5 preview/export fidelity, P6 transformed timing, and P13 final hardening. This is a recommended allocation, not a mandatory model or an automatic requirement to spawn agents.

If the user requests review before a phase merges, keep that PR open until the review and required fixes finish. Do not infer that every phase requires a second model or additional permission to merge.

## PR descriptions

State the phase, user-visible result, feature IDs covered, shared/Mac impact, persistence changes, evidence actually collected and outstanding user testing. Link issue #21 without using a closing keyword that would close the entire roadmap after one phase. State whether the PR is on hold.

## Fresh-session prompt

> Implement only Inkribe iOS phase Pn from latest develop. Read AGENTS.md, docs/ios/README.md, WORKFLOW.md, HANDOFF.md and phases/Pn.md first. Keep all passes in one PR targeting develop. Do not set up/trigger CI, run builds/tests unless asked, or perform device validation; I will test after completion. Preserve Mac behavior and the full feature inventory. Follow any current hold/review instructions before merging.
