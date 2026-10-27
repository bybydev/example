# Inkribe iOS — current design contract

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
Successful creation routes to project details only after importer dismissal. Surrounding settings/storage/
models/queue/export views share AF surfaces, borders, accent and semantic text.

Native Back/edge swipe and continuous themed chrome remain installed. A completed
pop does not discard failed saves or block on persistence. A genuine save failure offers Retry and is accessible from Home; normal autosaving
does not create an attention card. Rename opens the existing project title field.
There is no user-facing draft/recovery/discard/reload workflow. No sticky home/activity component or UIKit gesture override.

## Project details

One scrolling overview: combined preview/Edit → ordered Clips → Project defaults →
Exports newest first. Clip rows seek the shared editor at that clip. Rename, duplicate
and Trash remain plain actions. Save-failure and missing-media messages use actual state.

Exports includes active/failed work with Queue access and retained completed MP4/SRT
files with format/size/date, optional artwork, actual-file playback, Photos/Files/Share
and explicit local deletion. Old outputs remain immutable; changed revisions can show
Created before your latest changes and Export again. Export now follows progress in-place;
Queue export opens job detail. Both publish to the same collection.

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

Tap a clip to select/seek it. The current/selected clip's header menu retains
rename and Go to clip start. Tap a caption to select/reveal it; tap it again to
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
editable in the Timing sheet. Body movement preserves already-hidden portions.
Existing native overlap behavior remains; timeline gestures cannot overlap another
manual caption or silently replace additional recognized captions. Such proposals
show a red block/readout and require the existing Add Caption replacement review.
VoiceOver provides 0.1-second move/start/end actions through the same edit path.
Native execution/performance are unverified.

Bottom actions are Captions, Styles, Timing, Media, Customize and Export. Each opens
a sheet. Captions retains transcript correction, manual caption creation, overlap
review, generation, gaps/retry and explicit playback-follow. Timing retains word/
phrase correction, split/merge and original-project-clock timing fields. Media
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
[caption design matrix](phases/CAPTION_PRODUCTION.md).

Earlier imagery/layout directions are preserved in
[the archive](archive/before-consolidation/DESIGN.md) and do not authorize new scope.

