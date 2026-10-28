# Inkribe iOS — current architecture

## Final project sheets and reorder — pass 3 (2026-10-28)

ProjectClipsSheet owns a local stable-ID order and native List edit-mode handles.
Cancel never mutates the session. Save supplies an expected ClipGraphState and a
complete identity permutation to EditorSession → transcription admission → repository.
One valid changed order advances one revision and records one bounded structural
history entry. Invalid/stale/no-op orders never publish a structural edit.

ClipGraphEdit shares manual/native projection for append/remove/reorder. Reorder
rebuilds contiguous project intervals, translates each clip’s editable caption values
by an exact rational offset, sorts projected cues/words/manuals chronologically and
reindexes accepted coverage by clip/core. Native source intervals/IDs/raw windows,
clip names/settings and original files stay intact. Global trim keeps its absolute
clock window. Existing preview/media/audio/MP4/SRT read the same document graph.
Selection/playhead, timeline frames/labels and library artwork use existing adoption.

Structural history checks both expected graph and current transcription admission;
labels distinguish add/remove/reorder. Background export artwork leases remain
per-file deletion guards, while only user delivery blocks Export/Queue dismissal.
Unused ClipStrip UI is removed; thumbnail/name helpers are in ClipThumbnail.swift.
Schema stays 11; Mac, shared packages, renderer, speech engine and commerce stay intact.
See [handoff](handoffs/EDITOR_SHEETS.md). Earlier pass sections describe retained history.

## Clip management — pass 2 (2026-10-28)

PreparedClipImport owns inspected unpublished originals. MediaImporter supports both
new-project publication and returning staging to AddClipsSheet; Home selection state
is independent. ProjectRepository validates the exact expected base, adopts UUID-owned
files, then publishes one graph revision. Failure before publication leaves the old
graph intact. Inactive resume sidecars and derived artwork are invalidated afterward.
Removed files are kept for history; asset references are limited to retained clips.

ClipGraphEdit removes one clip, translates retained project intervals and maps trim
boundaries without modifying source intervals or native/raw IDs. EditorSession flushes
prior edits, holds only final transcription admission, adopts saved state and records
one bounded expected-state structural history entry. Ordinary caption/settings writes
keep their existing immutable-source gates. Active project speech blocks graph changes;
exports retain their independent pinned versions. Later inference disables incompatible
structural Undo instead of replacing accepted results.

Schema 11 adds optional retained-complete clip coverage. Native accepted window indices
are remapped by clip/core; legacy-complete clips carry accepted raw/captions without
synthesized checkpoint entries. A new structural operation ID prevents stale queue or
charged-allowance reuse. Reservations measure unresolved cores; existing accepted data
is not inferred again. Gap display, duplication, checkpoint seeding/publication and
library artwork support the new graph. Read [handoff](handoffs/EDITOR_SHEETS.md).

## Direct editor and project sheets — pass 1 (2026-10-28)

ProjectEditorDestination acquires the shared EditorSession and directly hosts
ProjectEditorView. There is no ProjectDetailView or second preview owner. Existing
editor opening cancellation, attach/detach, writer/history, error retention and
rename-on-open apply to every project route. Presentation state remains unsaved.
ProjectClipsSheet owns clip-list navigation and nested ClipRenameView; both entry
points capture the selected clip, without opening a new editor. All sheets suspend
timeline gesture/frame work and do not enter the player-sizing calculation.

ProjectStorageSection uses targeted repository package/thumbnail accounting and
ProjectsModel's cache-generation invalidation after confirmed thumbnail-only cleanup.
It never deletes durable data, originals, transcription progress or frozen exports.
ExportView embeds ProjectExportsSection as native Form sections, with one current
progress panel and a shared retained-file inventory. Existing ExportResultView,
delivery leases, frozen jobs, cancellation and deletion contracts remain intact.
Only toolbar Export presents that sheet. Timeline labels change only display text;
no media/caption mapping, schema, renderer, speech/commerce or Mac change is made.
See [handoff](handoffs/EDITOR_SHEETS.md). Earlier overview ownership is historical.

## Timeline editor pass 3 (2026-10-27)

TimelineCaptionTiming captures one cue/manual value, linked editable words, its
clip/trim map and previously reviewed replacement cues. UIKit retains only a
transient proposal during a gesture. No document, history or save changes occur
until release. Expected-state comparison permits unrelated metadata/speech changes;
a changed target/clip/trim cancels. Release rechecks current overlap/bounds and uses
EditorSession's existing atomic native/manual edit patch and serialized writer.
One accepted gesture is one undo entry; cancelled/rejected proposals publish none.

CaptionEdits.moveCue translates linked words by an exact rational delta, preserving
duration and immutable native source anchors. Edge resize reuses cueTiming's explicit
affine manual adjustment and full project validation. The output projection does
not rewrite original clocks. Manual gestures retain only previously reviewed native
replacements; new manual overlaps/replacements are rejected, including those from
concurrent publication. Extreme word compression is limited and validated atomically.

TimelineViewport owns selected-body/edge pan and hold-to-move recognition, exclusive
scroll/pinch ownership, coalesced frame audition and a weak-target edge-scroll clock.
Gesture cancellation/cover/background/layout change/teardown invalidates the clock
and pending seeks. Canvas draws handles/proposed timing only; export/renderer sees
only committed document state. VoiceOver retiming shares the same transaction path.
No schema, queue, speech, purchase, native output renderer or Mac changes.

## Timeline editor pass 2 (2026-10-27)

ProjectTimelineSnapshot derives trimmed output-clock clip/caption/gap geometry
once per CaptionSnapshot generation. Prefix-max interval indexes bound lookups
to the visible time range, including overlapping native captions. Source sample
time equals retained clip source start plus the tile's offset within that clip.
EditorWorkspace retains navigation scale/selection only; project schema 10 and
native timing remain unchanged. EditorSession retains the same composed AVPlayer.

ProjectTimelineView bridges a UIScrollView with a viewport-sized TimelineTrackCanvas.
The center playhead is a sibling overlay; half-viewport project padding permits
seeking to both endpoints. Programmatic offsets never emit seeks; user scrubs are
coalesced to ~30Hz with a final exact seek. Pinch zoom anchors the touched time.
Selection/sheets/playback start invalidate pending momentum seeks. Covered or
background timelines disable interaction/frame work; dismantle cancels requests.

TimelineThumbnailLoader prioritizes visible/nearby tiles, retains at most two live
generators through cancellation teardown, and budgets 12 MiB for normalized 192px
frames. Cache keys include project/asset/hash/path/source-time/size. Failed artwork
is optional and cannot fail project opening. Playback ticks do not rebuild the
project projection. No queue, renderer/export, purchase or speech behavior changes.

## Timeline editor pass 1 (2026-10-27)

ProjectEditorView owns the fixed four-area workspace and modal tool routes.
EditorPlaybackControls can omit its legacy scrubber, allowing transport to precede
the timeline area. Fullscreen/detail customization/manual/export presentations
relinquish the covered main player layer; no new playback engine is introduced.
EditorPreparationPresentation delays its visual overlay 180ms and keeps Cancel
outside disabled content. The view owns/cancels its opening Task; EditorSession
checks cancellation after repository/media awaits and invalidates load generations
on Cancel/Back. Saves, processing queues and source files are outside that teardown.
Schema 10, recognition/word timing, shared engine/model, output clock/renderer,
writer/history, settings and frozen exports remain unchanged. Frame tracks and
interactive timing gestures remain future passes in issue #47.


## Shared active speech engine (2026-10-26)

SpeechEngine.shared owns one active model and one retained native context for all
iOS projects. Settings switching confirms, cancels/drains transcription work,
unloads the old engine and activates the new model. ProcessingLifecycle blocks
and invalidates concurrent speech preparation during that transition. Export
preparation, queued/running exports and export controls remain unaffected.
Job payload model fields are legacy decode-only data; every new/resumed inference uses the active
engine. Accepted windows and edits remain reusable across model switches. See
[model ownership](MODELS.md) and the [current handoff](handoffs/MANUAL_CAPTIONS.md).
This supersedes older descriptions of per-job model ownership below.


## Manual-caption extension (2026-10-26)

Schema 10 adds optional `manualCaptions` (stable ID, clip ID, text, original-project
interval), separate from immutable native recognition. `CaptionUnit` is a transient
render/display adapter for native words and user-timed phrases; native model fields
and checkpoint mapping are unchanged. `ManualCaptionPatch` integrates into the
existing bounded history/writer. Speech-only rebase requires unchanged manual data.
`CaptionSnapshot` owns manual precedence and overlap review for every output path.
See [scope](phases/MANUAL_CAPTIONS.md) and [handoff](handoffs/MANUAL_CAPTIONS.md).
Earlier schema descriptions below are historical where superseded.


2026-10-24. Source contracts through expanded Pass 1 (#41), based on merged #39. Existing Mac
source/configuration/Transcript APIs remain intact; shared extraction does not
establish Mac feature/rendering parity.

| Owner | Responsibility |
|---|---|
| InkribeCore | Package identity/paths/atomic transactions, rational media time/revisions, processing contracts/gate, resolved style/catalog/reset/access/layout constraints and deterministic motion |
| ProjectRepository actor | Sole native project/media/recognition/usage/export authority; typed validation, adoption/lifecycle/storage, revision checks, source pins and publication |
| ProjectsModel + EditorSessions | Library/import routing and one app-owned editor session/writer per project; retain unsaved project edits in memory across navigation |
| EditorSession | Working document/snapshot, bounded value history, selection/playback, native preview composition and serialized project-save writer |
| ProcessingCoordinator + runtime/lifecycle | Existing transcription/export queues, action authorization, user/system pause, one shared heavy native operation and cancellation/teardown |
| Native adapters | Core Text font matching/shaping/layout/drawing, AVFoundation composition/inference/export, Photos/Files/Share and AppFoundation commerce/themes |

## Persistence and concurrency

Internal UUID.inkribe packages use wrapper 1 and document schema 9 (reads 1–8).
ApplicationSupport/InkribeIOSProjects and existing originals/checkpoints/usage/
exports/cache ownership remain. Relative paths, identity, versions, bounds and
regular-file checks apply on read and publication. Atomic same-directory legacy
adoption preserves valid bytes; collisions/unsafe/future data stay visible.

Editor edits save directly to document.json through the sole repository actor,
with atomic replacement and a previous valid document. One strong writer, normal
600ms debounce and immediate Back/background flush serialize complete project
values. Revision/native-anchor checks remain; only append-only speech publication
may rebase edits. Returned metadata never replaces newer typing.

The app no longer reads, creates or gates editing/actions on editor-draft.json.
The generic shared sidecar API/specifications remain unused by the app; existing
files are untouched. Failed edits and undo/context stay in the app-owned session
across navigation, with one friendly failure and Retry. They are not guaranteed
across process termination before a successful save. No UI forces a discard/reload
choice or blocks leaving Project details. Canonical metadata remains capped at
256MiB. Transcription checkpoints and frozen job requests retain their durability.

EditorHistory contains value-only expected-state commands/coalescing with the
existing 50-command/8MiB budget (one oversized command retained). Native playback,
focus, scroll and entitlement adapters remain separate; snapshot/time lookup is
independent of selection and does not dirty the project.

## Project experience and inherited settings

One import transaction publishes one project with one/multiple ordered sources.
ProjectDetailView is the overview; ProjectEditorView retains the scrolling editor.
Both share one EditorSession and writer, with owner IDs and covered-layer handoff.
Stable clip IDs drive route seeking, caption groups and override membership.

Optional clipSettings (schema 9) stores sparse CaptionStyleOverrides from InkribeCore
and iOS framing/audio overrides. Missing fields inherit current project defaults;
reset removes fields. Preset application intentionally pins its styling. Validate
effective values and clip membership, remap IDs on duplicate, and compare settings
when deciding whether a concurrent revision is append-only speech publication.
Bounded expected-state settings history excludes recognition/media bytes. Optional
ClipSettings.displayName holds the user-facing clip label (trimmed, 1–256 characters);
absence uses the original source name. Name-only records survive pruning and duplicate
remaps, but do not count as caption/media overrides. All settings resets retain names;
explicit original-name restoration removes the label. Naming uses the same writer and
settings history without changing canonical clips, checkpoint matching or the media key.

CaptionSnapshot caches resolved styles/groups. Native drawing selects style by
the cue's clip identity. Media graph applies clip placement and volume events per
inserted audio-lane interval. Caption-only patches do not change the media key.
Project trim and output canvas/30fps remain global. No post-creation sequencing.

## Recognition, media and jobs

Original clips/raw recognition/native timestamps and IDs remain canonical. Bounded
window inference publishes accepted captions incrementally; gap retry preserves
edits and mapping-version identity. Missing word timing uses a real segment-timed
phrase, never fabricated word boundaries. Only complete nonempty recognition
charges, through the existing durable allowance/reservation path.

One retained-range map serves preview/MP4/SRT. Trim does not reduce recognition
work. Preview/export share media composition, orientation/crop, original-audio mix,
caption geometry/typography/effects and edited timing. Schema/model/storage changes
never implicitly re-infer or regroup captions.

JobQueue 1.0.0 retains speech-jobs.json/export-jobs.json and current/legacy adapter
names/IDs/payload defaults. Each queue admits one job, and one shared gate limits
heavy native work total. Native teardown is awaited before records become removable.
Wrapper-1 processing-control.json separates user pause from foreground state; no
new background entitlement. Speech retries always retain model/revision/allowance
checks. Frozen export wrapper 1 captures document/profile/media; workers never read
current catalog defaults or live editor drafts. Per-output leases pin exact URLs;
record removal, orphan recovery and explicit file deletion remain distinct.
Project Exports uses that same inventory for queued/in-place requests. Manifests add
an optional creation date; old requests omit it. Preview and delivery acquire the
same immutable-file lease. Export now follows its durable job without bypassing the
resource gate, user pause or foreground requirement.

## Style and presentation

InkribeCore owns resolved style values and immutable preset (id, version) definitions.
Saved values are authoritative. Format 1 freezes old defaults/layout/motion. Format 2
requires its resolved extension fields; corruption cannot silently default them.
Unsupported future style formats are non-corruption errors, preserving future data
instead of falling back to an older document. Future incompatible wire changes must
also advance the canonical schema. Unknown catalog references retain known values.

Core Text handles installed closest weights, script/emoji fallback, clusters and
bidi. Layout fitting is bounded at six measurements, eight lines and 16,384 UTF-16
units per cue; failure is explicit. Word/phrase-aware motion uses actual original
edited intervals, including trim into a unit. The animated Styles browser retains
one authored sample snapshot/layout, shares the same native renderer, and clocks
only the displayed demo. Samples never enter project storage or recognition. The
old comparison-frame helper is no longer used by the style browsing route; no user
video frame extraction or additional player/decoder is needed for sample browsing.

The sample browser leaves the sole real player in the compact underlying editor.
Detailed customization/export/queue routes detach the covered editor player layer before
another route can present that session's player. Overlay error reporting invalidates
queued callbacks on any newer draw or dismantle and reports initial success too.
Native focus/scroll/layer transitions remain unexecuted acceptance scenarios.

See [CONSOLIDATION](CONSOLIDATION.md), phase handoffs and
[PRODUCTION_READINESS](PRODUCTION_READINESS.md) for evidence limits. Earlier source
records remain in [the archive](archive/before-consolidation/ARCHITECTURE.md).
