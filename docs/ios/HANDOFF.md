# Inkribe iOS — current handoff

2026-10-31. [Timeline clip trimming](handoffs/CLIP_TRIMMING.md) is stacked on
#55 head 381b0d2b, targeting feat/ios-media-form. Source delivery covers selected
clip handles/main-preview boundary audition, restoration/source limits, one saved
Undo edit, shared piecewise output/caption/seek mapping and legacy trim preservation.
Media trim controls are removed. Schema 13 reads 1–12; frozen outputs stay captured.
Compilation/native/UI acceptance is unverified. Keep parent and child PRs open.

2026-10-31. [Media Form pass 2](handoffs/MEDIA_FORM.md) completes both source
passes in PR #55, extending bb0d1b11. Review covers scopes/resets, cancellation,
stale/save/history/reopen, shared preview/output and preserved frozen exports.
Scoped fixes harden sheet-owned save lifetime, preview-independent saving and
recovery, clip settings rewrite/sort and final speech reconciliation. The approved
Form and other editor design remain unchanged. Compilation/native/UI acceptance
is unverified. Keep open without auto-merge; no next feature or merge.

2026-10-31. [Music pass 3](handoffs/MUSIC_LAYER.md) completes the planned three-pass
source delivery in PR #54. Integration review covers import/replacement/removal,
owned/staged files, stale/cancel/save/history, reopen/duplicate/Trash, duration/mute
and preview/frozen-export consistency. Scoped fixes harden sheet ownership and
late completion, rational loops/fades, slider bounds, muted feedback and audio
suitability preflight. The approved design is unchanged. See the source review
matrix and unresolved runtime boundary. Keep the PR open without auto-merge.

2026-10-31. [Music layer pass 2](handoffs/MUSIC_LAYER.md) is source-integrated in
PR #54: Video/Music/Captions order, leading native controls before time zero,
Add music, real bounded waveform/loop indicator, mute feedback and the controls-only
Music sheet. Local/staged Files/replace/control changes commit once on Done;
Cancel/swipe cancels ingress and discards staging. No other editor redesign.
Pass 3 remains unstarted. Source review only; compilation/native/UI acceptance
unverified. Keep the PR open without auto-merge.

2026-10-31. Current source delivery: [music foundation, pass 1](handoffs/MUSIC_LAYER.md),
in feat/ios-music-layer -> develop from 723f333. Adds one separate owned soundtrack,
source selection/output offset, looping, volume/mute/fades, saved controls/history,
master original mute and shared preview/frozen-MP4 integration. Schema 12 reads
1–11; wrapper versions and speech inputs remain unchanged. No timeline or sheet UI
is delivered in pass 1. Those are pass 2 and await the user's signal. Source review
only; compilation/native output/device behavior remain unverified. Leave PR open.

2026-10-29. Current source delivery is [native fullscreen playback](handoffs/NATIVE_FULLSCREEN.md),
stacked on PR #52 at 3f9b8107, targeting feat/ios-style-sheet-grid. Both editor expand
entries and all completed-file preview routes use AVKit directly, with live caption
overlay for the editor and burned-in captions for exported MP4s. Preserve frame
ownership, paused return, delivery leases and all parent behavior. Source-only;
compilation/device acceptance unverified. Keep both PRs open without auto-merge.

2026-10-29. Latest source delivery in PR #52 is the [Style form revision](handoffs/STYLE_SHEET.md):
shared template sample with live draft rendering, play/pause only, native section
rows and preview-free pushed pickers. Caption styling and placement are project-wide
in Style, with placement menu/inline X/Y reflected in the root sample. Media retains
real preview/scrubbing and its own framing/audio scope.
Cancel/Done atomicity and the lazy templates grid remain. Existing frozen requests
retain recorded clip styling; new requests capture the single project style.
Source review only; no compilation or native/UI/device execution. Keep #52 open
without auto-merge. Earlier descriptions of the first #52 design below are superseded.

2026-10-29. Current delivery is the [unified Style sheet](handoffs/STYLE_SHEET.md)
in feat/ios-style-sheet-grid -> develop, based on b28beebb. The user approved
real preview and inline customization, selected-template row pushing a lazy grid,
Cancel discarding local settings and Done durably saving one history entry.
The old carousel and separate Customize action are removed. Catalog, schema,
shared packages, Mac, native renderer, speech/model/commerce/exports stay intact.
Source/call-site/diff review only; no compilation or runtime acceptance. Keep the
new PR open without auto-merge. Earlier feature handoffs are historical where
superseded by this approved flow.

2026-10-28. Current source work in #50 is [Graphite](handoffs/GRAPHITE_THEME.md):
Free dark theme immediately after Paper, #279ED2 accent, translucent panels and
layered charcoal/blue lighting following the confirmed Midnight-like revision.
Paper default and premium access stay intact. Source review only;
compilation/device appearance unverified. Keep #50 open without auto-merge.
The preview fix described below was squash merged from #51 into #50 as 35b29af
after the user reported it working; earlier stacked/open-#51 status is historical.

2026-10-28. Current source work is [preview handoff](handoffs/PREVIEW_HANDOFF.md),
stacked from PR #50 head `5c9f9eb` to `feat/ios-contextual-caption-editor`.
Covered previews keep their last video/caption presentation; returning live video
waits for layer readiness. All #50 behavior remains. Both PRs stay open without
auto-merge. Source review only; no compilation, native execution or device acceptance.

2026-10-28. Current source handoff: [contextual caption editor](handoffs/CONTEXTUAL_CAPTION_EDITOR.md),
based on develop `ba5b422`. Only the Timing-to-Edit-caption consolidation is in scope.
No player/scrubber in that editor. Captions pushes it and Back/swipe-back/Done
returns to the list; timeline entry remains a sheet returning paused just before
the edited caption. Captions itself has a top video preview/play/pause/Undo/Redo,
no scrubber/timeline, and always-on playback-row highlighting without automatic
list scrolling. Caption identity, timing semantics, history and automatic saving
remain intact. Row text selects/highlights/seeks; only the selected row's top-left
Edit caption pushes editing. No inline text field or Split / Words remains in the
list. New PR targets develop,
left open without auto-merge. Other consolidation awaits the user's next signal.
Compilation and device acceptance are unverified under the source-only policy.

2026-10-28. PR #49 on `feat/ios-editor-sheets` → develop contains all three approved
project-sheet source passes. Pass 3 extends `014ad963`; keep the PR open without
auto-merge. The full [marked handoff](handoffs/EDITOR_SHEETS.md) owns source evidence,
implementation details, format limits and the runtime acceptance boundary.

- Direct editor entry with cancellable preparation and one app-owned session/writer.
- Project info for metadata, originals/relink and project-only thumbnail cleanup.
- Large Clips sheet for ordered selection, Photos/Files/URL append, rename, confirmed
  removal and native drag reorder with Cancel/Save and one durable Undo entry.
- Numbered timeline labels; native/manual captions, source anchors, settings, coverage,
  preview/seek/media/audio/SRT positions follow stable clip identities.
- Existing toolbar-only Export sheet owns creation, progress and retained files.
  Background artwork pins files without blocking dismissal. Frozen outputs stay intact.
- Schema 11 reads 1–10. No Mac/shared-package/renderer/engine/commerce/model-policy change.

Source/call-site/diff/whitespace/publication review only. No builds/typechecks/tests/
fixtures, CI/generation/models, native media/exports, UI/device/accessibility execution
or deployment. Compilation and actual touch/layout/performance/output acceptance are
unverified. [Production readiness](PRODUCTION_READINESS.md) retains release gates.

Earlier source evidence remains in the phase handoffs and archive. No automatic
next feature, merge or release is authorized.
