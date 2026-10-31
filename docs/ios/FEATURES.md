# Inkribe iOS — current feature ledger

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

See [scope](phases/MUSIC_LAYER.md) and [handoff](handoffs/MUSIC_LAYER.md). No other
editor design changes are authorized. Source-only restrictions remain.

## Native fullscreen playback (2026-10-29, stacked on #52)

| ID | Requirement | Source status |
|---|---|---|
| EDITOR.NATIVE_FULLSCREEN | Native fullscreen for both expand entries; current player/live captions, paused same-position return | Source-integrated; runtime unverified |
| EXPORT.NATIVE_PREVIEW | Native fullscreen for all completed-MP4 preview routes; preserve delivery protection | Source-integrated; runtime unverified |

See [scope](phases/NATIVE_FULLSCREEN.md) and [handoff](handoffs/NATIVE_FULLSCREEN.md).

## Style form revision (2026-10-29, PR #52)

| ID | Requirement | Source status |
|---|---|---|
| V1.STYLE_FORM | Native form sections, left labels/right summaries, menu/inline/pushed pickers | Source-integrated; runtime unverified |
| EDITOR.STYLE_SAMPLE | Same sample scenery/text/timing as grid; live rendered draft; play/pause only | Source-integrated; runtime unverified |
| EDITOR.PROJECT_CAPTION_STYLE | One appearance across clips, no caption scope/inheritance UI; new exports agree | Source-integrated; runtime unverified |
| EDITOR.CAPTION_PLACEMENT | Global placement in Style: preset menu, inline X/Y, live sample, Cancel/Done | Source-integrated; runtime unverified |
| EDITOR.ACTIONS | Five equal bottom actions including Export; compact spacing; main Undo/Redo in toolbar | Source-integrated; runtime unverified |

See [scope](phases/STYLE_SHEET.md) and [handoff](handoffs/STYLE_SHEET.md).
This supersedes the earlier PR #52 real-video Style preview and clip-caption scope.

## Unified Style sheet (2026-10-29)

| ID | Requirement | Source status |
|---|---|---|
| V1.STYLE | One large sheet: real preview, selected template, inline customization | Source-integrated; runtime unverified |
| V1.PRESETS | Native push to lazy grid of existing catalog; selection pops to Style | Source-integrated; runtime unverified |
| EDITOR.STYLE_TRANSACTION | Cancel/dismiss discard; Done saves before adoption, one history entry; retry remains local | Source-integrated; runtime unverified |
| EDITOR.STYLE_SCOPE | Project inheritance, sparse clip overrides, named resets and current Pro checks | Source-integrated; runtime unverified |

See [scope](phases/STYLE_SHEET.md) and [source handoff](handoffs/STYLE_SHEET.md).
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

See [scope](phases/PREVIEW_HANDOFF.md) and [handoff](handoffs/PREVIEW_HANDOFF.md).

## Contextual caption editor (2026-10-28)

| ID | Requirement | Source status |
|---|---|---|
| EDITOR.CONTEXTUAL_CAPTION | No top-level Timing; shared Edit caption from timeline/transcript; text/words/split/merge/exact timing; no playback controls; selected-caption return to main timeline | Source-integrated; compilation/device acceptance unverified |
| EDITOR.CAPTIONS_PREVIEW | Top video preview/play/pause/Undo/Redo, no scrubber/timeline; always highlight current playback row without auto-scroll; retain contextual push/pop | Source-integrated; compilation/device acceptance unverified |
| EDITOR.CAPTION_ROW_ACTION | Row tap selects/highlights/seeks; selected row's top-left Edit caption pushes editing; no inline text field or Split / Words | Source-integrated; compilation/device acceptance unverified |

See [scope](phases/CONTEXTUAL_CAPTION_EDITOR.md) and
[handoff](handoffs/CONTEXTUAL_CAPTION_EDITOR.md). Other consolidation is deferred.

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
unverified. [Scope](phases/EDITOR_SHEETS.md) and [handoff](handoffs/EDITOR_SHEETS.md)
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

See [scope](phases/EDITOR_SHEETS.md) and [handoff](handoffs/EDITOR_SHEETS.md).
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

See [scope](phases/MANUAL_CAPTIONS.md) and [marked handoff](handoffs/MANUAL_CAPTIONS.md).
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

