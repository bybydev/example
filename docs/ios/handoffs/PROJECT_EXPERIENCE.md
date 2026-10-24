# Expanded Pass 1 — source handoff (#41)

2026-10-24 (Vietnam). Base develop 4a9780f. Branch
`feat/ios-pass1-project-experience` → develop. Leave the PR open; no auto-merge.

The user authorized all of expanded Pass 1 and asked for a marked todo list with an
honest assessment. Checked below means source-integrated and reviewed, **not compiled,
executed or device-accepted**. All execution acceptance remains unchecked.

## Source checklist

- [x] One-project import: Photos/Files/direct URL, review thumbnails/duration, remove,
  reorder, name/format, one creation transaction and one navigation handoff.
- [x] Photos failures remain explicit and block creation until retried/removed; prepared
  successes are retained, and retry uses stable item identity/order. A file copy/check
  failure identifies the item, discards only uncommitted staging and publishes no subset.
- [x] Project overview: combined preview, ordered source rows, Edit/clip entry points,
  project-default routes, rename/duplicate/Trash and export collection.
- [x] Editor: retained one-scroll layout, continuous output clock, tap-to-seek clip strip,
  cached transcript grouping by stable clip ID and existing correction/gap-retry tools.
- [x] Sparse per-setting caption/framing/audio overrides, explicit scope, section/all reset,
  inheritance after reset, expected-state bounded undo, save/reopen/duplicate wiring.
- [x] Effective clip styles in the shared preview/MP4 renderer, clip framing transforms,
  per-source-audio-lane volume events at actual inserted intervals, and frozen input capture.
- [x] Project exports: newest-first completed inventory, activity/queue/retry access,
  output details/artwork, real-file playback, Photos/Files/Share and explicit local deletion.
- [x] Export now follows the same durable worker in-place; Queue export opens job detail.
  Both share capacity, persistence, inventory, cancellation and delivery leases.
- [x] Native save/share cancellation feedback; preview errors; old outputs remain immutable
  and show conservative revision-based freshness when the project subsequently changes.
- [x] Existing direct atomic writer/Back/background flush/error retention integrated with
  overview/editor routes. Speech publication checks now also compare clip settings.
- [x] Six shared override regression specifications authored, not executed.
- [x] Current phase/architecture/design/feature/workflow/readiness documentation updated.

## Ownership and implementation notes

- `ProjectEditorDestination` now acquires the shared session for `ProjectDetailView`
  (overview). `ProjectEditorView` retains the former editor; a navigation intent carries
  an optional clip or project-default tool. Both hold owner IDs in EditorSessions. Covered
  overviews detach their native player layer before the editor/export sheet takes it.
- `ImportView`, ProjectsModel and MediaImporter remove batch separate-project creation.
  Creation has a stable operation project ID. Review metadata/JPEGs are derived; publication
  always revalidates originals in staging. File-provider failures can require Retry or a
  new selection. Copying may repeat after failure; retained Photos ingress copies are reused.
- InkribeCore adds portable `CaptionStyleOverrides`. iOS `ClipSettings` holds clip IDs,
  caption patches and sparse framing/audio patches. No Mac source/config/API is changed.
  Schema 9 validates membership, uniqueness and effective values; duplicate remaps clip IDs.
- CaptionSnapshot caches effective styles and transcript groups. Caption-only overrides
  do not change the media key. Framing/volume changes rebuild the shared media graph after
  the existing debounce; no new per-caption player or native inference path is introduced.
- Settings history captures only small configuration values, not recognition/media. Reset
  removes overrides without changing text, native anchors or project trim. New premium
  choices use the existing gate; inheriting already saved defaults is permitted after expiry.
- Export manifests keep wrapper 1 and add an optional creation date. Project exports use
  the existing disk inventory and independent request/result folders. Actual output size is
  distinct from folder/pinned-input storage. Per-file preview/delivery and artwork requests
  acquire leases; delete checks those leases. Removed queue records do not hide retained files.
- `Export now` does not bypass a user pause, foreground requirement or busy resource gate.
  It can wait behind accepted work. Both entry points still create durable queue records.
- Freshness compares revisions/pending edits, so renaming or undoing can conservatively
  mark an output older even when its pixels would be unchanged. It is not a pixel/content hash.

## Compatibility and limits

Schema 9 reads 1–8 with absent overrides meaning inheritance; no legacy conversion job,
editor sidecar or migration UI is added. Schema-8 app builds reject schema-9 documents.
Do not downgrade a container in place; retain an external stopped-app backup when testing
older builds. This is a format boundary, not a claim of upgrade/device validation.

Clip order is adjustable before creation only. Existing project trim remains global;
output aspect/resolution/30fps remain project/output-wide. No new clip trim tools,
transitions or manual caption creation are included. Existing standalone export access
through Queue remains available when projects are in Trash or deleted.

Failed/unwritten edits remain in app-owned memory across navigation. They are not guaranteed
after termination before a successful atomic save. No separate recovery/discard workflow.

## Validation record

Source/call-site/diff/whitespace review and remote publication consistency checks only.
No builds/typechecks/tests/fixture execution, CI setup/triggers/runs, project generation,
model downloads, inference/native exports, UI/device/accessibility execution or deployment.
The six new shared specifications are unrun. No output artifacts/performance numbers claimed.

### Required user acceptance (all pending)

- [ ] Build/archive exact PR head; confirm native/SwiftUI/strict-concurrency API compilation.
- [ ] Photos + Files/iCloud multiple selection; reorder; failed/cancelled item; retry/remove;
  one resulting project; create/rename/edit/Back/reopen/relaunch. Verify copied originals.
- [ ] Overview → Clip 2 → editor; scrubbing/caption selection across boundaries; Back/swipe
  cancellation; nested export/queue/project routes; native video layers/keyboard on SE2.
- [ ] Default font/color, Clip 2 color-only override, later project font change, section/all
  reset, later default update, undo/redo, save/relaunch and duplicate. Verify persisted IDs.
- [ ] Existing premium defaults/work after expiry; new premium choices remain gated.
- [ ] Mixed video/audio, multiple source audio lanes, per-clip framing/volume and project
  trim; compare actual preview/MP4 captions, crop, orientation and sync at clip boundaries.
- [ ] Queue export + Export now; busy/paused/background states; cancel/retry; two independent
  outputs; preview actual files; Photos denied/allowed, Files/share cancel/error/success.
- [ ] Remove queue record, reopen project, deliver retained output; delete one output while
  another is in delivery; Trash/delete project and inspect independent files through Queue.
- [ ] Slow/failed/out-of-space saves, edits during incremental speech, background/reopen and
  retry; confirm latest successfully saved bytes and accurate single save failure UI.

Parent #40 passes 2–5 retain deeper transcription, manual caption creation, output-quality,
commerce/accessibility/performance acceptance. None has been started automatically.
