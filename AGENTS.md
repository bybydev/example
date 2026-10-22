# Inkribe Working Rules

- Do not fake completion. Source integration is not compilation or runtime evidence.
- Do not run builds/typechecks/tests, CI setup/triggers, project generation, model downloads, deployment or device/UI validation. User tests afterward.
- XcodeGen owns project.yml; do not modify generated .xcodeproj files.
- Preserve Mac identity, source, purchases, catalog, storage, resources and behavior.

## Scope and workflow

Read docs/ios/README.md, PLAN.md, FEATURES.md, WORKFLOW.md, HANDOFF.md and the requested phase brief. The compact 29-item v1 scope supersedes the historical 467-item catalog and P0–P13 roadmap. Old handoffs, images and Mac capabilities do not authorize features. No accounts/backend/cloud inference/sync, teams/social integration, credits, stock libraries, dubbing, share extension/App Group/inbox, camera, translation or advanced editor expansion.

One PR per requested phase from latest develop targeting develop; keep all passes in it. Leave open with auto-merge disabled until the user explicitly requests merge. Do not start another phase automatically. State scoped IDs and short UI plan; the current implementation request authorizes its settled UI and routine details. Ask only about actual new scope.

P0–P6 (#23–#29) and optional models plus P7 (#30) are squash merged. Latest phase baseline is eb89f0fb3cd0f67054e6d29de2375342718c1651. Historical PR review holds and P5 Pro deferral are superseded by the current request below.

## Current authorized phase: Pro locking and AF themes

Implement V1.PRO plus access rules on V1.LOCAL_STT/JOB/STYLE/PRESETS/MP4. Use feat/ios-pro-access-themes, one new PR targeting develop, leave open. Read docs/ios/phases/PRO.md and handoffs/PRO.md.

The user approved: free 5 minutes captioning/week versus unlimited Pro; basic free caption style versus all fonts/templates/animations; free 720p versus Pro 1080p; default free app theme versus all premium AppFoundation themes. Monthly $6.99 and lifetime $24.99 use com.hoangbkit.inkribe.pro.monthly and com.hoangbkit.inkribe.pro.lifetime. AppFoundation owns paywall, contextual upsell, restore, verified purchase state and theme picker/state. No watermark, trial, credit backend or new products.

Import/projects, caption text/timing/split/merge/undo, media tools and SRT remain free. Keep existing projects/captions/styles/export files usable after expiry; new premium choices require Pro. Failed/cancelled recognition is not charged; publication/retry is idempotent. Preserve accepted durable work across expiry and pre-policy jobs across upgrade.

## Existing local contracts

Schema v5 reads v1–v4. Keep original clips/raw recognition/native/manual timing canonical. One retained-range map drives preview/MP4/SRT; trimming does not reduce recognition work. One renderer/media graph/audio mix serves preview and export. Keep bounded undo and serialized latest-draft persistence.

Optional bundle/download/cache and Tiny/Base/Small selection remain per docs/ios/MODELS.md. Default project.yml omits iOS weights; project-ios-bundled.yml requires Small and disables download/cache fallback through INKRIBE_IOS_BUNDLED_MODELS_ONLY. Release alone does not change packaging. No weights are to be downloaded by the agent.
