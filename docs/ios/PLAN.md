# Inkribe iOS — current plan

2026-10-24. All five issue #38 source milestones are integrated in open PR #39 →
develop. Consolidation fixes integration seams in that PR; it does not start a new
feature phase. [FEATURES](FEATURES.md) retains the 29 approved V1 acceptance items.

| Milestone | Integrated source result | Detail |
|---|---|---|
| 1. Project system | Wrapper-1 UUID packages, legacy adoption, safe paths/revisions, lifecycle/storage and recovery | [Phase](phases/PROJECT_SYSTEM.md) |
| 2. Processing/delivery | Existing JobQueue stores/names behind one resource budget; independent frozen requests/results and per-output delivery | [Phase](phases/PROCESSING_DELIVERY.md) |
| 3. Home/native flow | Scrolling creation hero, compact projects/activity/search, native Back/chrome and app-owned editing and automatic saving | [Phase](phases/HOME_NATIVE_FLOW.md) |
| 4. Editor | One scrolling preview/transport/tools/workspace, direct corrections and preview-backed customization | [Phase](phases/EDITOR_EXPERIENCE.md) |
| 5. Caption quality/finish | Versioned resolved values/catalog, ten looks, shared layout/motion and native renderer extensions, compatibility and readiness record | [Phase](phases/CAPTION_PRODUCTION.md) |
| Consolidation | Strict new-style decoding, modal player-layer handoff, current render-error reporting and unified documentation | [Findings](CONSOLIDATION.md) |

The latest user-directed simplification removes editor-sidecar dependencies and
draft/recovery UI. Ordinary edits save directly to the project. See
[the current follow-up](CONSOLIDATION.md#follow-up-simple-project-saving).

## Retained product contracts

Photos/Files/direct-media URL import → optional on-device Tiny/Base/Small
recognition → incremental available captions and explicit missing-range retry →
correction/timing/split/merge/undo → project-wide style/media edits → independent
MP4/SRT exports and Photos/Files/Share delivery. Storage actions protect originals,
unsaved edits in memory and frozen job inputs. No implicit re-inference or caption regrouping.

Free: five captioning minutes/week, basic style, 720p and the default AF app theme.
Pro: unlimited captioning, all styles/animations, 1080p and premium app themes.
Monthly/lifetime products remain $6.99/$24.99 in simulation; live records need owner
verification. Core editing/media/SRT stay free; retained premium work survives expiry.
No watermark, trial, credits, backend quota or new product is introduced.

Default model packaging retains the existing optional bundle/download/cache flow;
the opt-in bundled-only spec remains explicit. Release configuration alone does not
choose a model lane. iOS is iPhone-only; current Mac identity/data/APIs are preserved.

## Outside scope

No accounts/cloud inference/sync, teams/social publishing, stock library, dubbing,
translation, camera, share extension/App Group/inbox, iPad workspace, per-caption
style overrides, advanced multitrack/history or Mac feature expansion. Existing
extras do not authorize new work. Historical P0–P7 delivery records remain in
[the archive](archive/before-consolidation/PLAN.md) and phase handoffs.

## Next gate

User-authorized compilation/regression/device/output/commerce acceptance and owner
release inputs, listed in [PRODUCTION_READINESS](PRODUCTION_READINESS.md). None ran
under this request. Keep PR open without auto-merge; do not start another phase.
