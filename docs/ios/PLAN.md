# Inkribe iOS v1.0 — scoped plan

Updated 2026-10-22 following the user's compact v1 feature list. This supersedes the old 467-item catalog and P0–P13 roadmap. Only current FEATURES and active P0–P7 briefs define deliverables when the user requests a phase. Archived documents, reference images, Mac capabilities and existing extra source do not authorize features.

## Product

Focused native workflow: Photos/Files import → on-device recognition → caption correction → styles/animations → MP4/SRT export. Local projects include thumbnails, rename/duplicate/delete, autosave, offline reopening and cleanup. Basic media tools are trim, crop/aspect ratio and original-audio volume. Simple Pro uses AppFoundation paywall/restore. Safe originals, recovery, accessible controls and clear errors apply throughout.

## Eight phases

| Phase | Result | Difficulty | Value | Status |
|---|---|---|---|---|
| [P0](phases/P0.md) | Target isolation and foundations | High | Essential | Merged #23; source-only evidence |
| [P1](phases/P1.md) | Local projects and import | Medium | Essential | Merged #24; reported source findings corrected, runtime unverified |
| [P2](phases/P2.md) | On-device transcription and word timing | High | Essential | Merged #25 (97d647e); model/native/runtime checks unrun |
| [P3](phases/P3.md) | Caption correction and simple timeline | High | Essential | Merged #26 (11902e6); compilation/runtime unverified |
| [P4](phases/P4.md) | Caption styles and curated animations | High | High | Source-integrated in open #27; compilation/render/runtime unverified |
| [P5](phases/P5.md) | MP4/SRT export and simple Pro | High | Essential | Not started; depends on P4 |
| [P6](phases/P6.md) | Basic media editing | Medium–High | High | Not started; depends on P5 |
| [P7](phases/P7.md) | V1 hardening and release handoff | Medium–High | Essential | Not started; final audit after P0–P6 |

P0–P6 keep their broad historical roles with reduced scope. P7 now means v1 hardening, replacing its unstarted AI/localization role. P8–P13 are retired. Reliability applies throughout, not only in P7.

## Outside v1

No accounts/backend, cloud transcription/AI/sync/backup, teams/collaboration/review links, social publishing/scheduling/analytics, AI credits/allowances, stock/music services, AI B-roll, eye-contact correction, dubbing/voice cloning/AI voiceovers, incoming share extension/App Group/inbox, camera/teleprompter, translation/bilingual workflows, automation API/Shortcuts/watch folders, or Mac feature expansion.

Also outside v1: advanced video effects/transitions/speed/reverse/tracking/masking, multi-track production, waveform/music editing, custom font importer, brand kits/template marketplace, 4K/MOV/alpha/chroma/soft-subtitle outputs, export batch pipelines, specialized caption-mode catalog, advanced project history, iPad-specific workspace and external-display tools. Unicode-safe text and accessible controls still apply.

## Existing extras and status

Planning #22 and P0 #23 are merged. P1 PR #24 was squash merged as 97d3645; its former review hold is historical. P2 PR #25 was squash merged as 97d647e. P3 PR #26 was squash merged as 11902e6. P4 stays open for review; no merge/auto-merge. The title-autosave race and post-download-only URL size check were corrected in source on 2026-10-22. Saves drain the latest draft with returned revisions; downloads enforce the existing 16 GiB cap on declared and actual streamed bytes. Runtime checks remain unrun.

URL import, combined/batch imports and advanced canvas controls already present in P1 source are not v1 requirements. The scope-reset documentation removed no source/UI. A subsequent explicit user request authorized the two correctness fixes, including hardening the existing URL path; it did not add URL import to v1 requirements. Record them separately; obtain an actual fix/removal decision before changing them. Transcript search is no longer a P2 obligation. Incoming share extension was removed and must not return.

## Execution and decisions

One PR per requested phase from latest develop, all passes in it. State included V1 IDs and a short plan first; do not start another phase automatically or expand scope. Follow WORKFLOW and relevant UI approval. Preserve Mac data/identity/purchases/behavior.

P2 must resolve compatible local model/packaging and genuine word timing. P3 implements compact preview/transport, a scrubber/cue overview and correction list; P4 the curated fonts/templates. P5 needs actual free/Pro limits, plans/IDs and prices. Do not invent commercial policy or infrastructure.

No builds/tests unless asked, CI setup/repair/triggers, Xcode project generation, model downloads, deployment or device validation. User tests afterward. Source integration is not compilation/runtime verification; missing required behavior remains incomplete.
