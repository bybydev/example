# Inkribe iOS v1.0 feature ledger

**29 acceptance items**, grouped from the user-approved compact list. This replaces the 466-active-item ledger. V1 IDs distinguish current requirements from historical Fxx entries. P0 owns foundations, no user feature items. Source status is not runtime verification.

| ID | Owner | Requirement | Status |
|---|---|---|---|
| V1.PROJECTS | P1 | Thumbnail library and offline reopening | Source-integrated; runtime unverified |
| V1.RENAME | P1 | Rename and durable autosave | Source-integrated; serialized latest-draft saves; runtime unverified |
| V1.DUPLICATE_DELETE | P1 | Safe project duplicate/delete | Source-integrated; runtime unverified |
| V1.IMPORT | P1 | Photos/Files video and audio import | Source-integrated; runtime unverified |
| V1.STORAGE | P1 | Storage cleanup and safe originals | Source-integrated; runtime unverified |
| V1.LOCAL_STT | P2 | On-device recognition and language selection | Source-integrated in #25; compilation/runtime unverified |
| V1.WORDS | P2 | Genuine word timestamps and stable identities | Source-integrated in #25; compilation/runtime unverified |
| V1.JOB | P2 | Progress, cancel, retry and useful errors | Source-integrated in #25; compilation/runtime unverified |
| V1.RESULT | P2 | Durable raw recognition and editable captions | Source-integrated in #25; compilation/runtime unverified |
| V1.TEXT | P3 | Caption text correction | Source-integrated in #26; compilation/runtime unverified |
| V1.TIMING | P3 | Cue/word timing and simple timeline | Source-integrated in #26; compilation/runtime unverified |
| V1.SPLIT_MERGE | P3 | Split/merge captions | Source-integrated in #26; compilation/runtime unverified |
| V1.UNDO | P3 | Undo/redo caption edits | Source-integrated in #26; compilation/runtime unverified |
| V1.PREVIEW | P3 | Synchronized footage/caption/selection/playback | Source-integrated in #26; compilation/runtime unverified |
| V1.STYLE | P4 | Fonts, size, color, outline and background | Not started |
| V1.POSITION | P4 | Caption position in output coordinates | Not started |
| V1.PRESETS | P4 | Curated templates: highlighting, karaoke, pop and fade | Not started |
| V1.MP4 | P5 | Captioned MP4 at 720p/1080p with source audio | Not started |
| V1.SRT | P5 | Edited captions exported as SRT | Not started |
| V1.DELIVERY | P5 | Save to Photos/Files and native export sharing | Not started |
| V1.EXPORT_JOB | P5 | Export progress/cancel and failure cleanup | Not started |
| V1.PRO | P5 | Simple free/Pro, AppFoundation paywall and restore | Not started; policy/prices undecided |
| V1.TRIM | P6 | Non-destructive trim with caption mapping | Not started |
| V1.CROP | P6 | Crop/aspect ratio in preview and export | Not started |
| V1.VOLUME | P6 | Original-audio volume in preview and export | Not started |
| V1.RECOVERY | P7 | Persistence and interruption/relaunch recovery | Continuous; final audit pending |
| V1.BOUNDS | P7 | Bounded processing, stale-result protection and cleanup | Continuous; final audit pending |
| V1.ACCESS | P7 | Accessible controls and clear loading/error/empty states | Continuous; final audit pending |
| V1.HANDOFF | P7 | End-to-end source audit and user-testing handoff | Not started |

## Accounting

PLAN defines exclusions. Legacy Fxx items and ISSUE_21.md are historical, not requirements. Old 18/19 P1 totals are superseded. V1.RENAME now serializes writes, keeps the latest draft and consumes returned revisions; no save-triggered reload replaces typing. Source review only. Existing search/sort/filter, URL and combined imports do not expand scope. Transcript search is not required. Incoming share extension remains removed; V1.DELIVERY is outbound native sharing.

Update each item only from actual integration; report source review, unrun checks and user validation separately. Do not require diarization, full forced alignment or cloud providers to complete this ledger. Never fabricate word timing. New features need an explicit user scope change.

## P2 source evidence — PR #25

Local Whisper Small Multilingual is bundled from the existing pinned asset. CPU execution uses <=4 threads. AVFoundation reads <=28-second windows around 24-second ownership cores; PCM is never accumulated across windows. Raw UTF-8 tokens are joined before NLTokenizer word segmentation; word intervals aggregate actual native token intervals, with midpoint core ownership and conservative acoustic-overlap reconciliation. Token timing is approximate, not forced alignment; unavailable timing fails without fake output.

JobQueue 1.0.0 owns durable one-at-a-time execution, progress/cancel/retry and interrupted-job restoration. Schema-v2 projects atomically store raw windows, words/cues and job identity; v1 remains readable, older clients reject v2. Completion is idempotent and strict revisions protect edits. Duplicates remap recognition/clip/word/cue identities. P2 UI is language/start/status and read-only results, not P3 editing.

No build/test/native inference/device evidence. Model weights were not downloaded; place the existing pinned file before user builds. See handoffs/P2.md for exact path/hash and pending checks. All four P2 items are source-integrated, not verified runtime-complete.

## P3 source evidence

V1.TEXT/TIMING/SPLIT_MERGE/UNDO/PREVIEW are integrated in the iOS editor. Text correction works per timed unit, including a corrected phrase; clearing hides text while retaining word identity/timing. No new sub-word timing is invented. Timing fields use project seconds, preserve native source intervals, and explicitly record manual source intervals. Caption timing scales its word intervals as a user correction. Word timing expands its cue when necessary. Split at an existing word boundary; merge the next same-clip caption. Undo/redo keeps up to 50 commands for the open session and coalesces consecutive typing in one field; history itself is not persisted.

One session serializes title and caption autosaves, preserves newer drafts across writes, reports conflicts without blind rebase and provides explicit saved-state reload. One stable AVPlayer composition maps clip source ranges, track offsets and orientation into project time. A pure immutable edited snapshot drives preview/list/timeline evaluation; selection seeks, playback highlights the active cue without taking editing focus. New media items are prepared only when media inputs change or preview is retried. No style/export, advanced timeline or extra services added. See handoffs/P3.md; no builds/tests/UI/device verification performed.
