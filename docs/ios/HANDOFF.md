# Inkribe iOS — current handoff

2026-10-24. PR #39 is open on `feat/ios-project-packages` → develop, auto-merge off.
All five implementation passes are source-integrated, followed by consolidation.
The latest exact source head is in the PR. No production-ready claim is made.

The latest user-directed change is simple project saving. Ordinary edits now save
directly to the project through one serialized writer and atomic repository save.
The app no longer reads/writes editor-draft.json, checks it before opening/renaming,
or presents recovery/discard/reload management. Existing sidecars are left untouched.
Unsaved changes and undo stay in the app-owned session across navigation, with one
friendly failure and Try again. They are not guaranteed after process termination
before a successful save. Transcription checkpoints/jobs/frozen exports stay durable.

Rename remains explicit in editor actions and Home. Pending changes, unavailable
media or an active speech job route Home Rename through the same editor title field
instead of disabling the action. Leaving Project details never waits for storage.
See [the current follow-up](CONSOLIDATION.md#follow-up-simple-project-saving).

| Source milestone | Commit | Detailed handoff |
|---|---|---|
| Project packages | a035dd3 | [PROJECT_SYSTEM](handoffs/PROJECT_SYSTEM.md) |
| Processing/delivery | f598376 | [PROCESSING_DELIVERY](handoffs/PROCESSING_DELIVERY.md) |
| Home/native flow | b040816 | [HOME_NATIVE_FLOW](handoffs/HOME_NATIVE_FLOW.md) |
| Scrolling editor | 31763bb | [EDITOR_EXPERIENCE](handoffs/EDITOR_EXPERIENCE.md) |
| Caption quality | cb594c3 | [CAPTION_PRODUCTION](handoffs/CAPTION_PRODUCTION.md) |
| Consolidation | See PR head | [CONSOLIDATION](CONSOLIDATION.md) |

## Current contracts

- Canonical schema 8 reads 1–7; package/processing-control/export-request
  wrappers and JobQueue names/IDs/files remain stable. Old apps reject schema 8.
  Use a pre-upgrade stopped-app container backup for rollback.
- Working local transcription, accepted partial captions, native word/phrase
  intervals/IDs, corrected text, gap retry, undo and allowance remain protected.
  Style/visual wrapping never rewrites grouping/timing or starts inference.
- One app-owned session/writer per project; direct atomic saves retain revision
  and append-only speech rebase checks. Failed changes stay in memory across
  navigation. Home only shows a save warning for an actual failed write.
- Ten versioned looks render from saved resolved values. Legacy defaults/motion
  stay frozen. Unknown preset ancestry preserves values; unsupported future style
  formats do not trigger older-document fallback. Version-2 resolved fields are
  required; legacy omissions retain their original defaults.
- One main scrolling editor. Modal style/export/queue routes relinquish the
  covered native player layer; render errors report only current surfaces/draws.
  Native gesture/focus/layout/output behavior still needs device evidence.
- Jobs own independent frozen requests/results with explicit retention/recovery
  and per-output delivery leases. No automatic unsaved-result eviction.

## Validation and next steps

Source/call-site/diff/whitespace and publication consistency review only. Twelve
shared caption regression specifications are authored, unrun, plus prior shared
package/processing/recovery specifications. Two additional direct-save specifications
are authored but unrun; source review is not behavioral validation. No builds/typechecks/tests/fixtures,
CI/generation/models/native inference/exports/UI/device/accessibility/deployment ran.

[PRODUCTION_READINESS](PRODUCTION_READINESS.md) is the release gate/owner-input
record. Actual privacy URL, live commerce/signing/model lane, licensed controlled
footage, compilation, SE2/larger-iPhone behavior, upgrade/recovery/queue acceptance
and preview/MP4/SRT parity remain pending. Execute only after user authorization;
record exact commit/input/device/output evidence. Keep the PR and issue open.

Historical status and CI reports are preserved in
[the archive](archive/before-consolidation/HANDOFF.md). Their earlier open-PR,
schema, tool-layout or Pro-deferral statements do not override these contracts.
