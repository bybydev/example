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
- One PR per requested phase from latest develop targeting develop; all passes in it. PR #24 stays open; no merge/auto-merge.
- No CI setup/triggers, project regeneration, model downloads or device validation. User tests afterward.
- Short UI plan/approval before new UI edits/tests. Existing routine P1 UI has approval. This docs reset authorizes no UI/code removal and starts no new phase.
