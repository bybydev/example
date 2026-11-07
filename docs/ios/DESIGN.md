# Inkribe iOS — current design contract

## Preview handoff (2026-10-28, stacked on #50)

Opening Captions/Customize or another preview-bearing presentation keeps the covered
editor visually stable: retain its video still and caption time/snapshot while
the live player belongs to the visible host. On return, adopt the outgoing host's
latest still until the returning video layer has its first displayable frame.
There is one live owner and one AVPlayer; no second player or project reload.
Caption overlays on stills use the held presentation, not another sheet's advancing
playhead. Audio-only previews keep live caption timing without waiting for video.
Initial/no-frame, deliberate black footage and real preview failures retain their
existing states. Preserve preview geometry, #50's row actions, push/pop, controls,
highlight-without-auto-scroll, keyboard, editing/history/saving and exports.
Source integration is not device acceptance. See handoffs/PREVIEW_HANDOFF.md.

## Contextual caption editor (2026-10-28)

Bottom actions are Clips, Captions, Styles, Media and Customize. Export remains
toolbar-only. Timing is no longer a top-level action. First tap selects a timeline
caption; second tap opens Edit caption without another seek. In Captions, the
row text selects/highlights and seeks to that caption, including a selected row.
Only the selected row's top-left Edit caption button pushes editing in the existing
navigation stack, in the former Editing caption label's position. Back/swipe-back/
Done returns to the same Captions list and scroll context. The list has no inline
text editing, Split / Words or deletion control; those edits belong to Edit caption.

Captions shows a bounded video preview at the top, followed by play/pause, time
readout and Undo/Redo. The list scrolls independently below; there is no scrubber,
timeline or follow toggle in this sheet. The current playback caption always has
an accent highlight/marker, even when a different caption is selected for editing.
Playback never selects another row or automatically scrolls the list. The same
player/renderer serves this preview; the covered main host retains a still while
its live layer is disconnected.

Edit caption contains one full-caption text field, native word correction and
split/merge where available, expandable caption/word timing and manual deletion.
There is no player, scrubber or transport in this editor. From Captions, Done pops
to the list. From the timeline, Done (or sheet dismissal) returns to the main
timeline, paused 0.25 seconds before the surviving edited caption, clamped to zero,
with that caption selected. No automatic playback.
Precision timing retains its existing original-project-clock semantics. A removed
or no-longer-visible target shows an unavailable state rather than another caption.
Other consolidation is deferred. This section supersedes older Timing-sheet wording.

2026-10-24. Expanded Pass 1 (#41) adds the discussed project experience to the
AppShot-inspired editor and AppShot/AppReel home hierarchy
to Inkribe's actual caption workflow and AppFoundation themes. These are integrated
source directions; device-rendered visual/interaction acceptance remains pending.

## Project home and navigation

One scrolling home: New Project hero/CTA → save-failure/queue/model activity → Projects
header/filters/sort → compact thumbnail rows with sibling actions. Search hides the
hero/filter strip while retaining results/sort and clear-filter controls. Empty,
loading, failure, missing-original and save-failure states use actual data.
Hero/toolbar enter the same guarded importer. One or multiple files always create
one project. Review thumbnails/durations/order, remove or retry failed selections,
then create atomically. No separate/combined selector or silent subset publication.
Successful creation routes directly to the editor after importer dismissal. Surrounding settings/storage/
models/queue/export views share AF surfaces, borders, accent and semantic text.

Native Back/edge swipe and continuous themed chrome remain installed. A completed
pop does not discard failed saves or block on persistence. A genuine save failure offers Retry and is accessible from Home; normal autosaving
does not create an attention card. Rename opens the existing project title field.
There is no user-facing draft/recovery/discard/reload workflow. No sticky home/activity component or UIKit gesture override.

## Project sheets (2026-10-28)

The library, Recent Project, creation completion and Queue open the existing editor
directly. There is no intermediate project overview. A plain ellipsis toolbar menu
with a 44-point target opens Project info: title, duration, clip count, canvas,
created/modified dates, original media details/relink and scoped storage accounting.
Confirmed cleanup removes only that project's rebuildable library thumbnail.

Clips is one large sheet, opened from bottom Clips or Clip N of M above the timeline.
Reveal/highlight the selected row; show thumbnails, full names within bounded rows,
duration/output position and missing originals. Tap retained clips to select/seek and
return. Swipe/context/accessible rename uses the existing cancellable rename sheet;
excluded-by-trim clips remain visible and renameable. Timeline labels stay Clip N.
Add clips opens local Photos/Files/direct-URL review. New media appends to the existing
canvas/defaults; Clips stays open and reveals the added row. Preparation is cancellable,
failed picks require retry/removal, and Add publishes all reviewed selections or none.
It does not start transcription. An explicit end trim expands (disclosed before Add).

Remove is a confirmed swipe/context/accessible action, disabled for the last clip or
while project transcription is active. Retained captions/settings move with their clips
when the gap closes. If removal clears the visible trim, the confirmation explains that
remaining clips become visible. Originals stay in project storage for Undo; completed
exports stay unchanged. Reorder enters native drag mode in this same sheet. Clip rows show names/durations
with drag handles and accessible Move earlier/later actions; selection/rename/removal
stay inactive while arranging. Cancel keeps the video unchanged. Save applies one
undoable order and returns to normal Clips with the selected identity retained.
Project trim stays at its current start/end times; disclose that reordered footage
inside the window can change.

Only toolbar Export opens the existing large Export sheet. It contains configuration,
Export now/Queue export, current/other export activity and newest-first completed MP4/SRT
files. Retain revision freshness, optional artwork, actual-file preview, Photos/Files/
Share, settings reuse and confirmed local deletion. Settings reuse returns to the same
sheet's configuration and rechecks the existing Pro policy. Independent completed files
remain accessible through the app-wide Queue as well. Optional artwork does not
block sheet dismissal; actual user preview/save/share retains its delivery protection.
No bottom Export action.

## Timeline editor — issue #47 (2026-10-27)

Fixed editor composition: actual media player → transport → remaining timeline
area → horizontally scrolling action buttons pinned above the bottom safe area.
The main editor contains no caption list or inline configuration workspace.
Preview sizing depends on viewport/canvas only; sheet, focus and keyboard state
must not shrink or move it. Fullscreen is a separate preview presentation and
relinquishes the underlying player layer while retaining the same session/clock.

Pass 2 replaces the overview/clip strip in the main editor with one continuous
project timeline: ruler → real frame strip with clip boundaries → caption blocks
and unfinished ranges. Frame tiles/captions align on the same output-clock axis.
The center playhead stays fixed while the content scrolls beneath it. Playback
follows that clock across clip boundaries; dragging pauses playback and seeks,
with a final exact seek on release. Pinch zoom preserves time beneath the fingers.
Leading/trailing padding allows the project start/end to meet the center playhead.

Tap a clip to select/seek it. The current/selected clip's numbered header opens
the Clips sheet; rename belongs to that sheet. Tap a caption to select/reveal it; tap it again to
open text and word/phrase timing in a large sheet, preserving the playhead on the
second tap. Selection remains separate from playback-follow. Project trim and
source offsets map frame samples correctly without rewriting clip/caption times.
Audio-only/missing/failed frame samples have explicit neutral placeholders.

Frame requests prioritize the visible window with nearby prefetch, two cancellable
decoders and a 12 MiB cache budget; no per-frame players or whole-video bitmaps.
Leaving, covering, zooming or moving the viewport cancels obsolete work. Seek
callbacks from cancelled scrolls cannot continue behind an inspector. Native
VoiceOver elements expose clip/caption activation, adjustable playhead and zoom.
Pass 3 adds direct dragging of a selected caption's body to move it, and edge
handles to resize it. Holding any caption selects it for movement, including
very narrow blocks. Other drags scroll; pinch is unavailable during a timing drag.
Edge scrolling follows a held gesture across the viewport, constrained to its clip.
A temporary block/readout and video-frame audition show the proposal; caption
render timing is applied on release, not written for every pointer update.

A completed valid gesture creates one undoable edit and autosaves through the
existing writer. Cancel, navigation, backgrounding, rotation, playback start or a
changed target cancels the proposal. Unrelated saves/append-only speech publication
do not invalidate unchanged target data. Rejected edits restore the initial playhead.
Moves shift all linked word intervals equally; edge resizing scales existing
intervals explicitly without inventing word boundaries or modifying native anchors.
Positive-duration/precision and clip/trim bounds are enforced before publication.

An edge hidden by project trim has no timeline handle; its original timing remains
editable in Edit caption. Body movement preserves already-hidden portions.
Existing native overlap behavior remains; timeline gestures cannot overlap another
manual caption or silently replace additional recognized captions. Such proposals
show a red block/readout and require the existing Add Caption replacement review.
VoiceOver provides 0.1-second move/start/end actions through the same edit path.
Native execution/performance are unverified.

Bottom actions are Clips, Captions, Styles, Media and Customize. Each opens
a sheet. Captions retains transcript correction, manual caption creation, overlap
review, generation, gaps/retry and current-playback highlighting without auto-scroll.
Its top preview has play/pause and Undo/Redo but no scrubber/timeline. Contextual Edit caption
retains word/phrase correction, split/merge and original-project-clock timing fields. Media
retains trim/framing/audio and project/clip scope. Customize retains the existing
actual-preview inspector and reset controls. Styles retains the large-only animated
sample browser with explicit Apply and existing Pro rules. Export keeps the durable
queue/delivery flow. Sheet closing clears focus/coalescing and requests a save,
while retaining playhead, selection, accepted text/drafts and per-tool scroll context.
Child Add Caption and upsell sheets are presented from the visible tool sheet.

When project opening takes longer than 180ms, blur the editor content and show a
custom progress ring, Preparing project… and Cancel. Before that delay, preparation
still disables editor content; native Back remains available. Cancel is outside the
disabled/accessibility-hidden editor subtree, cancels the opening task, invalidates
late callbacks and returns promptly. It never cancels queue work or discards edits.
Errors offer retry/navigation; quick opening skips the indicator. Spinner respects
Reduce Motion. This is editor-local presentation, not an application-window blocker.

The older one-scroll editor, inline caption list and no-sticky editor directions
are superseded for this scope. Home search/layout and project details are unchanged.
Source integration does not establish rendered device/keyboard/gesture acceptance.

## Output and accessibility

Visual wrapping/fitting never changes canonical text, grouping, IDs or timing.
Missing captions and gaps stay empty; render/frame errors stay visible. Phrase-timed
units use honest whole-unit effects; frozen legacy motion remains available. Native
shaping/fallback handles scripts and emoji, with actual preview/export checks pending.

Semantic text, wrapping/adaptive layouts, clear focus/selection/error labels and
44pt actions support the intended small-iPhone/large-text/VoiceOver experience;
that experience must be validated on SE2 and a larger iPhone. Caption artwork uses
the renderer, not theme colors. No performance/accessibility acceptance is inferred
from source inspection. See [readiness](PRODUCTION_READINESS.md) and
[caption design matrix](handoffs/CAPTION_PRODUCTION.md).

Earlier imagery/layout directions are preserved in
git history and do not authorize new scope.

