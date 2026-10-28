# Inkribe iOS — current plan

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
