# Inkribe Working Rules


## Current project-saving simplification

The user rejects a separate draft/recovery workflow and asks for a friendly single
project experience in PR #39. This supersedes earlier editor-journal requirements:
remove the app's editor sidecar dependency, readiness checks, discard/reload flows
and sidecar-driven library/action gates. Save directly through the sole repository
with the existing serialized writer and atomic/revision checks; retain failed edits
in app-owned memory across navigation. Show one friendly save failure with Retry.
Rename remains accessible. Do not add legacy migration work or delete existing
files. Transcription checkpoints/partial publication, processing queues, frozen
exports, originals, undo/access and Mac behavior remain protected. No builds/tests,
CI/generation/models/native/UI/device execution or deployment; leave PR open.

## Current consolidation authorization

The user requests a consolidation pass across issue #38's five source passes in
existing PR #39 → develop. Fix supported integration defects and duplication;
consolidate current docs while preserving historical evidence. Read docs/ios/
CONSOLIDATION.md and current entry points. Do not expand feature scope, alter
working transcription/data/access contracts or run restricted execution. The
source-only checks and open/no-auto-merge rules below remain in force.

## Issue #38 — current production passes 1–5 authorization

The user explicitly authorized pass 5 in existing PR #39
(`feat/ios-project-packages` → develop), retaining passes 1–4. Implement versioned
shared style/catalog/resolved values, ten distinctive looks, native renderer weight/
shadow/background/layout/motion extensions and pass-4 browser/customization/reset/
access integration, compatibility and supported production source fixes. Read
phases/CAPTION_PRODUCTION, handoffs/CAPTION_PRODUCTION and PRODUCTION_READINESS
under docs/ios plus prior pass records. Preserve successful transcription/partial
publication, raw/native IDs/timing, corrections/undo/allowance, packages/jobs/frozen
outputs/journals and current Mac source/config/Transcript APIs. Canonical schema 8
reads 1–7; package/job/checkpoint/request wrappers remain stable. Opening legacy
looks does not resolve current catalog defaults. Keep the approved one-scroll
editor and iPhone-only support. Routine settled UI details are authorized after
the short plan. Leave PR open without auto-merge. Production acceptance remains
pending; do not manufacture device/footage/rendering/store evidence.

No builds, typechecks, tests, fixture execution, CI setup/triggers/runs, project
generation, model downloads, native inference/exports, deployment or UI/device/
accessibility execution. User tests afterward. Meaningful regression source may
be authored but must not be executed. Source integration is not production
verification. Earlier pass-only/PR holds below are historical for this scope.

## Issue #36 — current authorization

The user requests updating #36 and implementing the approved editor visualization in existing PR #37 (fix/ios-window-recovery → develop, baseline 525fae4), left open without auto-merge. The latest explicit implementation request supersedes the earlier complete-only publication/schema-v5 restriction: publish available captions incrementally, keep transcript/footage editable and exportable with inline missing ranges, and retry gaps while preserving edits. Schema v7 records coverage/mapping versions and reads v1–v6. Use bounded window recovery and versioned sidecars; only complete nonempty recognition charges. Scope includes the existing editor/transcription/export surfaces; preserve Mac/shared runtime, purchases, originals, native/manual anchors and legacy empty recovery. Read docs/ios/phases/TRANSCRIPTION_RECOVERY.md and handoffs/TRANSCRIPTION_RECOVERY.md. No builds/typechecks/tests, workflow dispatch, generation, weights, deployment or UI/device validation. Routine implementation choices for the approved UI and partial publication are authorized. The user subsequently reported an empty transcript after 1 of 4 windows on device. Correct the strict word-timing gate: preserve native segment-timed phrases when precise word timing is unavailable; never invent word boundaries. Retain mapping 1 for existing identities and record mapping 2 per new accepted core (schema v7). Do not claim the original video is fixed without runtime evidence.
- Do not fake completion. Source integration is not compilation or runtime evidence.
- Do not run builds/typechecks/tests, workflow dispatches, project generation, model downloads, deployment or device/UI validation. User tests afterward. The current user request explicitly authorizes source-only setup of the manual Build Release workflow; other CI setup remains outside scope.
- XcodeGen owns project.yml; do not modify generated .xcodeproj files.
- Preserve Mac identity, source, purchases, catalog, storage, resources and behavior.

## Scope and workflow

Read docs/ios/README.md, PLAN.md, FEATURES.md, WORKFLOW.md, HANDOFF.md and the requested phase brief. The compact 29-item v1 scope supersedes the historical 467-item catalog and P0–P13 roadmap. Old handoffs, images and Mac capabilities do not authorize features. No accounts/backend/cloud inference/sync, teams/social integration, credits, stock libraries, dubbing, share extension/App Group/inbox, camera, translation or advanced editor expansion.

One PR per requested phase from latest develop targeting develop; keep all passes in it. Leave open with auto-merge disabled until the user explicitly requests merge. Do not start another phase automatically. State scoped IDs and short UI plan; the current implementation request authorizes its settled UI and routine details. Ask only about actual new scope.

P0–P6 (#23–#29) and optional models plus P7 (#30) are squash merged. Latest phase baseline is eb89f0fb3cd0f67054e6d29de2375342718c1651. Historical PR review holds and P5 Pro deferral are superseded by the current request below.

## Pro phase — merged #31

The Pro implementation below is squash merged as 76981dee7533aab9b1194eee7376bf0ebfc60efb; its earlier PR review hold is historical.

### Approved Pro contract

Implement V1.PRO plus access rules on V1.LOCAL_STT/JOB/STYLE/PRESETS/MP4. Use feat/ios-pro-access-themes, one new PR targeting develop, leave open. Read docs/ios/phases/PRO.md and handoffs/PRO.md.

The user approved: free 5 minutes captioning/week versus unlimited Pro; basic free caption style versus all fonts/templates/animations; free 720p versus Pro 1080p; default free app theme versus all premium AppFoundation themes. Monthly $6.99 and lifetime $24.99 use com.hoangbkit.inkribe.pro.monthly and com.hoangbkit.inkribe.pro.lifetime. AppFoundation owns paywall, contextual upsell, restore, verified purchase state and theme picker/state. No watermark, trial, credit backend or new products.

Import/projects, caption text/timing/split/merge/undo, media tools and SRT remain free. Keep existing projects/captions/styles/export files usable after expiry; new premium choices require Pro. Failed/cancelled recognition is not charged; publication/retry is idempotent. Preserve accepted durable work across expiry and pre-policy jobs across upgrade.

## Existing local contracts

Schema v8 reads v1–v7; absent recognition coverage means a legacy complete result. Keep original clips/raw recognition/native/manual timing canonical. One retained-range map drives preview/MP4/SRT; trimming does not reduce recognition work. One renderer/media graph/audio mix serves preview and export. Keep bounded undo and serialized latest-draft persistence.

Optional bundle/download/cache and Tiny/Base/Small selection remain per docs/ios/MODELS.md. Default project.yml omits iOS weights; project-ios-bundled.yml requires Small and disables download/cache fallback through INKRIBE_IOS_BUNDLED_MODELS_ONLY. Release alone does not change packaging. No weights are to be downloaded by the agent.

## Current release-workflow request

The user explicitly requested the GitHub Build Release workflow based on hoangbkit/guidelines. Keep it in one new chore/manual-build-release PR from latest develop targeting develop, open until asked to merge. This authorizes workflow/helper/docs source edits only, overriding the earlier no-CI-setup rule for this release lane. No workflow dispatch, agent builds/tests, project generation, model downloads or deployment. Do not add Fast/Full CI or change application UI/runtime/model policy. Read docs/BUILD_RELEASE.md. Only workflow_dispatch; unsigned selected-platform archives plus generated Xcode project ZIP; mycli-build prerelease tags. Preserve app identities, Mac resources and source.


## Current iOS bundle identifier request

PR #32 (manual release workflow) is squash merged as 990ef4b. The user explicitly requests a new PR changing the Inkribe iOS target to com.hoangbkit.inkribe in both Debug and Release. Keep this on chore/ios-bundle-identifier from latest develop targeting develop, open until asked to merge. Update the archive identity validator accordingly. Mac remains com.hoangbkit.inkribe.debug in Debug and com.hoangbkit.inkribe in Release. Keep existing iOS preference/storage keys, product IDs and entitlements unchanged. No builds/tests, workflow dispatch, generation, model downloads or device validation. Historical P0 bundle IDs are superseded by this request.

## iOS source naming correction

The user requires the iOS app source folder to be Inkribe/, matching its target, alongside InkribeMac/. App files/types use plain names without IOS prefixes; InkribeApp is the entry point and ProjectCanvas is the domain canvas. Only the two adapters in Inkribe/Storage/LegacyJobCompatibility.swift retain old type names because JobQueue 1.0 persists those names. Existing storage paths, defaults keys, model IDs, schema fields and queue payloads remain stable. Keep these changes in PR #33, open until asked to merge. No builds/tests, CI runs, Xcode generation, weights or device checks.

The user requires iPhone-only support: TARGETED_DEVICE_FAMILY is 1 for both iOS configurations, inherited by the bundled-model spec. Do not re-enable iPad support.

Both app targets must use the same existing InkribeMac/AppIcon.icon resource, following Spokio. iOS selects AppIcon and references that file directly; do not duplicate or redesign the artwork.
