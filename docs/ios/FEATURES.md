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
| V1.STYLE | P4 | Fonts, size, color, outline and background | Source-integrated in #27; compilation/render/runtime unverified |
| V1.POSITION | P4 | Caption position in output coordinates | Source-integrated in #27; compilation/render/runtime unverified |
| V1.PRESETS | P4 | Curated templates: highlighting, karaoke, pop and fade | Source-integrated in #27; compilation/render/runtime unverified |
| V1.MP4 | P5 | Captioned MP4 at 720p/1080p with source audio | Source-integrated; compilation/runtime unverified |
| V1.SRT | P5 | Edited captions exported as SRT | Source-integrated; compilation/runtime unverified |
| V1.DELIVERY | P5 | Save to Photos/Files and native export sharing | Source-integrated; permission/provider/runtime checks unrun |
| V1.EXPORT_JOB | P5 | Export progress/cancel and failure cleanup | Source-integrated; interruption/cleanup/runtime checks unrun |
| V1.PRO | P5 | Simple free/Pro, AppFoundation paywall and restore | Deferred by explicit user choice during P5; policy/prices undecided |
| V1.TRIM | P6 | Non-destructive trim with caption mapping | Source-integrated; compilation/timing/runtime unverified |
| V1.CROP | P6 | Crop/aspect ratio in preview and export | Source-integrated; orientation/pixel/runtime unverified |
| V1.VOLUME | P6 | Original-audio volume in preview and export | Source-integrated; mix/playback/runtime unverified |
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

## P4 source evidence

V1.STYLE/POSITION/PRESETS integrate project-wide editable style values, normalized output position, Modern/Bold/Serif/Mono built-in font choices and Spotlight/Karaoke/Pop/Soft Fade presets. Controls live below the stable footage preview. Choosing a template preserves output placement; style controls/presets/reset participate in the existing autosave and undo/redo sequence. Native text/timing/raw recognition/originals remain unchanged.

Schema v4 adds optional captionStyle; v1–v3 reads retain the default style without an eager rewrite. Duplicates preserve style values. A single Core Text renderer shapes/wraps text and draws base/outline/background, active-word highlight, progressive karaoke, word-triggered pop and word-envelope fade from project time. UIView preview, transparent bitmap and CI frame-composition adapters share this path. Unicode ranges use UTF-16 glyph-run mapping and explicit installed-font/system fallback. Layout is capped at 16,384 UTF-16 units and eight lines, with clear split/reduce-size errors, never silent truncation.

P4 did not implement P5 files/audio/jobs/commerce; subsequent export integration is recorded below. The shared bitmap/composition interfaces are implemented source, not an exported-file or pixel-parity result. No builds/typechecks/tests, CI, generation, model downloads or device validation. See handoffs/P4.md for exact interfaces and pending user scenarios.

## P5 source evidence

V1.MP4/SRT/DELIVERY/EXPORT_JOB are integrated in PR #28 on feat/ios-p5-export. A single JobQueue operation uses a frozen saved document/profile and pinned immutable media. Preview/export share source-range/orientation/track-offset composition; H.264 output uses an even-dimension 720p/1080p envelope at 30 fps, the exact P4 overlay at each output PTS, AAC source audio and black audio-only/gap frames. The finalized file is checked for size/duration/video codec/dimensions and expected AAC audio before atomic publication. SRT streams edited, visible cues as UTF-8 with stable ordering and outward millisecond rounding. No raw recognition or original media is rewritten.

Progress/cancel/retry, restart after interruption, partial cleanup, one retained artifact, delivery leases, add-only Photos permission, provider copies and native outbound sharing are integrated. Current export is accessible from Projects even if its source project is trashed. Storage includes retained export bytes; successful publication releases source pins, and explicit discard/new export cleans the retained job. No batch pipeline or export history added.

The user explicitly selected Defer Pro. V1.PRO remains deferred, not complete. No gates/plans/prices/watermarks/trials were invented. Schema remains v4. Source review only; no builds/typechecks/tests, CI, generation, models, deployment or device validation. See handoffs/P5.md for APIs, caveats and user scenarios.

## P6 source evidence

V1.TRIM/CROP/VOLUME are integrated in PR #29 on feat/ios-p6-media-editing. Schema v5 adds optional project-wide mediaEdits: original-project trim range, fit/fill, bounded zoom and normalized pan, volume 0–1. Missing edits preserve v1–v4 behavior without eager writes. Aspect changes use existing canvas/preset fields. Commands are atomic, undoable and use the existing serialized latest-draft save drain; duplicates preserve media values. No original clips/raw recognition/native or manual timing is rewritten by media commands.

One rational retained-range map intersects clips/cues/words and subtracts trim start for zero-based preview/MP4/SRT. Fully outside timed units are omitted from output only; boundary units retain their text with clipped output intervals. Effects retain the original edited-word phase, and original cue priority survives clipped-start ties. Reset/undo restores omitted output content. Caption correction timing fields explicitly remain original project seconds, while transport/list/export are output seconds. Library duration follows the retained range.

The shared AV composition maps retained source/track intersections, preferred orientation, crop transforms/source crop rectangles and project-aspect placement. Preview overlays fit the same rounded raster viewport. One audio-mix factory serves preview and export; volume-only edits replace the mix without a player rebuild. Other media changes pause and use a debounced generation-guarded rebuild preserving the source playhead. Empty retained gaps use a tiny held black clock frame; MP4 stays intentionally black/silent rather than requiring nonexistent source samples.

P5 frozen exports now include schema-v5 media settings, pin only referenced retained assets, and validate retained duration. Existing version-1 export manifests remain readable; prior frozen exports never adopt later edits. Pro remains deferred. No builds/typechecks/tests, CI, generation, model downloads, runtime exports or device validation. See handoffs/P6.md for boundaries and pending user scenarios.
