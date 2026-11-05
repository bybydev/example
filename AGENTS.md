# Inkribe Working Rules

## Current MP4 frame timing repair — stacked on #62

2026-11-05. The user requests the discussed multi-clip export repair in a stacked
PR from #62 head bb4fd6f9e312746d42ed52b3e156c94a6520d67d, targeting
fix/ios-improvements. Use fix/ios-export-timing. Validate composed frame display
intervals instead of a fixed 67 ms age/source-clip-start check; keep genuine
missing-frame, reader and timestamp failures. Make the shared 30 fps composition
timing explicit and retain bounded sample ownership, black gaps, captions/audio,
cancellation, frozen requests and atomic publication. Add failure-stage/time and
native-error diagnostics. Do not normalize/rewrite originals or change import/UI,
Mac, schema, formats or queue policy. The affected recording has not been supplied;
its exact failing branch remains unconfirmed. Source/diff/publication review only;
no builds/typechecks/tests/fixtures, CI, generation, downloads, native exports or
device/UI execution. See docs/ios/handoffs/MP4_FRAME_TIMING.md. Leave both PRs open
without auto-merge; do not modify the parent branch.

## Current iOS confirmation alerts — stacked on #62

2026-11-05. The user requests a new stacked PR targeting #62's
fix/ios-improvements branch at c26807a048becf9d0e5b9a8e69302dacd01a7fad.
Use fix/ios-confirmation-alerts. Replace every iOS confirmationDialog with a
native centered alert, preserving titles/messages, roles, guarded operations and
presentation owners. The full inventory is 17 sites in 11 iOS files, including
Speech Models under the ignored source folder. Keep explicit Cancel actions,
captured import/model IDs and pending error presentation safe. Preserve Mac,
existing sheets/menus, processing/storage policy and all earlier #62 work.
Source/diff/whitespace/publication review only; no builds/typechecks/tests,
fixtures, CI, generation, model downloads, native/UI/device execution or
deployment. Leave parent and child PRs open without auto-merge. See
docs/ios/handoffs/CONFIRMATION_ALERTS.md. Further work requires the user's request.

## Current issue #63 — stacked caption word effects fix

2026-11-05. The user requests the proposed v1.0 fix in a stacked PR on #62,
starting at 8119966e71db23222a635c6e32316cd682c6635e. Branch
fix/ios-caption-highlighting targets fix/ios-improvements; do not modify the
parent branch. Scope: word-only eligibility for Highlight/Active color/Underline/
Karaoke, word-preserving text correction with stable typing/undo scope, truthful
phrase indicators and the authored Karaoke sample. Preserve raw/native timing,
trimmed-out text and IDs, manual captions, saved projects, existing frozen export
behavior and Mac callers. A default-off shared motion opt-in and shared text
mapping helper are scoped support, with optional frozen-export motion metadata.
Deeper WordMapper/native timing recovery remains deferred; never invent word
timestamps. See docs/ios/handoffs/CAPTION_WORD_EFFECTS.md. Source-only review and
regression-source authoring; no builds/typechecks/tests/fixtures, CI, generation,
model downloads, native processing/exports, UI/device execution or deployment.
Leave both PRs open without auto-merge; await further user-requested changes.

## Current iOS improvements — trimmed caption text correction

2026-11-05. The user requests fixing the reviewed P1 trimmed-caption text bug in
one new PR from latest develop d870b04, targeting develop. Use the generic branch
fix/ios-improvements for this fix and later explicitly requested changes. Keep
caption text edits scoped to the same retained word IDs displayed by the field;
preserve trimmed-out text, native IDs/timing, raw recognition, manual captions,
undo/redo, autosave, preview/export mapping and existing UI. Other review findings
are outside this request. See docs/ios/handoffs/CAPTION_TRIM_TEXT.md. Source-only
review; no builds/typechecks/tests/fixtures, CI, project generation, downloads,
native processing/exports, UI/device execution or deployment. Leave the PR open
without auto-merge and await the user's next requested change.

## Current Photos import repair

2026-11-04. The user authorizes repairing Photos imports stuck at Preparing videos
in PR #59. Request current movie encoding in New Project and Add clips. Both use
one cancellable transfer bridge with a two-minute per-item deadline, one completion
and cleanup of late successful files. Preserve the app-owned file copy, ordered
selection/retry/session guards, video-only creation, working Files path and Music.
Source/API/diff review only; no builds/typechecks/tests, CI or device execution.
The device-specific trigger remains unconfirmed; native regression acceptance is
pending. Keep the PR open targeting develop without auto-merge.

## Current New Project import scope

2026-11-04. In PR #59, the user authorizes video-only New Project creation from
Photos and Files. Remove its direct URL UI/state and creation-only URL helpers.
Require inspected video media both in selection review and before publication;
keep ordered combined imports, cancellation and recovery behavior. Preserve the
editor Music audio importer, existing project compatibility and separate editor
Add clips flow. This supersedes historical audio/URL New Project support only.
No unrelated New Project UI polish, builds/typechecks/tests, CI or device runs.
Keep this PR open targeting develop without auto-merge.

## Current Screenshot Studio implementation

2026-11-04. The user authorizes the five approved static App Store scenes plus
AppFoundation's real paywall screenshot, referencing BYOKchat, in PR #59
`fix/ios-polish` -> develop. Add a Debug-only Settings developer destination and
catalog for the 6.9/6.5-inch iPhone PNG presets. Feature scenes must use fixed data
and pure SwiftUI drawing, with no app/session/media/queue/store dependencies.
Omit campaign app icon/name/footer. Default to the approved light cyan palette;
allow screenshot appearance/background configuration. The paywall alone uses a
lazy, separate nonpersistent screenshotPreview purchase manager and Commerce's
three products, selecting yearly. Update committed iOS source membership without
running project generation. Preserve all earlier changes. Source/diff review only;
no native builds/typechecks/tests, CI runs, models or device/export execution.
Keep the PR open without auto-merge. See docs/ios/SCREENSHOT_STUDIO.md.

## Current Xcode Cloud setup

2026-11-04. The user authorizes the discussed Xcode Cloud setup in PR #59,
`fix/ios-polish` -> develop, following Spokio and ReadAloud. Commit the generated
project/shared schemes/lockfile and required iOS Info.plist, add executable
post-clone/archive-verification hooks, and document the manual Apple setup.
Read `IOS_MODELS` directly: unset/empty defaults to download, and only bundled
includes Small multilingual and enables the existing bundled-only behavior.
No xcconfig is needed. XcodeGen remains authoritative; Cloud adjusts only iOS
model resources/flags after package resolution. Preserve earlier Home fixes.
Use source/syntax review; native builds/tests/model downloads and Cloud/device
acceptance remain unverified. Keep the PR open without auto-merge.

## Current iOS improvements PR

2026-11-02. The user approves the ellipsis-menu assessment and requests updating
this same PR. Keep Rename, Duplicate project and Project info in that order, then
a separator and confirmed destructive Move to Trash. Remove the informational
save-status row and redundant Expand preview, Queue and Media tools entries.
Preserve save errors/retry in editor/Project info, playback fullscreen, the bottom
Media action and Home Queue. Remove only the now-unused editor Queue sheet/state/
opener and menu-status helper; keep incoming queue project routes and Export/
Captions dismissal handoffs intact. All earlier #58 fixes and source-only rules
remain; no unrelated feature, processing/queue policy, CI, test or merge work.

2026-11-01. The user requests a native, theme-aware Project info Form, grouped
as Project, Original media and Storage, with Status only for existing errors.
Use read-only title/metadata rows, theme surface backgrounds/separators and the
existing themed sheet background. Storage accounting and its confirmed thumbnail
cleanup use native section rows and an explanatory footer. Preserve missing-media
relink, save/status recovery and all protected files. The sheet must not rename
titles: remove its title field/focus/keyboard toolbar and route the separate
editor Rename action and rename-on-open fallback to a native Save/Cancel alert
using the existing session title setter/writer. Keep the dedicated Clips action,
all earlier #58 fixes and unrelated UI/data/processing behavior. Source-only rules
remain. See docs/ios/handoffs/PROJECT_INFO_FORM.md.

2026-11-01. The user now explicitly authorizes the main editor transport layout:
Start/Play-Pause/End, flexible space, current/total time, flexible space, preview
speed and Fullscreen. Remove the redundant Clip X of N button/helper, preserving
the dedicated Clips action and its selected-clip routing. Use icon-only transport
with full 44-point targets, a compact speed menu and the existing narrow/large-text
two-row fallback. Boundary jumps pause at zero/the final 30 fps preview frame;
Play at that final frame restarts. The user's sizing follow-up enlarges speed
text to title3/medium and reduces the fullscreen glyph to body for visual balance;
Start/Play/End retain title3 and every control retains its 44-point target.
Corrected speed choices 0.5/1/1.25/1.5/2 use only the shared
editor AVPlayer, persist across pause/resume and native fullscreen in memory,
and never change saved media timing, history or exports. Observe native default/
positive rate changes and remove both observers on session stop. Other sheet transports keep
their existing controls; preserve all earlier #58 fixes. Source-only restrictions
remain. See docs/ios/handoffs/EDITOR_TRANSPORT.md for source evidence.

2026-11-01. In this same PR #58 the user also explicitly authorizes replacing
the editor's horizontal scrolling actions with five equal-width columns across
the available bottom bar. Keep Clips/Captions/Style/Media/Export in that order,
the current icon/label/color/height/insets and existing sheet actions/disabled
states. Each label expands equally and its entire column is tappable. Remove the
horizontal ScrollView and fixed intrinsic button widths; this is layout-only.
Preserve the fullscreen fix and all other editor behavior. Source/diff/whitespace
review only under the existing no-build/no-test/no-native/UI execution rules.

2026-11-01. The user requests a new generic fix/ios-improvements branch from
latest develop 5910c9c, targeting develop, for this fullscreen caption fix and
later explicitly requested small changes. Keep work in this PR until told
otherwise; leave it open without auto-merge. Discussion alone does not authorize
other edits. EDITOR.NATIVE_FULLSCREEN now owns an AVPlayer periodic caption clock
inside the native presenter rather than depending on the covered SwiftUI editor's
representable updates. Read the current session snapshot and actual player time,
preserve readiness/held-frame pairing and native controls, and remove/invalidate
the clock on replacement, dismissal and teardown. Completed MP4 previews keep
burned-in captions and receive no caption observer. No extra player, temporary
export, renderer/schema/queue/Mac/commerce/CI changes. Existing source-only
restrictions remain: no builds/typechecks/tests/fixtures, CI, generation/models,
native processing/exports, UI/device execution or deployment. See the follow-up
in docs/ios/handoffs/NATIVE_FULLSCREEN.md; runtime acceptance remains unverified.

## Current queue experience authorization — pass 4

2026-11-01. The user's next-pass signal authorizes final JOB.INTEGRATION in PR #57,
feat/ios-queue-experience -> develop, extending 2923c08b. Review all prior queue
actions/capacity, navigation/presentation owners, background permission/resource
changes, pause/cancel/retry, retention/delivery and reopening paths; fix scoped
integration defects only. Source fixes keep lifecycle observation on the stable
navigation owner, distinguish true background return from temporary inactivity,
wait for settled export inventory before one-time focus, respect subsequent user
actions, and revalidate projects after sheet dismissal with Job-details fallback.
Remove obsolete global-cancellation helper/correct stale engine ownership comment.
Preserve queue/editor design, 1/3 JobQueue limits, explicit-only continued-task
submission, GPU fallback, stores/schema/allowance/frozen output/native ownership,
shared packages/Mac/models/commerce/CI behavior. Apply QUEUE_EXPERIENCE phase/handoff.
All four source passes may be complete; compilation/native/UI acceptance remains
unverified. No builds/typechecks/tests/fixtures, CI, project/plist generation,
models, native processing/exports, UI/device execution, signing or deployment.
Keep PR open without auto-merge; no new feature or merge is authorized.

## Current queue experience authorization — pass 3

2026-11-01. The user's next-pass signal authorizes JOB.BACKGROUND in PR #57,
feat/ios-queue-experience -> develop, extending 7d4b06fd. Apply QUEUE_EXPERIENCE
phase/handoff under docs/ios. Adapt the inspected Spokio iOS continued-processing
pattern: explicit enqueue/retry/recovery/Resume requests, system progress, expiration
and durable foreground recovery. JobQueue still owns execution (speech 1, exports 3).
Track speech/export execution grants independently so GPU restrictions/expiration or
model switching cannot unnecessarily stop the other kind. CPU transcription and
SRT-only exports use default resources; export work containing MP4 requires supported
background GPU access. Unsupported/denied GPU access keeps export work foreground-
only, without a new renderer or custom scheduler. Enable iOS processing metadata and
GPU entitlement in source configuration; do not generate a project or plist.
Preserve user pause, cancellation/awaited native teardown, accepted caption progress,
allowance, frozen inputs/results, delivery and all pass-2 design/navigation. Force
quit cannot guarantee completion; interrupted MP4s restart from frozen input as before.
No auto-submission on launch/foreground return, model/schema/package/Mac/commerce/CI
changes or unrelated editor work. Source-only: no builds/typechecks/tests/fixtures,
CI, generation/models, native processing/exports, UI/device execution or deployment.
Keep #57 open without auto-merge; pass 4 awaits a separate signal.

## Current queue experience authorization — pass 2

2026-11-01. The user's next-pass signal authorizes pass 2 in existing PR #57,
feat/ios-queue-experience -> develop, extending faa33e8c. Implement only JOB.QUEUE_UI
and JOB.PROJECT_ROUTE in phases/QUEUE_EXPERIENCE.md and its handoff under docs/ios.
Use the inspected Spokio iOS plain list, outlined icon/count scopes, compact status/
progress/chevron rows, toolbar sorting/type filter and swipe/context actions. Move
retained exports/storage explanation to their own destination; show only relevant
notices. Row tap opens project Captions or its exact export activity/file, with
Job details available from context menu and as unavailable-project fallback.
Presentation owners must dismiss their own sheets before forwarding navigation;
reuse the current editor for its own project. Preserve file delivery protection,
pass-1 actions/concurrency, job identities/storage, engine/allowance/frozen outputs
and all unrelated editor design. Background work remains pass 3 and final review
pass 4; both await separate signals. No shared-package/schema/Mac/model/commerce/
CI work. Existing source-only execution restrictions remain. Keep #57 open without
auto-merge; no automatic next pass or merge.

## Current queue experience authorization — pass 1

2026-11-01. The user starts pass 1 of four in one new PR from develop b51e1b95,
branch feat/ios-queue-experience, targeting develop. Apply
phases/QUEUE_EXPERIENCE.md and handoffs/QUEUE_EXPERIENCE.md under docs/ios.
One Transcribe action and one Create Export action always use the existing durable
JobQueue stores; remove Export now versus Queue export and keep project-local
progress available after reopening. JobQueue alone owns execution capacity:
transcription 1, exports 3, including current and legacy job types. Remove the iOS
call to the shared single-operation gate; keep native cancellation/teardown tracking,
shared speech engine, allowance, frozen inputs/results and delivery protection.
No scheduler, package/schema/model/commerce/Mac/CI changes or unrelated editor design.
The agreed Queue UI/deep links are pass 2, continued background processing is pass 3,
and final integration review is pass 4; each awaits a separate signal. Pass 1 stays
foreground-only and must not promise background completion. This supersedes the
historical one-heavy-operation/two-export-action requirements only for this scope.
Source-only: no builds/typechecks/tests/fixtures, CI, project generation/models,
native processing/exports, UI/device execution or deployment. Leave the PR open
without auto-merge; no automatic next pass or merge.

## Current timeline clip trimming authorization

2026-10-31. The user explicitly requests implementing the discussed timeline-only
clip trimming in a stacked PR on #55, starting at 381b0d2b and targeting
feat/ios-media-form. Branch feat/ios-timeline-clip-trimming. Select a timeline clip,
drag its edge handles, audition the boundary in the existing main preview and
save one undoable edit on release. Restore native footage by dragging outward;
close trimmed output gaps and keep all captions aligned. Remove Media trim UI.
Preserve saved legacy project trims and frozen outputs. Schema 13 adds optional
source-clock clip trims; original clips/native word/source clocks stay unchanged.
Use one derived piecewise output map across preview/MP4/SRT/seeking. No new player,
engine, inference, allowance, shared-package/Mac/model/commerce/CI or unrelated
design work. Read phases/CLIP_TRIMMING.md and handoffs/CLIP_TRIMMING.md under docs/ios.
Existing source-only restrictions remain: no builds/typechecks/tests/fixtures,
CI/generation/downloads, native processing/exports or UI/device execution. Keep
parent and stacked PR open without auto-merge; never modify the parent branch.

## Current Media Form authorization — pass 2

2026-10-31. The user's next-pass signal authorizes the final source integration
review in PR #55, feat/ios-media-form -> develop, extending bb0d1b11. Review scope,
resets, cancel/dismissal, stale/save/history/reopen and shared preview/export use.
Fix scoped defects only: sheet-owned save cancellation/late completion; save without
waiting on preview preparation, with interrupted-preview recovery; one settings
rewrite/sort; and dismissal reconciliation of speech progress. Preserve the approved
Form, scopes and every other editor design. Both source passes may be complete;
compilation/native/UI acceptance remains unverified. Read MEDIA_FORM phase/handoff.
Existing source-only restrictions remain, including no builds/typechecks/tests,
fixtures, CI, generation/downloads/native processing/exports, UI/device execution
or deployment. Leave #55 open without auto-merge; no next feature or merge.

## Current Media Form authorization — pass 1

2026-10-31. The user starts pass 1 of two in a new feat/ios-media-form PR targeting
develop. Scope: a large native Form like Style with no preview/transport; the first
row selects Project or a numbered clip and changes all sections below it. Project:
aspect ratio, whole-project trim and original-audio master mute. Clip: framing,
zoom/position, volume and standard resets. Remove inheritance/default/reset-to-project
UI; preserve existing effective clip values. All scopes share one local Cancel/Done
transaction, one durable settings Undo entry and existing preview/MP4 integration.
No other editor design changes, schema/wrapper/shared-package/Mac/model/commerce/CI
work. Read phases/MEDIA_FORM.md and handoffs/MEDIA_FORM.md under docs/ios.
Pass 2 awaits a separate user signal. Source-only restrictions remain: no builds,
typechecks/tests/fixtures, CI/generation/downloads, native media processing/exports,
UI/device execution or deployment. Leave the PR open without auto-merge.

## Current music layer authorization — pass 3

2026-10-31. The user says "next pass" after pass 2 and authorizes the final music
integration review in existing PR #54, feat/ios-music-layer -> develop, extending
73a2323c. Review one-file ingress/replacement/removal, stale/cancel/failed-save
paths, reopen/duplicate/Trash/history, duration changes, mute states and shared
preview/frozen-export consistency. Fix scoped integration defects only; preserve
the approved layout, controls-only Music sheet and all other editor design.
Source fixes cover actual-sheet-owned draft cleanup across child Files pickers,
late save/cancellation lifetime, rational repeat budget/boundaries, clamped native
fade ranges, stable fade-slider bounds, effective-zero-volume feedback and copied
music readability/composability/protection preflight. No other feature expansion,
new player, schema/wrapper/dependency/engine/model/commerce/Mac/CI work.
Read MUSIC_LAYER phase/handoff. Source-only restrictions still prohibit builds,
typechecks/tests/fixtures, native processing/exports, CI, generation/downloads,
UI/device execution or deployment. Keep #54 open without auto-merge. All three
passes may be source-complete; actual compilation/device/audio acceptance remains
unverified. Do not start another feature or merge/release automatically.

## Current music layer authorization — pass 2

2026-10-31. The user says "next pass" after pass 1 and authorizes pass 2 in existing
PR #54, feat/ios-music-layer -> develop, extending b345f71c. Implement only the agreed
MUSIC.TIMELINE / MUSIC.SHEET: Video -> Music -> Captions, leading unboxed original
mute, compact square music/caption buttons before time zero, empty Add music lane,
real bounded waveform/loop indicator and controls-only Music sheet. Keep the main
preview/transport/actions/theme/navigation and caption gestures otherwise intact;
the added row alone changes reserved timeline height. No new preview/transport in
Music. Files/replace selections and all controls stay local until Done publishes
one saved Undo operation; Cancel/swipe discards staging. This explicitly authorizes
the narrow pass-1 transaction adaptation needed for that sheet. Keep schema 12,
shared preview/MP4 graph, speech/allowance and frozen outputs. No unrelated design
changes. Pass 3 still awaits a separate signal. Existing source-only execution
restrictions apply; leave #54 open without auto-merge. Read MUSIC_LAYER scope/handoff.

## Current music layer authorization — pass 1

2026-10-31. The user approves one new PR from develop 723f333 targeting develop,
branch feat/ios-music-layer, and explicitly starts pass 1 of three. Implement
MUSIC.FOUNDATION: one project-level audio file, coordinated Files ingress/owned
storage, replacement/removal, source-section trim, output-clock offset, loop-to-fit,
volume/mute, endpoint fades, atomic saved controls, bounded Undo/Redo and one shared
preview/MP4 composition. Add an independent original-audio master mute that keeps
per-clip volumes. Music never extends duration, enters transcription or consumes
speech allowance. Preserve frozen exports, duplicate/Trash/relink and old documents.
Schema 12 reads 1–11; package/export/job wrapper versions remain unchanged.

The settled next-pass UI is Video -> Music -> Captions, leading unboxed original
mute and compact square music/caption controls, an empty Add music lane, waveform,
and a controls-only Music sheet with Done; no preview or transport in that sheet.
Pass 1 adds no UI, entry buttons, row reordering or other design changes. Pass 2
requires the user's next signal. Any unrelated change requires asking first.
Read docs/ios/phases/MUSIC_LAYER.md and handoffs/MUSIC_LAYER.md. Existing source-only
restrictions apply: no builds/typechecks/tests/fixtures, CI/generation/models, native
media processing/exports, UI/device execution or deployment. Leave the PR open with
no auto-merge. This explicit scope supersedes historical exclusions of music only
for this single-file soundtrack; no other editor expansion is authorized.

## Current native fullscreen player authorization

2026-10-29. The user explicitly requests the discussed replacement in a new stacked
PR. Branch feat/ios-native-fullscreen-player starts at PR #52 head 3f9b8107 and
targets feat/ios-style-sheet-grid, not develop. Keep both PRs open without auto-merge
and do not update the parent branch. Scope: EDITOR.NATIVE_FULLSCREEN and
EXPORT.NATIVE_PREVIEW. Present AVPlayerViewController itself for both editor expand
entry points and every ExportResultView video preview in Export/Queue/retained files.
Reuse the editor's AVPlayer/composition with live captions in contentOverlayView;
no temp output, extra editor player or export/inference work. Completed-file previews
use their own immutable MP4, without a second caption overlay. Retain delivery leases
through native dismissal/failure/teardown, frame ownership/held-frame return, actual
clock/play-state synchronization and pause on dismissal/inactivity. Native controls
replace the custom navigation/Done/transport/timeline/history screen. Inline previews,
Style/sample/form, caption/media edits, timing/history/persistence, queue/jobs/frozen
outputs, schema/packages/native renderer/Mac/models/allowance/commerce/icons stay.
PiP and external playback are disabled during these in-app previews because live
captions and delivery ownership are tied to the presentation; restore player policy
on close. No new background playback entitlement or media pipeline.

This explicit request authorizes this implementation only. Discussion of another
problem or preference is not permission to edit; wait for an implementation command.
Source-only: no builds/typechecks/tests/fixtures, CI/generation/models, native media
execution/exports, UI/device execution or deployment. Read phases/NATIVE_FULLSCREEN.md
and handoffs/NATIVE_FULLSCREEN.md under docs/ios. Runtime acceptance is unverified.

## Current Style form authorization (PR #52)

2026-10-29. The user approves the latest native-form mockup and requests updating
current PR #52, feat/ios-style-sheet-grid -> develop. This supersedes its first
actual-project preview, category tabs and caption scope controls. Use the same
sample background, text and timing as the template tiles, with live rendering of
all draft appearance changes and only an overlaid play/pause button. Native form
sections show labels left and selected/compound values right; small menus, inline
Size, and pushed Font/Animation/Spacing/Outline/Background/Shadow/Text-layout forms.
The template row still pushes the lazy grid. Cancel discards and Done atomically
saves one undoable project-wide caption style. No per-clip caption appearance,
inheritance indicators or caption reset-to-project controls remain.
The user's follow-up keeps the live sample preview only on the root Style form;
pushed pickers/detail forms contain settings only. Grid tiles remain static.
The shared sample uses three meaningful sentences as sequential timed cues.
The latest editor-controls follow-up moves Export into the bottom action bar as
an ordinary fifth button (Clips/Captions/Style/Media/Export), tightens spacing to fit
standard iPhone widths, and moves main-editor Undo/Redo to the top toolbar. Remove
their main playback-row/menu duplicates. Existing sheet/fullscreen history remains.
This supersedes historical toolbar-only Export requirements for the main editor.
The next follow-up removes the visible Timeline heading/header and places its
Clip X of Y button in the main playback row, before fullscreen where Undo/Redo
used to be. Preserve selected-clip numbering and the same Clips-sheet action.
The next follow-up removes the main navigation title and save-status subtitle;
keep Back, Undo/Redo and the ellipsis, with project naming/status in existing menus.

The latest follow-up keeps caption placement in Style: project-wide Top/Center/Bottom
and inline precise X/Y under Layout, previewed using the live sample and saved only
with Done. Media has no caption placement controls; keep per-clip framing/audio.
Live captions and newly frozen exports use one project style. Read compatibility
for existing clip-caption fields and already-frozen requests is retained without
changing document/request versions; a successful appearance/placement edit clears
obsolete caption overrides while keeping clip names/media. No new catalog,
saved-template library, shared package, native renderer, schema, Mac, speech/model,
allowance, queue, purchase, icon or CI work. Source-only restrictions remain: no
builds/typechecks/tests/fixtures, CI/generation/downloads/native processing/exports,
UI/device execution or deployment. Keep #52 open without auto-merge. Current scope
and handoff are docs/ios/phases/STYLE_SHEET.md and handoffs/STYLE_SHEET.md.

## Current unified Style sheet authorization

2026-10-29. The user approved the revised Style mockup and requests one new PR
from latest develop b28beebb, targeting develop. One bottom Style action opens a
large sheet with the actual preview/transport, selected template row and inline
Text/Colors/Backdrop/Layout/Position/Motion customization. Tapping the template
row natively pushes a lazy templates grid. Selecting a template changes the local
sheet state and returns to Style; native Back alone does not select anything.
Cancel or swipe dismissal discards uncommitted caption settings. Top-right Done
publishes one durable, undoable edit only after saving succeeds. A failed Done
keeps the local choices and permits retry or Cancel without adopting them.

This supersedes the older carousel/explicit-Apply/separate-Customize requirements
for V1.STYLE/PRESETS. Keep the existing ten-template catalog, renderer, project
inheritance/sparse clip overrides, Pro policy, preview handoff/single player,
recognition/timing, frozen exports, model/queue/commerce, schema and Mac behavior.
No saved-template library or catalog expansion is authorized. Source-only: no
builds/typechecks/tests/fixtures, CI/generation/models, native processing/exports,
UI/device execution or deployment. Leave the PR open without auto-merge. See
phases/STYLE_SHEET.md and handoffs/STYLE_SHEET.md under docs/ios.

## Current edge-to-edge timeline authorization

2026-10-28. The user confirmed removing the editor timeline's inherited 12-point
side gutters in PR #50. Move horizontal padding to preview, playback controls,
timeline header, errors and caption prompts so the ruler/tracks span the editor
width. Preserve centered-playhead start/end scroll space, scrub/pinch/timing
gestures, thumbnail/caption geometry and preview dimensions. Layout only; retain
all caption, Graphite and preview-handoff work. Source-only checks; no builds,
typechecks/tests/fixtures, CI, generation or UI/device execution. Keep #50 open
without auto-merge; future edits still require a confirmed concrete plan.

## Current Graphite theme authorization

2026-10-28. The user confirmed adding Graphite in existing PR #50, targeting
develop. Graphite is Free, always dark, immediately after Paper, with accent
#279ED2. The user subsequently confirmed revising the flat design to Midnight's
translucent surface/elevated/border tokens, subtle shadows and layered background
with restrained blue lighting. Keep the charcoal base and blue accent; remove
the special flat-background adapter and reuse AppThemeBackground for all themes.
Paper remains the default/fallback; existing premium themes retain their palettes
and Pro access. Keep theme persistence, picker and access in AppFoundation 1.6.4;
the Graphite palette is iOS app-owned. Update the
Free comparison to Paper and Graphite. No shared-package, Mac, icon, schema,
editor/playback or purchase-product changes. Source-only checks; no builds,
typechecks/tests/fixtures, CI, generation or UI/device execution. Keep #50 open
without auto-merge. Other edits still require a concrete plan and confirmation.
PR #51's preview fix was user-validated and squash merged into #50 as 35b29af.
Earlier instructions to leave #51 open and Paper as the sole Free theme are
superseded. See docs/ios/handoffs/GRAPHITE_THEME.md.

## Current preview handoff authorization

2026-10-28. The user confirms the proposed fix for the covered editor turning black
when sheets open, in a new stacked PR. Branch fix/ios-preview-handoff starts at
PR #50 head 5c9f9eb and targets feat/ios-contextual-caption-editor, not develop.
Preserve a current frame before transferring the one shared player's live layer;
keep covered previews mounted with a still and matching caption clock/snapshot,
then reveal returning live video only when its layer is ready. Preserve all #50
row selection/seek/top-left Edit caption, native push/pop, Captions preview/controls,
highlight-without-auto-scroll, styles, timing/history/saving and independent exports.
No extra player, asset reload/decode pipeline, schema, renderer implementation,
speech, queue/commerce/model/Mac or CI changes. Source-only checks; no builds,
typechecks/tests/fixtures, generation/models, native processing/exports, CI or
UI/device execution. Leave both PRs open without auto-merge. Read PREVIEW_HANDOFF
under docs/ios/phases and handoffs. This request confirms only the discussed fix;
other edit plans still require the user's confirmation before implementation.

## Current contextual caption editor authorization

2026-10-28. The user authorizes only replacing the top-level Timing tool with a
contextual Edit caption editor in one new PR from latest develop, targeting develop.
Second tap on a selected timeline caption or the selected transcript row's top-left
Edit caption button opens the same editing content. Keep caption/word correction, split/
merge, exact timing, manual deletion, existing history and automatic saving. The
contextual editor has no player, scrubber or transport. The latest correction
requires a native push from Captions; Back/swipe-back/Done returns to the same list
and scroll context, without another sheet. Timeline entry remains a sheet whose
Done/dismissal returns paused just before the edited caption with selection retained.
The latest user correction also gives Captions a video preview above its list,
play/pause and Undo/Redo, with no scrubber/timeline. Always highlight the current
playback cue without selecting it or auto-scrolling. Remove the optional follow
toggle; retain manual list scrolling and contextual push/pop. Reuse the sole player
and existing renderer, handing off its visible layer across sheets/navigation.
The latest confirmed row plan preserves tap-to-select/highlight/seek. The list has
no inline text editing or Split / Words button. Only the selected row's existing
top-left Edit caption button pushes editing; text/words/split/merge/timing/manual
deletion stay in that editor. Before future edit work, explain the concrete plan
and wait for the user's confirmation. This request confirms only this row change.
Keep all other consolidation proposals deferred until the user's next signal.
No schema, native timing/IDs, renderer, speech, queue/export, commerce, model, Mac or
CI changes. Source-only checks; no builds/typechecks/tests/fixtures, generation,
native processing/exports, CI runs or UI/device execution. Leave the new PR open
with auto-merge disabled. Read phases/CONTEXTUAL_CAPTION_EDITOR.md and its handoff.
Earlier implementation authorizations below are historical where superseded.

## Current direct editor and sheets authorization

2026-10-28. The user requests **pass 3** in existing PR #49,
feat/ios-editor-sheets → develop, extending pass-2 head 014ad963. Complete native
clip drag reorder and source consolidation while preserving passes 1–2. Reorder
is local in the large Clips sheet until Save, with Cancel, stable IDs, expected
state, one durable undoable commit and no-op rejection. Project trim remains a
window at its current clock positions; reordered footage inside it can change.
Keep native source intervals/raw IDs, manual/native captions, clip names/settings,
accepted coverage/retry/allowance, preview/media/audio/SRT order, selection and
original files aligned. Do not automatically transcribe or affect frozen exports.
Retain direct editor/opening cancellation, Project info/storage, numbered timeline,
plain ellipsis and toolbar-only Export sheet/history. Remove unused clip-strip UI;
background export artwork must retain deletion leases without blocking dismissal.
Schema stays 11 (reads 1–10); no shared-package/Mac/native renderer/engine/commerce/
model-policy/CI changes. Active project transcription still excludes final graph
transactions. Read docs/ios/phases/EDITOR_SHEETS.md and handoffs/EDITOR_SHEETS.md.
Source-only: no builds/typechecks/tests/fixtures, CI, generation/models, native
processing/exports, UI/device/accessibility execution or deployment. Keep PR #49
open without auto-merge; implementation completion is not runtime acceptance.

## Current timeline editor authorization

2026-10-27. The user requests **pass 3** of issue #47 in existing PR #48,
`feat/ios-timeline-editor` → develop, extending pass-2 head `95628a7`.
Implement caption block move/edge-resize, explicit word timing rules, one undoable
commit per completed gesture, autosave, overlap/bounds/concurrency checks and final
gesture integration. Keep the four-area editor, action sheets, stable preview,
cancellable opening, real multi-clip frames/ruler/scrub/playback/pinch selection.
Preserve native timestamps/IDs, raw results, hidden trim portions, media/clip
identity, shared engine, queue/frozen outputs, allowance/Pro, home and Mac behavior.
Read docs/ios/phases/TIMELINE_EDITOR.md and handoffs/TIMELINE_EDITOR.md.
No schema change, clip sequencing, transitions or music tracks. Source-only:
no builds/typechecks/tests/fixtures, CI, generation/models/native processing,
UI/device execution or deployment. Keep PR #48 open without auto-merge.
Earlier scope/PR instructions below are historical where superseded.

## Current iOS library organization pass

2026-10-27. The user approved implementation in existing PR #46,
`fix/ios-improvements` → develop. Replace the home media-type strip with All,
Favorites, custom folders and Trash, using Spokio iOS's outlined icon/label/count
pills. Remove the Projects header count; keep Sort and Options close to the label.
The floating + offers New Project and New Folder. Add folder create/rename/delete,
project membership/favorites, and Trash restore/confirmed permanent deletion.
Deleting a folder preserves its active and trashed projects. New projects created
within a folder join it. These organization features are Free.
Keep the earlier hero, subtitle and crown/settings toolbar. Paper is first,
default and the only Free iOS theme; other themes require Pro. Preserve captions,
revision/job/allowance contracts, frozen exports and Mac behavior. Library metadata
belongs to ProjectRepository independently of project document revisions.
Source review only; no builds, typechecks, tests, generation, CI or UI execution.
Keep the PR open without auto-merge. See handoffs/LIBRARY_ORGANIZATION under docs/ios.

## Current shared speech engine and active model

2026-10-26. In PR #44 the user explicitly supersedes per-job/original-model
binding: the whole iOS app has one shared engine and active model. Settings alone
exposes its name and choice. Switching requires confirmation, cancels all queued
and running transcription tasks plus model downloads, waits for speech teardown, and
then changes the active model. Exports, including preparation, queue admission and
running exports, are unaffected by model switching. New, restored and resumed
transcription jobs use that active model; old payload model fields are decode-only compatibility data. Retain saved
captions, edits, accepted raw intervals and completed exports. Resume unfinished
ranges with the active model without overwriting earlier accepted edits. No new
migration or original-model UI. Existing source-only execution restrictions and
open-PR/no-auto-merge requirements remain. This overrides prior pinned-model rules.

## Current free captioning allowance

2026-10-26. The user requests raising Free to 30 minutes/week in the current PR
#44, feat/ios-manual-captions → develop. This supersedes the earlier 5-minute
allowance. Preserve existing usage/reservations and weekly reset/accounting;
Pro remains unlimited. Keep allowance and comparison/upsell copy consistent.
User-facing completion checklists should cover requested implementation work,
without adding build or device validation items.

## Current manual-caption authorization

2026-10-26. The user requests implementing the discussed Add missing caption
feature in a new PR from latest develop f0eb80c targeting develop, branch
feat/ios-manual-captions. This authorizes the discussed UI and necessary source
integration: text/user timing, saving/reopen, undo/redo, styles/trim/MP4/SRT,
duplication and preservation during transcription retries with explicit overlap
review. See docs/ios/phases/MANUAL_CAPTIONS.md and handoffs/MANUAL_CAPTIONS.md.
Keep native recognition/IDs/timing, allowance, multi-clip projects, automatic
saving, independent outputs and Mac behavior. Schema 10 reads 1–9; wrappers stay.
No builds/typechecks/tests/fixtures, CI setup/triggers/runs, generation/models,
native inference/exports, UI/device execution or deployment. Source checks only;
leave the PR open without auto-merge. Earlier phase authorizations are historical.


## Current animated Styles sheet authorization

The user also authorizes polishing the supplied editor screenshot in this PR:
bounded content width/insets, compact playback/tool controls, hidden redundant
single-clip navigation and compact multi-clip cards with readable labels. Keep
single-clip rename reachable and do not change source names, timestamps, rendering
or persistence. Existing no-execution restrictions and sheet-layout rules remain.

2026-10-26. The user approved the animated-demo Styles sheet and requests one new
PR from latest develop (81b8207), branch feat/ios-animated-style-sheet, targeting
develop; leave open without auto-merge. Scope is V1.PRESETS/V1.STYLE presentation:
sample carousel, explicit Apply and project-default/clip scope. Latest user
corrections require a large-only sheet and no editor-preview movement: preserve
the scrolling workspace, active tool, scroll identity and expanded preview state
when opening it. Do not replace the editor with a compact preview. Keep multiple clips, the existing
catalog/renderer, recognition/timing, Pro gates, overrides, undo, saving and Mac
behavior. No builds/typechecks/tests/fixtures, CI/generation/models/native exports
or UI/device execution. See docs/ios/handoffs/ANIMATED_STYLES.md for source evidence
and pending acceptance. Prior completed phase instructions below are historical.

## Current issue #41 implementation authorization

The user authorizes the entire expanded Pass 1 in a new PR from latest develop,
branch `feat/ios-pass1-project-experience` targeting develop, left open with no
auto-merge. This supersedes issue #41's planning-only status and old PR #39 holds.
Read docs/ios/phases/PROJECT_EXPERIENCE.md and handoffs/PROJECT_EXPERIENCE.md.
Implement one-project creation (one/multiple files; no separate-project import),
project details and multi-clip editor, sparse per-setting clip overrides/reset,
project exports with queued/in-place generation and preview/save/share, and simple
automatic saving. The user approved the settled UI through this conversation.
The user also authorizes clip renaming in this same PR: visible details/editor menus,
persisted labels, original-name restoration and undo; settings resets preserve names.
Preserve native recognition/IDs/timing, allowance, originals, independent frozen
outputs and Mac behavior. Schema 9 reads 1–8; package/job/checkpoint wrappers remain.
No builds/typechecks/tests/fixtures, CI setup/triggers/runs, generation, model
downloads, native inference/exports, UI/device/accessibility execution or deployment.
Source/diff/whitespace/publication review only; user validates afterward. Finish
with a marked todo list distinguishing source integration from runtime acceptance.
Earlier scope/PR instructions below are historical where superseded by this task.


## Current project-saving simplification

The user rejects a separate draft/recovery workflow and asks for a friendly single
project experience in PR #39. This supersedes earlier editor-journal requirements:
remove the app's editor sidecar dependency, readiness checks, discard/reload flows
and sidecar-driven library/action gates. Save directly through the sole repository
with the existing serialized writer and atomic/revision checks; retain failed edits
in app-owned memory across navigation. Show one friendly save failure with Retry.
Rename remains accessible. Do not add legacy migration work or delete existing
files. Transcription checkpoints/partial publication, processing queues, frozen
exports, originals, undo/access and Mac behavior remain protected. No builds/tests,
CI/generation/models/native/UI/device execution or deployment; leave PR open.

## Current consolidation authorization

The user requests a consolidation pass across issue #38's five source passes in
existing PR #39 → develop. Fix supported integration defects and duplication;
consolidate current docs while preserving historical evidence. Read docs/ios/
CONSOLIDATION.md and current entry points. Do not expand feature scope, alter
working transcription/data/access contracts or run restricted execution. The
source-only checks and open/no-auto-merge rules below remain in force.

## Issue #38 — current production passes 1–5 authorization

The user explicitly authorized pass 5 in existing PR #39
(`feat/ios-project-packages` → develop), retaining passes 1–4. Implement versioned
shared style/catalog/resolved values, ten distinctive looks, native renderer weight/
shadow/background/layout/motion extensions and pass-4 browser/customization/reset/
access integration, compatibility and supported production source fixes. Read
phases/CAPTION_PRODUCTION, handoffs/CAPTION_PRODUCTION and PRODUCTION_READINESS
under docs/ios plus prior pass records. Preserve successful transcription/partial
publication, raw/native IDs/timing, corrections/undo/allowance, packages/jobs/frozen
outputs/journals and current Mac source/config/Transcript APIs. Canonical schema 8
reads 1–7; package/job/checkpoint/request wrappers remain stable. Opening legacy
looks does not resolve current catalog defaults. Keep the approved one-scroll
editor and iPhone-only support. Routine settled UI details are authorized after
the short plan. Leave PR open without auto-merge. Production acceptance remains
pending; do not manufacture device/footage/rendering/store evidence.

No builds, typechecks, tests, fixture execution, CI setup/triggers/runs, project
generation, model downloads, native inference/exports, deployment or UI/device/
accessibility execution. User tests afterward. Meaningful regression source may
be authored but must not be executed. Source integration is not production
verification. Earlier pass-only/PR holds below are historical for this scope.

## Issue #36 — current authorization

The user requests updating #36 and implementing the approved editor visualization in existing PR #37 (fix/ios-window-recovery → develop, baseline 525fae4), left open without auto-merge. The latest explicit implementation request supersedes the earlier complete-only publication/schema-v5 restriction: publish available captions incrementally, keep transcript/footage editable and exportable with inline missing ranges, and retry gaps while preserving edits. Schema v7 records coverage/mapping versions and reads v1–v6. Use bounded window recovery and versioned sidecars; only complete nonempty recognition charges. Scope includes the existing editor/transcription/export surfaces; preserve Mac/shared runtime, purchases, originals, native/manual anchors and legacy empty recovery. Read docs/ios/phases/TRANSCRIPTION_RECOVERY.md and handoffs/TRANSCRIPTION_RECOVERY.md. No builds/typechecks/tests, workflow dispatch, generation, weights, deployment or UI/device validation. Routine implementation choices for the approved UI and partial publication are authorized. The user subsequently reported an empty transcript after 1 of 4 windows on device. Correct the strict word-timing gate: preserve native segment-timed phrases when precise word timing is unavailable; never invent word boundaries. Retain mapping 1 for existing identities and record mapping 2 per new accepted core (schema v7). Do not claim the original video is fixed without runtime evidence.
- Do not fake completion. Source integration is not compilation or runtime evidence.
- Do not run builds/typechecks/tests, workflow dispatches, project generation, model downloads, deployment or device/UI validation. User tests afterward. The current user request explicitly authorizes source-only setup of the manual Build Release workflow; other CI setup remains outside scope.
- XcodeGen owns project.yml; do not modify generated .xcodeproj files.
- Preserve Mac identity, source, purchases, catalog, storage, resources and behavior.

## Scope and workflow

Read docs/ios/README.md, PLAN.md, FEATURES.md, WORKFLOW.md, HANDOFF.md and the requested phase brief. The compact 29-item v1 scope supersedes the historical 467-item catalog and P0–P13 roadmap. Old handoffs, images and Mac capabilities do not authorize features. No accounts/backend/cloud inference/sync, teams/social integration, credits, stock libraries, dubbing, share extension/App Group/inbox, camera, translation or advanced editor expansion.

One PR per requested phase from latest develop targeting develop; keep all passes in it. Leave open with auto-merge disabled until the user explicitly requests merge. Do not start another phase automatically. State scoped IDs and short UI plan; the current implementation request authorizes its settled UI and routine details. Ask only about actual new scope.

P0–P6 (#23–#29) and optional models plus P7 (#30) are squash merged. Latest phase baseline is eb89f0fb3cd0f67054e6d29de2375342718c1651. Historical PR review holds and P5 Pro deferral are superseded by the current request below.

## Pro phase — merged #31

The Pro implementation below is squash merged as 76981dee7533aab9b1194eee7376bf0ebfc60efb; its earlier PR review hold is historical.

### Approved Pro contract

Implement V1.PRO plus access rules on V1.LOCAL_STT/JOB/STYLE/PRESETS/MP4. Use feat/ios-pro-access-themes, one new PR targeting develop, leave open. Read docs/ios/phases/PRO.md and handoffs/PRO.md.

The user approved: free 30 minutes captioning/week versus unlimited Pro; basic free caption style versus all fonts/templates/animations; free 720p versus Pro 1080p; default free app theme versus all premium AppFoundation themes. Monthly $6.99 and lifetime $24.99 use com.hoangbkit.inkribe.pro.monthly and com.hoangbkit.inkribe.pro.lifetime. AppFoundation owns paywall, contextual upsell, restore, verified purchase state and theme picker/state. No watermark, trial, credit backend or new products.

Import/projects, caption text/timing/split/merge/undo, media tools and SRT remain free. Keep existing projects/captions/styles/export files usable after expiry; new premium choices require Pro. Failed/cancelled recognition is not charged; publication/retry is idempotent. Preserve accepted durable work across expiry and pre-policy jobs across upgrade.

## Existing local contracts

Schema v8 reads v1–v7; absent recognition coverage means a legacy complete result. Keep original clips/raw recognition/native/manual timing canonical. One retained-range map drives preview/MP4/SRT; trimming does not reduce recognition work. One renderer/media graph/audio mix serves preview and export. Keep bounded undo and serialized latest-draft persistence.

Optional bundle/download/cache and Tiny/Base/Small selection remain per docs/ios/MODELS.md. Default project.yml omits iOS weights; project-ios-bundled.yml requires Small and disables download/cache fallback through INKRIBE_IOS_BUNDLED_MODELS_ONLY. Release alone does not change packaging. No weights are to be downloaded by the agent.

## Current release-workflow request

The user explicitly requested the GitHub Build Release workflow based on hoangbkit/guidelines. Keep it in one new chore/manual-build-release PR from latest develop targeting develop, open until asked to merge. This authorizes workflow/helper/docs source edits only, overriding the earlier no-CI-setup rule for this release lane. No workflow dispatch, agent builds/tests, project generation, model downloads or deployment. Do not add Fast/Full CI or change application UI/runtime/model policy. Read docs/BUILD_RELEASE.md. Only workflow_dispatch; unsigned selected-platform archives plus generated Xcode project ZIP; mycli-build prerelease tags. Preserve app identities, Mac resources and source.


## Current iOS bundle identifier request

PR #32 (manual release workflow) is squash merged as 990ef4b. The user explicitly requests a new PR changing the Inkribe iOS target to com.hoangbkit.inkribe in both Debug and Release. Keep this on chore/ios-bundle-identifier from latest develop targeting develop, open until asked to merge. Update the archive identity validator accordingly. Mac remains com.hoangbkit.inkribe.debug in Debug and com.hoangbkit.inkribe in Release. Keep existing iOS preference/storage keys, product IDs and entitlements unchanged. No builds/tests, workflow dispatch, generation, model downloads or device validation. Historical P0 bundle IDs are superseded by this request.

## iOS source naming correction

The user requires the iOS app source folder to be Inkribe/, matching its target, alongside InkribeMac/. App files/types use plain names without IOS prefixes; InkribeApp is the entry point and ProjectCanvas is the domain canvas. Only the two adapters in Inkribe/Storage/LegacyJobCompatibility.swift retain old type names because JobQueue 1.0 persists those names. Existing storage paths, defaults keys, model IDs, schema fields and queue payloads remain stable. Keep these changes in PR #33, open until asked to merge. No builds/tests, CI runs, Xcode generation, weights or device checks.

The user requires iPhone-only support: TARGETED_DEVICE_FAMILY is 1 for both iOS configurations, inherited by the bundled-model spec. Do not re-enable iPad support.

Both app targets must use the same existing InkribeMac/AppIcon.icon resource, following Spokio. iOS selects AppIcon and references that file directly; do not duplicate or redesign the artwork.
