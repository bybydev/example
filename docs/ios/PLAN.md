# Inkribe iOS — current plan

## Current: Graphite in PR #50

2026-10-28. Confirmed plan: add Free, always-dark Graphite immediately after Paper,
accent #279ED2. The confirmed visual revision uses Midnight's translucent panels,
subtle shadows and layered background with charcoal/blue lighting. Paper stays default;
premium themes and stored selections stay intact. Source-integrated; no runtime
validation. See [handoff](handoffs/GRAPHITE_THEME.md). Keep #50 open. The preview
fix below is already squash merged from #51 into #50 as 35b29af, user-validated.

## Current: preview handoff fix stacked on #50

2026-10-28. `fix/ios-preview-handoff` starts at #50 head `5c9f9eb` and targets
`feat/ios-contextual-caption-editor`. Retain a current still before disconnecting
live video, retain its caption presentation, and restore live video after readiness.
Source-integrated; compilation/device acceptance unverified. Preserve the full #50
workflow and one player. No automatic next feature or merge. See
[scope](phases/PREVIEW_HANDOFF.md) and [handoff](handoffs/PREVIEW_HANDOFF.md).

## Current: contextual caption editor

2026-10-28. Replace only the top-level Timing tool, from develop `ba5b422`, in a
new open PR targeting develop. Source integration covers contextual entry from
timeline/transcript, caption/word correction and timing without playback controls,
and native push/pop back to the Captions list. Timeline entry retains sheet dismissal
to the main timeline with selection and paused pre-roll.
Captions now includes top video preview/play/pause/Undo/Redo without a scrubber or
timeline, and always highlights the current playback cue without auto-scrolling.
Row taps still select/highlight/seek. The selected row's top-left Edit caption
pushes the editor; remove list inline editing and Split / Words. Future edits
require a concrete plan confirmed by the user before implementation.
Styles/Customize, Media, reset scope and displayed-clock consolidation are deferred.
See [scope](phases/CONTEXTUAL_CAPTION_EDITOR.md) and
[handoff](handoffs/CONTEXTUAL_CAPTION_EDITOR.md). No automatic next feature or merge.

## Prior project-sheet passes (merged)

2026-10-28. The three approved project-sheet passes are source-integrated in PR #49
on `feat/ios-editor-sheets` → develop. Leave open without auto-merge.

| Pass | Result | Source status |
|---|---|---|
| 1 | Direct editor; separate Project info/Clips; toolbar-only existing Export sheet/history; numbered labels/plain ellipsis | Integrated |
| 2 | Reviewed Photos/Files/URL append, confirmed removal, durable expected-state history and caption/coverage/preview integration | Integrated |
| 3 | Native local reorder with Cancel/Save, exact caption projection, ordering/trim/history integration and source consolidation | Integrated |

See [scope](phases/EDITOR_SHEETS.md) and [marked handoff](handoffs/EDITOR_SHEETS.md).
Compilation and device/output acceptance remain unverified.

## Product contracts

One creation makes one project containing one/multiple clips. Existing projects
can append clips; copies are inspected in unpublished staging, then one transaction
publishes all selected media or none. Removal keeps one clip minimum and retains
original files for history. Structural Undo is in memory like other editor history;
files are not automatically purged when history ages out.

Clip names/settings/native/manual captions follow stable clip IDs. Source intervals,
raw recognition and native word IDs stay genuine; structural edits move project-clock
positions and accepted coverage indices. Active project transcription excludes final
structural transactions. Copying and frozen export jobs remain independent.

Reorder edits a local order and Save commits one durable change. Cancel/no-op does
not publish. Global trim keeps its start/end clock positions through reorder. Add
expands an explicit end trim; removal collapses boundaries and resets only if no
visible range remains. These behaviors are disclosed in the corresponding sheet.

Schema 11 reads 1–10. Free remains 30 minutes/week; accepted coverage is reused and
new speech reservations measure unresolved audio cores. Model choice stays solely
in Settings and all transcription uses the shared active engine/model. Existing
premium work and immutable export files retain their established access rules.

No automatic next feature, merge or release. No transitions, music/multitrack,
per-clip trim, accounts/backend/cloud sync, translation/dubbing, share extension,
iPad or Mac expansion. Source-only execution restrictions remain in force.
