# Inkribe iOS — current handoff

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
