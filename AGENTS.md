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
- One PR per requested phase from latest develop targeting develop; all passes in it. P0–P6 are squash merged (#23–#29); P6 merge is e2bb512. PR #30 on feat/ios-optional-speech-models contains the optional-model change and, by explicit subsequent user instruction, P7 in the same PR. Leave it open until explicitly asked to merge; do not create another phase branch/PR.
- No CI setup/triggers, project regeneration, model downloads or device validation. User tests afterward.
- Short UI plan before edits. The current user request authorizes P6 with the stated Media panel: whole-project trim start/end, aspect presets, fit/fill/zoom/pan and original-audio volume, integrated with undo/autosave/preview/export. Do not re-ask for routine details or run UI tests. Future phases and excluded features need their own request.
- The user explicitly selected Defer Pro for P5. Implement the four export items; V1.PRO remains deferred. Do not invent gates, limits, products, prices, watermark/trials or a paywall offer.

- P6 keeps persisted clips/recognition/manual timing in the original project clock. One retained-range map drives zero-based preview/MP4/SRT; never destructively delete trimmed captions or originals. Project writes use schema v5, with v1–v4 readable.

## Current optional speech-model request

The user explicitly authorizes optional bundling, in-app download/cache and variant selection for faster development, while retaining a future hard-bundled production flow. This updates V1.LOCAL_STT/V1.JOB. The user subsequently requested P7 in the same PR #30, overriding the usual separate-phase PR rule. The stated UI is a Speech Models sheet from Projects settings, transcription and Storage, with Tiny/Base/Small multilingual variants, progress/cancel/select/remove. Routine implementation is authorized; do not add cloud inference or larger model families. Read docs/ios/MODELS.md for exact packaging/cache/job contracts. Default project.yml omits iOS weights; project-ios-bundled.yml requires Small and disables download/cache fallback via INKRIBE_IOS_BUNDLED_MODELS_ONLY. Mac resources remain unchanged. Do not download weights or run generation/build/test/CI/device work yourself.

## P7 authorization and final source handoff

The user explicitly said to keep working on the last phase in this PR. P7 owns V1.RECOVERY/BOUNDS/ACCESS/HANDOFF and is included in PR #30 with optional models. Its short plan covers source audit and concrete recovery/cancellation/stale-result/cleanup/accessibility/error fixes; no redesign or new feature scope. Read docs/ios/handoffs/P7.md for outcomes and user checks. Source integration is not release/runtime validation. No builds/typechecks/tests, CI, generation, weights or device work. Keep PR #30 open until asked to merge. Pro remains deferred; do not start excluded work.
