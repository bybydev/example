# Inkribe iOS — current feature ledger

## Queue experience — final pass 4 (2026-11-01)

| ID | Requirement | Source status |
|---|---|---|
| JOB.ACTIONS / JOB.CONCURRENCY | Single queued Transcribe/Create Export and JobQueue 1/3 limits/current/legacy jobs | Source-integrated and reviewed |
| JOB.QUEUE_UI / JOB.PROJECT_ROUTE / JOB.RETAINED_EXPORTS | Settled queue design, exact project/export routes, retained-file fallback and delivery | Source-integrated and reviewed |
| JOB.BACKGROUND / JOB.BACKGROUND_RECOVERY / JOB.BACKGROUND_RESOURCES | Explicit system leases, kind/resource isolation, pause/recovery and GPU fallback | Source-integrated and reviewed |
| JOB.INTEGRATION | Stable scene owner, real-background recovery, settled/cancellable focus, stale-project fallback and source ownership cleanup | Source-reviewed; scoped fixes integrated |

All four source passes are complete. See [handoff](handoffs/QUEUE_EXPERIENCE.md).
Source-only; compilation/native/UI/signing acceptance remains unverified.

## Queue experience — pass 3 (2026-11-01)

| ID | Requirement | Source status |
|---|---|---|
| JOB.BACKGROUND | Explicit work/Resume requests; actual handler grants; independent speech/export leases and system progress | Source-integrated |
| JOB.BACKGROUND_RECOVERY | Expiration cancels/pauses affected kind; captured native teardown before completion; foreground recovery without resubmission | Source-integrated |
| JOB.BACKGROUND_RESOURCES | CPU speech/SRT-only export; GPU-supported MP4; foreground-only export fallback; source metadata/entitlement | Source-integrated |
| JOB.ACTIONS / JOB.CONCURRENCY / JOB.QUEUE_UI / JOB.PROJECT_ROUTE | Passes 1–2 | Preserved |
| JOB.INTEGRATION | Final scoped source review | Await pass 4 |

See [handoff](handoffs/QUEUE_EXPERIENCE.md).
No generation/build/native/UI execution; runtime acceptance remains unverified.

## Queue experience — pass 2 (2026-11-01)

| ID | Requirement | Source status |
|---|---|---|
| JOB.QUEUE_UI | Spokio-style plain list, outlined status pills/counts, compact status/progress/chevron rows, toolbar filters/sort, swipe/context actions | Source-integrated |
| JOB.PROJECT_ROUTE | Rows open project Captions or exact Export activity/file; owner-dismissed handoff and same-editor reuse | Source-integrated |
| JOB.RETAINED_EXPORTS | Dedicated retained requests/files, live details/recovery/delivery and unavailable-project fallback | Source-integrated |
| JOB.ACTIONS / JOB.CONCURRENCY | Single queued actions and JobQueue 1/3 limits from pass 1 | Preserved |
| JOB.BACKGROUND / JOB.INTEGRATION | Continued processing / final source integration review | Await passes 3 / 4 |

See [handoff](handoffs/QUEUE_EXPERIENCE.md).
Source-only; compilation/native/UI acceptance remains unverified.

## Queue experience — pass 1 (2026-11-01)

| ID | Requirement | Source status |
|---|---|---|
| JOB.ACTIONS | One Transcribe/Create Export path, always queued; project activity persists across sheet reopening | Source-integrated |
| JOB.CONCURRENCY | JobQueue capacity: transcription 1, exports 3; current/legacy types; no global iOS permit | Source-integrated |
| JOB.QUEUE_UI / JOB.PROJECT_ROUTE | Spokio iOS reference and project Captions/specific-export navigation | Deferred to pass 2 |
| JOB.BACKGROUND | User-initiated continued processing, progress/expiration and GPU-aware export fallback | Deferred to pass 3 |
| JOB.INTEGRATION | Final source review of retry/cancellation/recovery/navigation | Deferred to pass 4 |

See [handoff](handoffs/QUEUE_EXPERIENCE.md).
Source integration only; compilation/runtime acceptance remains unverified.

## Timeline clip trimming (2026-10-31, stacked on #55)

| ID | Requirement | Source status |
|---|---|---|
| EDITOR.CLIP_TRIM_HANDLES | Selected timeline clip start/end drag, bounds, restore and accessibility actions | Source-integrated |
| EDITOR.CLIP_TRIM_PREVIEW | Bounded serial boundary-frame audition in existing main preview; no new player | Source-integrated |
| EDITOR.CLIP_TRIM_OUTPUT | Shared piecewise map closes excluded time across video, audio, captions, SRT and seeks | Source-integrated |
| EDITOR.CLIP_TRIM_TRANSACTION | Save once on release, expected-state check, atomic adoption, bounded Undo/Redo | Source-integrated |
| EDITOR.CLIP_TRIM_COMPATIBILITY | Preserve old project windows/hidden clips; schema 13 reads 1–12; frozen exports stay captured | Source-integrated |

See [handoff](handoffs/CLIP_TRIMMING.md).
Media trim fields/reset are removed. Compilation/native/UI acceptance is unverified.

## Media Form — passes 1–2 (2026-10-31)

| ID | Requirement | Source status |
|---|---|---|
| EDITOR.MEDIA_FORM | Native themed Form without preview/transport | Source-integrated |
| EDITOR.MEDIA_SCOPE | Top Project/Clip menu changes every following section | Source-integrated |
| EDITOR.MEDIA_TRANSACTION | Cancel/swipe discards; Done saves one settings Undo entry | Source-integrated |
| EDITOR.CLIP_MEDIA_VALUES | Independent clip framing/volume; standard resets; legacy effective values preserved | Source-integrated |
| EDITOR.MEDIA_INTEGRATION | Closed-sheet cancellation, preview-independent saving/recovery, one rewrite/sort and speech reconciliation; source lifecycle/history/output review | Source-reviewed and scoped fixes integrated |

See [handoff](handoffs/MEDIA_FORM.md).
Both source passes are complete; compilation/native/UI acceptance is unverified.

## Music layer — passes 1–3 (2026-10-31)

| ID | Requirement | Source status |
|---|---|---|
| MUSIC.FOUNDATION | One owned audio file, source selection/output offset, loop/mix/fades, durable edits/history | Source-integrated; runtime unverified |
| MUSIC.OUTPUT | Shared preview/MP4 composition; frozen media pins; duration remains clip-defined | Source-integrated; runtime unverified |
| MUSIC.OWNERSHIP | Reopen/duplicate/Trash/storage/integrity/relink; schema 12 reads 1–11 | Source-integrated; runtime unverified |
| MUSIC.ORIGINAL_MUTE | Independent original-clip master mute preserves per-clip levels and music | Source-integrated with pass-2 leading control; runtime unverified |
| MUSIC.TIMELINE | Video/Music/Captions, leading buttons, empty Add music, real bounded waveform/loop | Source-integrated in pass 2; runtime unverified |
| MUSIC.SHEET | Controls only; staged Files/replace/settings save once on Done, Cancel/swipe discards; no preview/transport | Source-integrated in pass 2; runtime unverified |
| MUSIC.INTEGRATION | Sheet lifetime/late completion, rational loop/fade bounds, stable sliders, effective mute, import suitability; source ownership/duration/output review | Source-reviewed and fixes integrated in pass 3; runtime unverified |

See [handoff](handoffs/MUSIC_LAYER.md). No other
editor design changes are authorized. Source-only restrictions remain.

## Native fullscreen playback (2026-10-29, stacked on #52)

| ID | Requirement | Source status |
|---|---|---|
| EDITOR.NATIVE_FULLSCREEN | Native fullscreen for both expand entries; current player/live captions, paused same-position return | Source-integrated; runtime unverified |
| EXPORT.NATIVE_PREVIEW | Native fullscreen for all completed-MP4 preview routes; preserve delivery protection | Source-integrated; runtime unverified |

See [handoff](handoffs/NATIVE_FULLSCREEN.md).

## Style form revision (2026-10-29, PR #52)

| ID | Requirement | Source status |
|---|---|---|
| V1.STYLE_FORM | Native form sections, left labels/right summaries, menu/inline/pushed pickers | Source-integrated; runtime unverified |
| EDITOR.STYLE_SAMPLE | Same sample scenery/text/timing as grid; live rendered draft; play/pause only | Source-integrated; runtime unverified |
| EDITOR.PROJECT_CAPTION_STYLE | One appearance across clips, no caption scope/inheritance UI; new exports agree | Source-integrated; runtime unverified |
| EDITOR.CAPTION_PLACEMENT | Global placement in Style: preset menu, inline X/Y, live sample, Cancel/Done | Source-integrated; runtime unverified |
| EDITOR.ACTIONS | Five equal bottom actions including Export; compact spacing; main Undo/Redo in toolbar | Source-integrated; runtime unverified |

See [handoff](handoffs/STYLE_SHEET.md).
This supersedes the earlier PR #52 real-video Style preview and clip-caption scope.

## Unified Style sheet (2026-10-29)

| ID | Requirement | Source status |
|---|---|---|
| V1.STYLE | One large sheet: real preview, selected template, inline customization | Source-integrated; runtime unverified |
| V1.PRESETS | Native push to lazy grid of existing catalog; selection pops to Style | Source-integrated; runtime unverified |
| EDITOR.STYLE_TRANSACTION | Cancel/dismiss discard; Done saves before adoption, one history entry; retry remains local | Source-integrated; runtime unverified |
| EDITOR.STYLE_SCOPE | Project inheritance, sparse clip overrides, named resets and current Pro checks | Source-integrated; runtime unverified |

See [source handoff](handoffs/STYLE_SHEET.md).
This supersedes the separate Styles carousel / Customize descriptions below.

## Timeline width (2026-10-28, PR #50)

| ID | Requirement | Source status |
|---|---|---|
| EDITOR.TIMELINE_WIDTH | Ruler/tracks span editor width; preview/controls/labels/prompts retain side padding; centered-playhead scroll space preserved | Source-integrated; device layout unverified |

## Graphite theme (2026-10-28, PR #50)

| ID | Requirement | Source status |
|---|---|---|
| V1.PRO / APP.GRAPHITE | Free dark Graphite directly after Paper; #279ED2 accent, Midnight-like translucent panels and layered charcoal/blue background; Paper default and existing Pro themes preserved | Source-integrated; compilation/device appearance unverified |

See [source handoff](handoffs/GRAPHITE_THEME.md). Preview handoff #51 below is
squash merged into #50 as 35b29af after the user reported it working.

## Preview handoff (2026-10-28, stacked on #50)

| ID | Requirement | Source status |
|---|---|---|
| EDITOR.PREVIEW_HANDOFF | Covered preview retains video/caption frame; one live owner; readiness-gated return; bounded decoded-frame cache and stale callback rejection | Source-integrated; compilation/device acceptance unverified |

See [handoff](handoffs/PREVIEW_HANDOFF.md).

## Contextual caption editor (2026-10-28)

| ID | Requirement | Source status |
|---|---|---|
| EDITOR.CONTEXTUAL_CAPTION | No top-level Timing; shared Edit caption from timeline/transcript; text/words/split/merge/exact timing; no playback controls; selected-caption return to main timeline | Source-integrated; compilation/device acceptance unverified |
| EDITOR.CAPTIONS_PREVIEW | Top video preview/play/pause/Undo/Redo, no scrubber/timeline; always highlight current playback row without auto-scroll; retain contextual push/pop | Source-integrated; compilation/device acceptance unverified |
| EDITOR.CAPTION_ROW_ACTION | Row tap selects/highlights/seeks; selected row's top-left Edit caption pushes editing; no inline text field or Split / Words | Source-integrated; compilation/device acceptance unverified |

See [handoff](handoffs/CONTEXTUAL_CAPTION_EDITOR.md). Other consolidation is deferred.

## Final project sheets — passes 1–3 (2026-10-28, PR #49)

| ID | Requirement | Source status |
|---|---|---|
| PROJECT.DIRECT_EDITOR | One direct editor route, cancellable preparation | Integrated |
| PROJECT.INFO_STORAGE | Plain ellipsis, metadata/originals/relink, scoped storage | Integrated |
| PROJECT.CLIPS_SHEET | Numbered timeline, select/rename/add/remove/reorder in Clips | Integrated |
| PROJECT.CLIP_REORDER | Native local drag order, Cancel/Save, one expected-state durable history entry | Integrated |
| PROJECT.CLIP_ORDERING | Genuine source anchors, native/manual captions, settings and coverage follow stable clips | Integrated |
| PROJECT.EXPORT_SHEET | Existing toolbar-only Export sheet owns configuration/activity/files/delivery | Integrated |
| PROJECT.CONSOLIDATION | Shared structural projection, current docs and nonblocking optional artwork | Integrated |

All three passes have source integration; compilation/device/output acceptance remains
unverified. [handoff](handoffs/EDITOR_SHEETS.md)
supersede earlier intermediate overview/clip-strip and deferred-pass descriptions below.

## Clip management — pass 2 (2026-10-28, PR #49)

| ID | Requirement | Status |
|---|---|---|
| PROJECT.ADD_CLIPS | Reviewed Photos/Files/URL append, cancellation/failures, one publication | Source-integrated |
| PROJECT.REMOVE_CLIPS | Confirmed removal, last-clip guard, retained clock/settings/captions | Source-integrated |
| PROJECT.CLIP_HISTORY | Expected-state durable structural Undo/Redo and original retention | Source-integrated |
| PROJECT.CLIP_COVERAGE | Accepted coverage reuse/reindex, unresolved audio admission, schema 11 | Source-integrated |

Pass 1 remains intact. Drag reorder remains pass 3. See
[handoff](handoffs/EDITOR_SHEETS.md); compilation/device/output acceptance unverified.

## Direct editor and sheets — pass 1 (2026-10-28)

| ID | Requirement | Status |
|---|---|---|
| PROJECT.DIRECT_EDITOR | Home/Recent/import/Queue enter the editor directly | Source-integrated |
| PROJECT.INFO_STORAGE | Basic info, originals/relink, scoped storage and thumbnail cleanup | Source-integrated |
| PROJECT.CLIPS_SHEET | Two entry points, numbered timeline labels, select and existing rename | Source-integrated |
| PROJECT.EXPORT_SHEET | Existing sheet owns configuration, activity and retained MP4/SRT files; toolbar-only entry | Source-integrated |

See [handoff](handoffs/EDITOR_SHEETS.md).
No clip addition/removal/reorder in this pass. Earlier overview navigation is
superseded; compilation/device/output acceptance remains unverified.

## Timeline editor passes 1–3 — issue #47 (2026-10-27)

| ID | Requirement | Status |
|---|---|---|
| EDITOR.STRUCTURE | Fixed player/controls/timeline area and sticky horizontal actions | Source-integrated |
| EDITOR.SHEETS | Caption/transcription/timing/media tools in sheets; large animated Styles; existing Customize/Export | Source-integrated |
| EDITOR.PREPARATION | Delayed custom indicator, blurred editor, Cancel/Back and stale-result rejection | Source-integrated |
| EDITOR.FRAME_TIMELINE | Multi-clip frame tracks, ruler, centered playhead and zoom | Source-integrated in pass 2; native execution unverified |
| EDITOR.TIMING_GESTURES | Caption move/resize and associated timing/history integration | Source-integrated in pass 3; native execution unverified |

Pass 2 replaces the main overview/clip strip with multi-clip frame/caption tracks.
The existing overview remains available in focused inspector transport only.
Source evidence: [timeline handoff](handoffs/TIMELINE_EDITOR.md). No runtime evidence.
Older descriptions of a one-scroll inline caption workspace below are superseded.


## Manual caption authoring (2026-10-26)

| ID | Requirement | Status |
|---|---|---|
| V1.MANUAL_CAPTIONS | Explicit user text/timing, correction/hide/delete/undo, saving/duplicate, shared preview/export, retry overlap review | Source-integrated; compilation/device/output acceptance pending |

See [marked handoff](handoffs/MANUAL_CAPTIONS.md).
Schema 10 reads 1–9. Phrase timing does not create model word timestamps, charge
speech usage or mark recognition gaps complete. Whole-cue overlap replacement is
explicitly warned and reversible. Earlier rows remain delivery history.


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

## Animated Styles sheet (2026-10-26)

| ID | Requirement | Status |
|---|---|---|
| V1.PRESETS / V1.STYLE | Animated sample carousel sheet, explicit apply, inherited/clip scope, compact real preview | Source-integrated; compilation/device/output acceptance pending |

See [animated styles handoff](handoffs/ANIMATED_STYLES.md). All ten catalog definitions,
recognition, entitlement rules and multi-clip support remain unchanged.

## Expanded Pass 1 (#41)

| ID | Requirement | Status |
|---|---|---|
| PROJECT.ONE_CREATION | One project, one/multiple ordered files, visual review and retry | Source-integrated; unverified execution |
| PROJECT.DETAILS | Combined overview, ordered clips, defaults and retained exports | Source-integrated; unverified execution |
| PROJECT.CLIP_EDITOR | Continuous clock, clip navigation and grouped captions | Source-integrated; unverified execution |
| PROJECT.CLIP_NAMES | Individual clip labels, original-name restoration, persistence/duplicate and undo | Source-integrated; unverified execution |
| PROJECT.CLIP_SETTINGS | Per-setting overrides/reset, history and effective output | Source-integrated; unverified execution |
| PROJECT.EXPORTS | Queued/in-place generation, actual-file preview/save/share | Source-integrated; unverified execution |
| PROJECT.SAVING | Shared atomic writer across details/editor/export routes | Source-integrated; unverified execution |

Details and pending acceptance: [PROJECT_EXPERIENCE](handoffs/PROJECT_EXPERIENCE.md).

## Current implementation evidence

| Area | Contracts and source evidence |
|---|---|
| Projects/import/storage | [Project system](handoffs/PROJECT_SYSTEM.md), [home/native flow](handoffs/HOME_NATIVE_FLOW.md); UUID packages, original-safe import/lifecycle, cached library and automatic project saving |
| Transcription/jobs/delivery | [Recovery](handoffs/TRANSCRIPTION_RECOVERY.md), [processing](handoffs/PROCESSING_DELIVERY.md); accepted partial captions, gap retry, native intervals/IDs, quota and independent frozen outputs |
| Editing/styles | [Editor](handoffs/EDITOR_EXPERIENCE.md), [caption production](handoffs/CAPTION_PRODUCTION.md); one scrolling workspace, direct correction/history, resolved versioned looks and shared renderer |
| Integration fixes | [Consolidation](CONSOLIDATION.md); strict version-2 decoding, covered player-layer handoff, current error reporting and documentation cleanup |
| Acceptance/release | [Readiness](PRODUCTION_READINESS.md); all native/build/device/commerce/output evidence remains pending |

The original Fxx catalog and delivery history are historical; no new feature is
implied. Search/sort/filter, direct URLs and combined imports remain existing
supported behavior; transcript search and incoming share extension are not required.
No invented word timing, implicit regrouping or inference on style choices.
Previous source records are preserved in git history.
