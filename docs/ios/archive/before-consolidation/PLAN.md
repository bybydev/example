> Historical snapshot before the 2026-10-24 consolidation. Current contracts are in [README](../../README.md); instructions and status here are superseded.

# Inkribe iOS v1.0 — scoped plan

## Current work — issue #38 production passes 1–5 (2026-10-24)

The user authorized pass 5 in existing [PR #39](https://github.com/hoangbkit/Inkribe/pull/39)
(`feat/ios-project-packages` → develop), retaining passes 1–4. All five source passes
are integrated: packages, processing, home/native flow, scrolling editor and now
versioned caption values/catalog, ten curated looks, renderer/layout/motion extensions,
independent resets, compatibility/access and production metadata source review.
Read [phase](../../phases/CAPTION_PRODUCTION.md), [handoff](../../handoffs/CAPTION_PRODUCTION.md)
and [readiness record](../../PRODUCTION_READINESS.md). Canonical schema 8 reads 1–7;
existing queue/checkpoint/request wrappers and working transcription are retained.
Shared style/catalog/motion values are consumed by iOS without changing Mac APIs.

Source/call-site/diff/whitespace and publication review only. Shared regression
specifications are authored, unexecuted. No builds/typechecks/tests/fixtures, CI,
generation, model downloads, native inference/exports, UI/device/accessibility or
deployment. Production verification and owner inputs remain pending, including the
placeholder privacy URL, live commerce, licensed footage/device/preview-export
acceptance and archive privacy report. Leave PR open without auto-merge. Earlier
pass-specific holds below are historical; source integration is not release readiness.

The user explicitly requested implementation of the visualized editor in PR #37 (fix/ios-window-recovery → develop), based on 525fae4. Accepted windows now publish usable captions incrementally; the visible transcript edits whole captions, footage previews real text, and inline gaps retry without replacing edits. Partial MP4/SRT export is allowed with a notice; only complete nonempty recognition charges. Schema v7 reads v1–v6 and records coverage/mapping versions; the version-1 sidecar remains for inference recovery. This supersedes the earlier complete-only policy and panel hierarchy. PR stays open without auto-merge. Source/diff/whitespace review only: no builds/typechecks/tests, CI/workflow triggers, generation, weights, inference or UI/device validation. See [phase](../../phases/TRANSCRIPTION_RECOVERY.md) and [handoff](../../handoffs/TRANSCRIPTION_RECOVERY.md).

The earlier status paragraphs below are historical and superseded by this request.

> Current request (2026-10-23): #35 is squash merged as 525fae4. Implement issue #36 in one new fix/ios-window-recovery PR targeting develop, left open without auto-merge. Scope and publication/checkpoint policy: [phases/TRANSCRIPTION_RECOVERY.md](../../phases/TRANSCRIPTION_RECOVERY.md). Source evidence and user checks: [handoffs/TRANSCRIPTION_RECOVERY.md](../../handoffs/TRANSCRIPTION_RECOVERY.md). No new phase/features or Mac changes; no builds/typechecks/tests, CI, generation, weights or UI/device validation. Older #35 holds below are historical.

> Current repair (2026-10-23): all four requested passes are source-implemented in open PR #35 targeting develop; no auto-merge. Read [handoffs/TRANSCRIPTION_WORKSPACE.md](../../handoffs/TRANSCRIPTION_WORKSPACE.md) and [HANDOFF.md](../../HANDOFF.md) for current behavior and user validation. Builds/runtime/device checks are unrun. Earlier phase/Pro branch holds below are historical; no next phase or merge is authorized.

> Current amendment (2026-10-22): PR #30 is squash merged as eb89f0f. The user has now authorized Pro locking and AF themes; [phases/PRO.md](../../phases/PRO.md) and [handoffs/PRO.md](../../handoffs/PRO.md) supersede historical Pro deferral, 28/29 accounting and PR #30 review holds below. The new phase stays open on feat/ios-pro-access-themes → develop. All 29 V1 items are source-integrated; compilation/runtime/user validation is unrun.

Updated 2026-10-22 following the user's compact v1 feature list. This supersedes the old 467-item catalog and P0–P13 roadmap. Only current FEATURES and active P0–P7 briefs define deliverables when the user requests a phase. Archived documents, reference images, Mac capabilities and existing extra source do not authorize features.

## Product

Focused native workflow: Photos/Files import → on-device recognition → caption correction → styles/animations → MP4/SRT export. Local projects include thumbnails, rename/duplicate/delete, autosave, offline reopening and cleanup. Basic media tools are trim, crop/aspect ratio and original-audio volume. Simple Pro uses AppFoundation paywall/restore. Safe originals, recovery, accessible controls and clear errors apply throughout.

## Eight phases

| Phase | Result | Difficulty | Value | Status |
|---|---|---|---|---|
| [P0](../../phases/P0.md) | Target isolation and foundations | High | Essential | Merged #23; source-only evidence |
| [P1](../../phases/P1.md) | Local projects and import | Medium | Essential | Merged #24; reported source findings corrected, runtime unverified |
| [P2](../../phases/P2.md) | On-device transcription and word timing | High | Essential | Merged #25 (97d647e); model/native/runtime checks unrun |
| [P3](../../phases/P3.md) | Caption correction and simple timeline | High | Essential | Merged #26 (11902e6); compilation/runtime unverified |
| [P4](../../phases/P4.md) | Caption styles and curated animations | High | High | Merged #27 (ab67747); compilation/render/runtime unverified |
| [P5](../../phases/P5.md) | MP4/SRT export and simple Pro | High | Essential | Merged #28 (3c09e32); Pro deferred by user; compilation/runtime unverified |
| [P6](../../phases/P6.md) | Basic media editing | Medium–High | High | Merged #29 (e2bb512); compilation/runtime unverified |
| [P7](../../phases/P7.md) | V1 hardening and release handoff | Medium–High | Essential | Source audit/fixes/handoff in open #30; compilation/runtime/user validation unrun |

P0–P6 keep their broad historical roles with reduced scope. P7 now means v1 hardening, replacing its unstarted AI/localization role. P8–P13 are retired. Reliability applies throughout, not only in P7.

## Outside v1

No accounts/backend, cloud transcription/AI/sync/backup, teams/collaboration/review links, social publishing/scheduling/analytics, AI credits/allowances, stock/music services, AI B-roll, eye-contact correction, dubbing/voice cloning/AI voiceovers, incoming share extension/App Group/inbox, camera/teleprompter, translation/bilingual workflows, automation API/Shortcuts/watch folders, or Mac feature expansion.

Also outside v1: advanced video effects/transitions/speed/reverse/tracking/masking, multi-track production, waveform/music editing, custom font importer, brand kits/template marketplace, 4K/MOV/alpha/chroma/soft-subtitle outputs, export batch pipelines, specialized caption-mode catalog, advanced project history, iPad-specific workspace and external-display tools. Unicode-safe text and accessible controls still apply.

## Existing extras and status

Planning #22 and P0 #23 are merged. P1 PR #24 was squash merged as 97d3645; its former review hold is historical. P2 PR #25 was squash merged as 97d647e. P3 PR #26 was squash merged as 11902e6. P4 #27 was squash merged as ab67747. P5 #28 was squash merged as 3c09e32. P6 #29 was squash merged as e2bb512. The subsequent explicitly requested optional-model change stays open for review; no merge/auto-merge. The title-autosave race and post-download-only URL size check were corrected in source on 2026-10-22. Saves drain the latest draft with returned revisions; downloads enforce the existing 16 GiB cap on declared and actual streamed bytes. Runtime checks remain unrun.

URL import, combined/batch imports and advanced canvas controls already present in P1 source are not v1 requirements. The scope-reset documentation removed no source/UI. A subsequent explicit user request authorized the two correctness fixes, including hardening the existing URL path; it did not add URL import to v1 requirements. Record them separately; obtain an actual fix/removal decision before changing them. Transcript search is no longer a P2 obligation. Incoming share extension was removed and must not return.

## Execution and decisions

One PR per requested phase from latest develop, all passes in it. State included V1 IDs and a short plan first; do not start another phase automatically or expand scope. Follow WORKFLOW and relevant UI approval. Preserve Mac data/identity/purchases/behavior.

P2 model packaging is now governed by MODELS. The subsequent user-approved [Pro phase](../../phases/PRO.md) implements free 5-minute weekly captioning/basic style/720p/default AF theme versus unlimited captioning/all styles/1080p/premium AF themes. Monthly $6.99 and lifetime $24.99 use the approved IDs in Commerce. Core editing/media/SRT remain free. Existing saved content stays usable after expiry. No watermark/trial/credit backend. See handoffs/PRO for exact quota/recovery and production inputs.

No builds/tests unless asked, CI setup/repair/triggers, Xcode project generation, model downloads, deployment or device validation. User tests afterward. Source integration is not compilation/runtime verification; missing required behavior remains incomplete.

## Explicit model-flow amendment — after P6 merge

The user requested optional bundling plus in-app download/cache and variant selection to speed development. This amends V1.LOCAL_STT/JOB without adding a phase or cloud transcription. Support Tiny, Base and Small multilingual GGML models. Default project.yml packages no iOS weights; the opt-in project-ios-bundled.yml requires Small and disables downloads/cache fallback for a future production choice. No production policy is switched automatically by Release configuration. See MODELS.md. By subsequent user request P7 source hardening is included in PR #30; Pro remains deferred. The agent still must not download weights itself.
