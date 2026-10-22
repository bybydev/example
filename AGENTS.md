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
- One PR per requested phase from latest develop targeting develop; all passes in it. P0–P4 are squash merged (#23–#27); P4 merge is ab67747. P5 PR #28 uses feat/ios-p5-export from that develop. Leave it open for review; no merge/auto-merge until asked.
- No CI setup/triggers, project regeneration, model downloads or device validation. User tests afterward.
- Short UI plan before edits. The current user request authorizes P5 with the stated Export sheet, format/resolution, progress/cancel, Save to Photos/Files/share and current-export access. Do not re-ask for routine details or run UI tests. Future phases and excluded features need their own request.
- The user explicitly selected Defer Pro for P5. Implement the four export items; V1.PRO remains deferred. Do not invent gates, limits, products, prices, watermark/trials or a paywall offer.
