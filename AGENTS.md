# Inkribe Working Rules

- Do not fake completion; report problems honestly.
- Do not run builds or tests unless asked.
- XcodeGen owns project.yml; do not modify generated .xcodeproj files.

## iOS v1.0 scope

Read docs/ios/README.md, PLAN.md, FEATURES.md, WORKFLOW.md, HANDOFF.md and the requested phase brief first.

- The compact v1 scope dated 2026-10-22 supersedes the exhaustive 467-item catalog and P0–P13 plan. Only current V1 items and P0–P7 briefs define deliverables. Historical issue/handoffs and Mac capabilities do not authorize features.
- Do not add accounts/backends, cloud STT/AI/sync, teams, social integrations, credits, stock libraries, dubbing, share extension/App Group/inbox, camera/teleprompter, translation, automation or advanced editor features excluded by PLAN.
- State included V1 IDs and short concrete plan before each requested phase. Obtain explicit approval for scope expansions; do not invent infrastructure or pricing.
- Preserve Mac identity, purchases, entitlements, storage and behavior. AppFoundation for iOS; reuse useful portable code without forced abstractions.
- One PR per requested phase from latest develop targeting develop; all passes in it. P0–P3 are squash merged (#23/#24/#25/#26). P4 PR #27 uses feat/ios-p4-caption-styles from develop 11902e6; leave its PR open, no merge/auto-merge until asked.
- No CI setup/triggers, project regeneration, model downloads or device validation. User tests afterward.
- Short UI plan/approval before new UI edits/tests. Existing routine P1 UI has approval. The user requested P4 implementation after merging P3. Its stated Style/Templates panels, four built-in fonts and highlight/karaoke/pop/fade presets cover routine P4 UI in that request; no renewed routine approval. Future phases and excluded-feature work need their own request.
