# Project info Form — source handoff

2026-11-01. User-authorized follow-up in PR #58, fix/ios-improvements -> develop,
extending aded0bcd. Keep the PR open without auto-merge.

- [x] Replace Project info's ScrollView/stack with a native Form. Project rows
  show the read-only title, clip count, duration, canvas and created/modified dates.
  Original media has one row per file with size/media metadata and existing
  missing-original recovery. Storage uses native rows for accounting and the
  existing confirmed thumbnail-cleanup action, with its explanation in the footer.
  Status appears as a separate section only when existing errors need attention.
- [x] Use theme.surfaceColor for every section's rows, theme.borderColor for
  separators, hidden system scroll background and the existing themedSurface
  adapter, following the current Media/Style forms. No custom card presentation.
- [x] Remove title editing, automatic title focus and the keyboard toolbar from
  Project info. Keep the editor's separate Rename action and library's rename-on-
  open fallback working through a native alert with local text, explicit Save/
  Cancel, trimming and the existing nonempty/256-character validation. Save uses
  the same session title setter/serialized writer; Cancel does not modify a title.
- [x] Preserve status retry, missing-media picker/relink, storage refresh and
  cleanup confirmation/deletion scope, editor session presentation guards, all
  earlier #58 work, native timing/IDs, queue/exports/history and Mac behavior.

2026-11-02. Approved project-menu follow-up: Rename, Duplicate project and Project
info form the project-action group; a separator precedes confirmed Move to Trash.
Remove save-status/Expand preview/Queue/Media tools rows and the unused editor
Queue presentation/opener and menu-only status string. Save errors/retry remain
in the editor and Project info. Dedicated playback fullscreen, bottom Media and
Home Queue remain. Incoming queue routes and Export/Captions owner-dismissal
callbacks are preserved. Source/diff/whitespace review only, as below.

Validation: source/call-site/presentation/theme/diff/whitespace review and remote
tree preservation only. No builds/typechecks/tests, CI, generation or native/UI/
device execution. Compilation, theme/layout and rename/relink device acceptance
remain unverified.
