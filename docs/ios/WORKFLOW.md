# Inkribe iOS — current working agreement

2026-10-24. Latest user instructions and root AGENTS.md control authorization.
Current work is consolidation of the five implemented source passes in existing
PR #39, `feat/ios-project-packages` → develop. Earlier phase-only holds/Pro deferral
and references to old open PRs are historical, preserved in
[the archive](archive/before-consolidation/WORKFLOW.md).

The latest project-saving instruction supersedes editor-journal requirements in
older phase records. Remove the app sidecar dependency and recovery-management UI;
retain serialized atomic saves and unsaved edits in app-owned memory. No legacy
migration work or destructive cleanup is requested.

## Scope and PR procedure

1. Read README, PLAN, FEATURES, HANDOFF, ARCHITECTURE, DESIGN and the relevant
   phase/handoff. Inspect current source and refresh actual develop/PR heads.
2. Preserve all work in PR #39 for this requested scope. Use a short concrete plan
   before changes; settled interaction details and supported integration fixes are
   authorized. Ask only about actual scope expansion.
3. Preserve working transcription/partial publication, raw/native IDs/timing,
   caption edits/undo/allowance, packages/queue/frozen outputs, original
   media and existing Mac identity/config/resources/APIs.
4. Review complete call paths and failure/retention behavior. Source fixtures or
   meaningful regression specifications may be authored but must not be executed.
5. Update current handoff, source evidence and issue/PR metadata honestly. Distinguish
   integration, source checks, executed validation and owner inputs.
6. Keep PR open with auto-merge disabled. Merge/release/deployment and another phase
   require explicit instructions.

## Execution limits

No builds, typechecks, tests, fixture execution, CI setup/triggers/runs, Xcode project
generation, model downloads, native inference/exports, UI/device/accessibility
execution or deployment. User tests afterward. Source review is not runtime evidence.
Do not provision signing/store/website resources or invent policy URLs/disclosures.

XcodeGen owns project.yml; never hand-edit generated .xcodeproj files. iOS remains
Inkribe/, target Inkribe, iPhone only. Mac remains InkribeMac/. Only the two legacy
JobQueue adapters retain IOS-prefixed names because their persisted type names
are part of the upgrade contract. Shared AppIcon.icon/resource ownership is retained.

This workspace is a partial review snapshot with synthetic local git history.
Publish only changed blobs onto the full remote base tree; never push/replace the
remote tree from this snapshot. Verify changed hashes, unchanged remote blobs and
an expected-head branch lease, then final PR state/base/head. This applies while
that snapshot remains in use; a future real clone should verify its own history.

## Continuation

Use HANDOFF for the current source milestone and PRODUCTION_READINESS for pending
acceptance. Original phases and archived status do not authorize extra features,
execution or resources. Never claim production readiness without the evidence.
