# Inkribe iOS — current feature ledger

2026-10-24. The original 29 V1 acceptance items below retain their delivery owners.
Expanded Pass 1 (#41, parent #40) adds the project experience tracked separately here.
All implementation status means source integration only; compilation/runtime acceptance
is pending. Base develop 4a9780f includes merged #39.

| ID | Owner | Requirement | Status |
|---|---|---|---|
| V1.PROJECTS | P1 | Thumbnail library and offline reopening | Source-integrated; execution/acceptance unverified |
| V1.RENAME | P1 | Rename and durable autosave | Source-integrated; execution/acceptance unverified |
| V1.DUPLICATE_DELETE | P1 | Safe project duplicate/delete | Source-integrated; execution/acceptance unverified |
| V1.IMPORT | P1 | Photos/Files video and audio import | Source-integrated; execution/acceptance unverified |
| V1.STORAGE | P1 | Storage cleanup and safe originals | Source-integrated; execution/acceptance unverified |
| V1.LOCAL_STT | P2 | On-device recognition, language/model selection and optional download/cache | Source-integrated; execution/acceptance unverified |
| V1.WORDS | P2 | Genuine model word/phrase intervals and stable identities | Source-integrated; execution/acceptance unverified |
| V1.JOB | P2 | Progress, cancel, retry and useful errors | Source-integrated; execution/acceptance unverified |
| V1.RESULT | P2 | Durable raw recognition and editable captions | Source-integrated; execution/acceptance unverified |
| V1.TEXT | P3 | Caption text correction | Source-integrated; execution/acceptance unverified |
| V1.TIMING | P3 | Cue/word timing and simple timeline | Source-integrated; execution/acceptance unverified |
| V1.SPLIT_MERGE | P3 | Split/merge captions | Source-integrated; execution/acceptance unverified |
| V1.UNDO | P3 | Undo/redo caption edits | Source-integrated; execution/acceptance unverified |
| V1.PREVIEW | P3 | Synchronized footage/caption/selection/playback | Source-integrated; execution/acceptance unverified |
| V1.STYLE | P4 | Versioned resolved typography, colors, outline, shadow, background and line layout | Source-integrated; execution/acceptance unverified |
| V1.POSITION | P4 | Caption position in output coordinates | Source-integrated; execution/acceptance unverified |
| V1.PRESETS | P4 | Ten versioned project-wide looks and deterministic timing-aware motion | Source-integrated; execution/acceptance unverified |
| V1.MP4 | P5 | Captioned MP4 at 720p/1080p with source audio | Source-integrated; execution/acceptance unverified |
| V1.SRT | P5 | Edited captions exported as SRT | Source-integrated; execution/acceptance unverified |
| V1.DELIVERY | P5 | Save to Photos/Files and native export sharing | Source-integrated; execution/acceptance unverified |
| V1.EXPORT_JOB | P5 | Export progress/cancel and failure cleanup | Source-integrated; execution/acceptance unverified |
| V1.PRO | P5 | Simple free/Pro, AppFoundation paywall and restore | Source-integrated; execution/acceptance unverified |
| V1.TRIM | P6 | Non-destructive trim with caption mapping | Source-integrated; execution/acceptance unverified |
| V1.CROP | P6 | Crop/aspect ratio in preview and export | Source-integrated; execution/acceptance unverified |
| V1.VOLUME | P6 | Original-audio volume in preview and export | Source-integrated; execution/acceptance unverified |
| V1.RECOVERY | P7 | Atomic project saving and durable job interruption handling | Source-integrated; execution/acceptance unverified |
| V1.BOUNDS | P7 | Bounded processing, stale-result protection and cleanup | Source-integrated; execution/acceptance unverified |
| V1.ACCESS | P7 | Accessible controls and clear loading/error/empty states | Source-integrated; execution/acceptance unverified |
| V1.HANDOFF | P7 | End-to-end source audit and user-testing handoff | Source-integrated; execution/acceptance unverified |

## Expanded Pass 1 (#41)

| ID | Requirement | Status |
|---|---|---|
| PROJECT.ONE_CREATION | One project, one/multiple ordered files, visual review and retry | Source-integrated; unverified execution |
| PROJECT.DETAILS | Combined overview, ordered clips, defaults and retained exports | Source-integrated; unverified execution |
| PROJECT.CLIP_EDITOR | Continuous clock, clip navigation and grouped captions | Source-integrated; unverified execution |
| PROJECT.CLIP_SETTINGS | Per-setting overrides/reset, history and effective output | Source-integrated; unverified execution |
| PROJECT.EXPORTS | Queued/in-place generation, actual-file preview/save/share | Source-integrated; unverified execution |
| PROJECT.SAVING | Shared atomic writer across details/editor/export routes | Source-integrated; unverified execution |

Details and pending acceptance: [PROJECT_EXPERIENCE](handoffs/PROJECT_EXPERIENCE.md).

## Current implementation evidence

| Area | Contracts and source evidence |
|---|---|
| Projects/import/storage | [Project system](phases/PROJECT_SYSTEM.md), [home/native flow](phases/HOME_NATIVE_FLOW.md); UUID packages, original-safe import/lifecycle, cached library and automatic project saving |
| Transcription/jobs/delivery | [Recovery](phases/TRANSCRIPTION_RECOVERY.md), [processing](phases/PROCESSING_DELIVERY.md); accepted partial captions, gap retry, native intervals/IDs, quota and independent frozen outputs |
| Editing/styles | [Editor](phases/EDITOR_EXPERIENCE.md), [caption production](phases/CAPTION_PRODUCTION.md); one scrolling workspace, direct correction/history, resolved versioned looks and shared renderer |
| Integration fixes | [Consolidation](CONSOLIDATION.md); strict version-2 decoding, covered player-layer handoff, current error reporting and documentation cleanup |
| Acceptance/release | [Readiness](PRODUCTION_READINESS.md); all native/build/device/commerce/output evidence remains pending |

The original Fxx catalog and delivery history are historical; no new feature is
implied. Search/sort/filter, direct URLs and combined imports remain existing
supported behavior; transcript search and incoming share extension are not required.
No invented word timing, implicit regrouping or inference on style choices.
Previous source records are preserved in [the archive](archive/before-consolidation/FEATURES.md).
