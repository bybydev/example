# Inkribe iOS — start here

2026-10-31. Current work is [timeline clip trimming](phases/CLIP_TRIMMING.md),
stacked on PR #55 at 381b0d2b and targeting feat/ios-media-form. Timeline edge
handles are the only trimming UI; the existing main preview auditions boundaries.
One saved Undo edit closes excluded time without moving native clip/caption data.
Media has no trim controls. Schema 13 reads 1–12, including old project trim windows;
frozen exports remain independent. See [source handoff](handoffs/CLIP_TRIMMING.md).
Source-only; compilation/native/UI acceptance unverified. Leave both PRs open.

2026-10-31. [Media Form pass 2](phases/MEDIA_FORM.md) completes the two source
passes in PR #55, extending bb0d1b11. Scope/reset/save/history/reopen and shared
preview/export review preserves the approved Form. Scoped fixes cancel a closed
sheet's unpublished save, remove preview-preparation waiting from Done, recover
interrupted preview work, rewrite clip settings with one sort and reconcile speech
progress on dismissal. See [review matrix](handoffs/MEDIA_FORM.md). Compilation/
native/UI acceptance is unverified; keep open without auto-merge. Earlier Media
preview/default wording is historical where superseded by this scope.

2026-10-31. [Music integration pass 3](phases/MUSIC_LAYER.md) completes the three
source passes in PR #54, extending 73a2323c. Review covers file/history/lifecycle,
duration/mute behavior and frozen outputs; scoped fixes harden actual-sheet draft
ownership, late completion/cleanup, rational repeat/fade boundaries, stable fade
controls, zero-volume feedback and import suitability checks. The approved layout
is unchanged. See [review matrix](handoffs/MUSIC_LAYER.md). Source-only: no builds,
tests/typechecks/native/UI runs; runtime acceptance remains unverified. Leave open.

2026-10-31. [Music pass 2](phases/MUSIC_LAYER.md) is now source-integrated in PR #54,
extending b345f71c. Timeline order is Video/Music/Captions, with leading original
mute and square music/caption controls before time zero, Add music, a real waveform
and loop indication. Music has a controls-only large sheet; Files/replace/settings
publish together on Done, while Cancel/swipe discards staging. Existing editor
chrome and preview ownership remain. See [handoff](handoffs/MUSIC_LAYER.md). Pass 3
awaits the user's signal; source-only, no runtime acceptance or auto-merge.

2026-10-31. Current work is [music layer pass 1](phases/MUSIC_LAYER.md), in one
new feat/ios-music-layer PR from develop 723f333, targeting develop. One soundtrack
has owned storage, independent output timing/mix/fades/loop, saved edits/history and
shared preview/MP4 rendering. Schema 12 reads 1–11; speech remains clip-only. Pass 1
has no editor UI/layout changes; leading controls and the preview-free Music sheet
are pass 2 and await the user's next signal. See [handoff](handoffs/MUSIC_LAYER.md).
Source-only; compilation/runtime unverified; keep the PR open without auto-merge.

2026-10-29. Current work is [native fullscreen playback](phases/NATIVE_FULLSCREEN.md),
stacked on PR #52 at 3f9b8107 and targeting feat/ios-style-sheet-grid. Editor expands
use the existing live composition/captions; Export/Queue previews use the selected
completed MP4. AVKit owns fullscreen controls/dismissal; inline previews remain.
See [source handoff](handoffs/NATIVE_FULLSCREEN.md). Source-only; runtime unverified.
Keep parent/stacked PRs open without auto-merge.

2026-10-29. Latest approved revision in PR #52 is the [Style form](phases/STYLE_SHEET.md):
shared template sample background/text, live appearance preview with play/pause only,
native section/row controls and pushed pickers. Caption appearance is project-wide;
placement stays in Style with live sample feedback; Media retains its actual
preview/scrubber for framing/audio. The template grid and
Cancel/Done transaction remain. This supersedes PR #52's first real-video Style
preview, category tabs and caption scope menu below. See [handoff](handoffs/STYLE_SHEET.md).
Source-only; compilation and runtime acceptance remain unverified. Keep #52 open.

2026-10-29. Current user-approved work is the [unified Style sheet](phases/STYLE_SHEET.md),
from develop b28beebb in feat/ios-style-sheet-grid, targeting develop. Style contains
real preview, selected template and inline controls; its template row pushes the
lazy grid. Cancel discards local settings; Done durably saves one undoable edit.
This replaces the former carousel and separate Customize entry. Existing catalog,
single player/held-frame handoff, clip inheritance and Pro access remain.
See the [source handoff](handoffs/STYLE_SHEET.md). Source-only; compilation/device
acceptance is unverified. Keep the new PR open without auto-merge.

2026-10-28. PR #50 also removes the timeline's outer side gutters: ruler/tracks
span the editor width; preview, controls, labels and prompts keep 12-point insets.
Centered-playhead scroll space is preserved. Source-only; device layout unverified.

2026-10-28. Current work in PR #50: Free dark **Graphite**, immediately after
Paper, with accent #279ED2, translucent panels and layered charcoal/blue lighting
following the user's confirmed revision to match Midnight's depth. Paper remains the
default; other themes stay Pro. [Source handoff](handoffs/GRAPHITE_THEME.md).
PR #51's preview fix is squash merged into #50 as 35b29af after the user reported
it working. Keep #50 open without auto-merge; source-only checks remain in force.
Earlier stacked-PR status below is historical.

2026-10-28. Current work: preserve preview frames during sheet/player handoffs in
`fix/ios-preview-handoff`, stacked on PR #50 (`5c9f9eb`) and targeting
`feat/ios-contextual-caption-editor`. Covered hosts keep a still with its caption
clock/snapshot; live video returns after layer readiness. The single session player,
all #50 caption flows and preview dimensions remain. Source integration only;
compilation/device acceptance is unverified. See [scope](phases/PREVIEW_HANDOFF.md)
and [handoff](handoffs/PREVIEW_HANDOFF.md). Keep both PRs open without auto-merge.

2026-10-28. Current work is the contextual caption editor, based on develop
`ba5b422`, in a new PR targeting develop. The bottom Timing action is removed.
Second-tap a selected timeline caption, or use the selected row's top-left Edit
caption in Captions, to open the editor. It has no playback controls. Captions pushes it in its own
navigation stack; Back or Done returns to the same list. Timeline entry stays a
sheet whose Done returns paused 0.25 seconds before the edited caption (clamped
to zero), retaining selection.
Captions has a bounded video preview and play/pause/Undo/Redo above its scrollable
list, with no scrubber/timeline. The current playback row is always highlighted;
playback does not select rows or automatically scroll the list.
Tapping row text still selects/highlights/seeks. Caption text in the list is read-only;
only Edit caption pushes editing. There is no Split / Words or inline text field.
See [scope](phases/CONTEXTUAL_CAPTION_EDITOR.md) and
[source handoff](handoffs/CONTEXTUAL_CAPTION_EDITOR.md). Other consolidation waits
for a separate user signal. The earlier sheet passes below are merged in the base.

2026-10-28. PR #49 (`feat/ios-editor-sheets` → develop) contains source integration
for all three approved project-sheet passes, through pass 3 based on `014ad963`.
Keep the PR open without auto-merge. Compilation/device acceptance is unverified.

Projects open directly in the fixed player → controls → timeline → bottom-actions
editor. Project info in the plain ellipsis menu handles metadata, originals/relink
and storage. Clips opens from the bottom action or numbered timeline header and
supports Photos/Files/URL append, rename, confirmed removal and native drag reorder.
Reorder is local until Save, with Cancel and one durable undoable change.

Only toolbar Export opens the existing Export sheet, which owns configuration,
progress, completed MP4/SRT files, preview/save/share and local deletion. Original
files and frozen outputs remain independent from later project changes.

Schema 11 reads 1–10. Keep genuine native/source anchors, accepted partial captions,
clip settings, shared active engine/model, 30-minute Free policy and Mac behavior.
Adding/reordering clips does not start transcription. Current global trim is a
clock window; reordering can change which footage falls inside it.

Read [scope](phases/EDITOR_SHEETS.md), [marked source handoff](handoffs/EDITOR_SHEETS.md),
[plan](PLAN.md), [features](FEATURES.md), [workflow](WORKFLOW.md), [architecture](ARCHITECTURE.md)
and [design](DESIGN.md). Root AGENTS.md and the latest user request control scope.
Previous phase evidence remains in linked handoffs and the archive.

Source-only: no builds/typechecks/tests/fixtures, CI, generation/models, native
processing/exports, UI/device/accessibility execution or deployment. Source
completion is not production validation. [Readiness](PRODUCTION_READINESS.md)
retains the unverified runtime/release gates.
