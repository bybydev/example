# Inkribe iOS — current design contract

2026-10-24. Adapt the inspected AppShot editor and AppShot/AppReel home hierarchy
to Inkribe's actual caption workflow and AppFoundation themes. These are integrated
source directions; device-rendered visual/interaction acceptance remains pending.

## Project home and navigation

One scrolling home: New Project hero/CTA → save-failure/queue/model activity → Projects
header/filters/sort → compact thumbnail rows with sibling actions. Search hides the
hero/filter strip while retaining results/sort and clear-filter controls. Empty,
loading, failure, missing-original and save-failure states use actual data.
Hero/toolbar enter the same guarded importer; partial/cancelled imports retain their
committed project IDs and route only after dismissal. Surrounding settings/storage/
models/queue/export views share AF surfaces, borders, accent and semantic text.

Native Back/edge swipe and continuous themed chrome remain installed. A completed
pop does not discard failed saves or block on persistence. A genuine save failure offers Retry and is accessible from Home; normal autosaving
does not create an attention card. Rename opens the existing project title field.
There is no user-facing draft/recovery/discard/reload workflow. No sticky home/activity component or UIKit gesture override.

## Editor and customization

One main vertical scroll: actual video/audio canvas → transport/timeline → horizontal
Captions/Style/Timing/Media choices → active workspace. Expansion grows footage
within that page. No pinned preview, bottom-inset editor tools, floating duplicate
or nested vertical transcript scroll. Native navigation and keyboard Done remain.

Whole-caption text is the primary correction field. Selected word/phrase text,
original-clock timing, split/merge, undo/redo and missing-range retry remain inline.
Playback-follow is explicit/off initially, never changes editing selection/focus,
and pauses on correction/tool selection. Field focus/geometry changes reveal inputs;
accepted text, timing/trim drafts and per-tool anchors remain app-owned context.
Unapplied timing/trim needs explicit Apply; UI-only context is not durable project data.

Style leads with real-footage/caption comparisons. Basic, Spotlight, Karaoke, Pop,
Soft Fade, Punch, Podcast, Cinema, Classroom and Editorial use different typography,
layout, contrast/background/emphasis and motion combinations. Categories, selection,
saved version, Customized/custom-position state, access locks and named resets are
explicit. Saved values do not change because catalog defaults evolve. Apply keeps
placement; recommended placement is a separate undoable action.

Text/Colors/Backdrop/Layout/Position/Motion detail controls include scrollable real
preview/playback. Typography/colors/backdrop/layout/placement/motion reset independently.
Covered main player layers relinquish presentation during style/export/queue modals;
newly attached overlays clear stale errors and old callbacks cannot replace current
status. Preserve current free/Pro/expiry/restore behavior and AF upsells/themes.

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
