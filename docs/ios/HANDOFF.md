# Inkribe iOS — current handoff

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
