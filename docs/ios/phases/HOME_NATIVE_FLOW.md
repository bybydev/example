# Issue #38 — production pass 3: home and native app flow

Date: 2026-10-24 (Vietnam). Existing PR #39, feat/ios-project-packages → develop,
retaining passes 1–2. Scoped existing V1 IDs: PROJECTS, RENAME, DUPLICATE_DELETE,
IMPORT, RECOVERY, ACCESS, JOB, DELIVERY, PRO, STORAGE, BOUNDS, HANDOFF; preserve
TEXT/TIMING/UNDO and all successful transcription/render/export behavior.

## Approved implementation direction

Reference the project-library hero/CTA and compact project presentation in AppShot
at daac397 and AppReel at b0f4e9b. Adapt hierarchy with Inkribe's AppFoundation
surfaces/text/accent, not copied fixed colors/tiny fonts or reference business logic.

One scrolling home: rounded creation hero with New Project → recovery/queue
activity → Projects/filter/sort → compact rows. Search hides hero/filter strip.
Purposeful empty/loading/error/missing-media states; one dominant creation CTA.
Hero and toolbar enter the same guarded importer. No sticky/floating home content.
Restore native Back/edge swipe and remove the abrupt flat navigation background.
Keep draft safety through app-owned sessions and durable recovery, not a disabled
custom Back. Full editor layout/style redesign remains passes 4–5.

## Delivery contract

- One project-ID navigation route and one app-owned session/writer per project,
  shared across library/queue routes. Native gesture progress does not mutate or
  clear the draft. Completed disappearance initiates retained save/media teardown.
- Journal exact saved base/proposed document before canonical save. Restore only
  safe known-format data; retain incomplete titles, native/manual caption edits
  and normal conflict rules. Acknowledging an already committed journal must not
  reapply/increment the edit. Conditional cleanup cannot remove newer ownership.
- Preserve dirty/failed in-memory sessions after native pop; expose Home recovery
  and explicit Retry/confirmed discard. Do not silently reset unknown/corrupt drafts
  or block saved-caption access. Keep canonical schema and Mac APIs unchanged.
- Back/background trigger immediate flush; existing typing debounce remains. Show
  actual save errors. Do not promise OS termination safety before a durable write,
  device-verified cancelled swipe behavior or new background execution capability.
- Native bar/title/Export remain. The continuous AF background replaces the flat
  toolbar override, using theme text/accent and native iPhone navigation.
- Preserve all import sources/separate/combined mode and canvas choices. Partial/
  cancelled batches retain committed IDs; retry only remaining inputs. Root navigates
  after sheet dismissal; no automatic transcription. Cancel Photos preparation
  safely, invalidating late callbacks. Direct URL validates custom canvas too.
- Themed settings/models/storage/export/queue, explicit recovery/errors, one sheet
  route per owner, and retained AF purchase/restore/celebration/theme policy.
- Preserve pass-1 package lifecycle and pass-2 jobs, frozen exports/delivery/allowance.
  Resolve pending drafts before rename/duplicate/Trash. Cache clearing never owns
  editor recovery. No accounts, backend, sync, iPad, new prices or Mac redesign.

## Evidence

Source/call-site/diff/whitespace/publication review only. Shared draft regression
specifications authored but not executed. No builds/typechecks/tests/fixtures,
CI setup/triggers/runs, generation, models, inference/exports or UI/device checks.
User validates gestures, native lifecycle, low disk/crash, providers, performance,
themes/accessibility before release. See [handoff](../handoffs/HOME_NATIVE_FLOW.md).
Leave PR open without auto-merge; passes 4–5 remain pending.
