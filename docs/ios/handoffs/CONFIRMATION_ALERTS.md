# iOS confirmation alerts

2026-11-05. User-authorized stacked PR from #62 head
`c26807a048becf9d0e5b9a8e69302dacd01a7fad`. Branch
`fix/ios-confirmation-alerts` targets `fix/ios-improvements`. Leave both PRs open
without auto-merge and do not modify the parent branch.

## Converted inventory

All 17 iOS `confirmationDialog` sites now use native `.alert` presentation:

| Location | Confirmation |
|---|---|
| Home / Projects | Move project to Trash |
| Home / Projects | Delete folder |
| Home / Projects | Permanently delete project |
| Editor project menu | Move current project to Trash |
| Clips sheet | Remove clip |
| Captions / transcription recovery | Start transcription over |
| Captions / unfinished progress | Reset saved retry progress |
| Project info / Storage | Clear library thumbnail |
| Export / file row | Delete local export |
| Export / job row | Cancel export or delete local export |
| Queue / individual and filtered actions | Cancel jobs or remove records |
| Job details | Cancel job, remove record or delete local export files |
| Storage | Clear cached previews |
| Storage | Empty Project Trash |
| Storage | Discard unfinished import |
| Speech Models | Switch active model and cancel transcription |
| Speech Models | Remove downloaded model |

The inventory includes ignored source directories (`Inkribe/Models`); source
searches must not rely on default ripgrep ignore behavior for this audit.

## Source integration

- [x] Keep existing titles, explanatory messages, destructive roles, selected
  targets, operation guards and asynchronous work. Add explicit Cancel actions
  wherever the confirmation previously relied on an implicit cancel action.
- [x] Keep existing explicit Cancel cleanup for folder/project/clip/model targets.
  Capture pending import and model IDs through `.alert(... presenting:)` so
  dismissing an optional-state alert cannot clear the operation's target before
  its action captures it.
- [x] Existing Home error gating already excludes all its confirmations. Apply
  equivalent gating to Storage errors and editor Trash confirmation so background
  errors wait and remain available after a confirmation ends.
- [x] Remove the queue dialog's `titleVisibility` argument, which is not an alert
  parameter. Keep its dynamic single/bulk titles, counts and actions.
- [x] Preserve all #62 caption fixes, Mac dialogs, menus, sheets, schemas,
  processing/queue/model/storage behavior, dependencies and generated projects.

Validation: reviewed every converted call site, Cancel/action target handling,
roles/messages and existing error owners; verified no iOS `confirmationDialog`
sites remain, including ignored source folders. Reviewed diff/whitespace and
verified exact remote base blobs, changed-file publication and stacked PR refs.

No builds, typechecks, tests/fixtures, CI, generation, native processing, UI/device
execution or deployment were run under repository rules. Native appearance,
presentation and action behavior remain unverified at runtime.
