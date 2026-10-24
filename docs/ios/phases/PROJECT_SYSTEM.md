# Issue #38 — production pass 1: project system

> Pass 1 historical record: its package work remains in PR #39. The user has now
> authorized/source-integrated pass 2 in that same PR; current processing scope and
> restrictions are in PROCESSING_DELIVERY phase/handoff and root AGENTS. Earlier
> pass-1-only/remaining-pass holds in this document describe its original delivery.

Authorized 2026-10-23: implement only the first of issue #38's five implementation
passes in one new PR from latest develop, targeting develop. Baseline is
`e39e223245b68d743b5f5efb51fc9c9cdb984a2a` (#37 squash merged).
Branch: `feat/ios-project-packages`. Leave open without auto-merge.

## Scope

V1.PROJECTS/RENAME/DUPLICATE_DELETE/IMPORT/STORAGE/RECOVERY/BOUNDS/HANDOFF:
formal project packages, safe legacy adoption, complete lifecycle, source
ownership, storage accounting and the first consumed shared-core boundary.
Preserve the working editor, speech mapping/checkpoints, queue payloads,
allowance, export pins, purchases and current Mac behavior.

No pass 2 multi-job redesign, home/navigation redesign, editor redesign or new
caption styles in this PR. No external document browser, UTType registration,
Files package import/share, cloud storage or Mac document conversion.

## Implementation contract

- App-private `Projects/<UUID>.inkribe` and `Trash/<UUID>.inkribe` packages.
  A wrapper version-1 `package.json` records project identity. `document.json`
  remains schema 7, with schema 1–6 reads; adoption never rewrites its bytes.
- Keep `Originals/`, previous-document recovery, optional
  `speech-checkpoint.json` and `RecognitionRecovery/` under package ownership.
  Preserve unknown children during adoption; no reimport, reparse, inference,
  remapping or hashing of whole movies just to open a project.
- Validate the legacy document/identity and owned paths before writing the
  marker. A same-parent directory rename commits adoption. If interrupted before
  rename, the same legacy folder/marker is reusable. If interrupted after rename,
  the package is already the authority. Do not create a second copy or delete a
  source before committing the destination.
- Detect legacy/package or case-variant identity collisions and keep both.
  Reject future package/document formats, symlinks and unsafe paths explicitly.
  A corrupt primary may read its prior valid copy; never fall back from a future
  primary to an older document. Missing/damaged media must not hide saved edits.
- Use one `ProjectRepository` actor. Its synchronous shared
  `ProjectPackageStore<ProjectDocument>` owns filesystem transactions; the app's
  `ProjectPackageDocument` conformance retains speech-policy validation.
- Preserve staged import publication, exact immutable-source checks, expected
  revisions, returned save revisions, raw/native caption anchors and current
  duplicate remapping. A duplicate gets fresh IDs and physical originals, not
  the old job/sidecar/usage charge.
- Resolve/adopt before handing a native worker a project URL. Speech queue
  payloads use IDs/revisions, not old folder paths. Frozen exports keep their
  independent hard-linked/copy-fallback sources and unchanged manifests.
- Trash/restore move the package. Validate before restore; failed validation
  retains the item in Trash. Keep unreadable/future items visible with an error.
  Explicit Empty Trash does not follow symlinks or resolve collisions by deletion.
- Derived thumbnails remain in the existing global cache. Publication checks
  the live project/source under the repository actor; late generation must not
  recreate cache for a trashed project. Restoring invalidates thumbnail state.
- Show per-project source/durable/cache/temp breakdowns in the existing Storage
  screen, plus explicit failures. Checkpoints and empty-result archives are
  durable data. Global cache, pending imports, Trash and exports remain separately
  accounted. Cache cleanup never touches package documents/originals/checkpoints.

## Shared module and platform boundary

Extend the existing `Packages/InkribeCore` (its Mac Transcript APIs are unchanged).
The iOS target now consumes portable package identity/layout/document contracts,
storage transactions, rational media time and edit revision contracts from that
module. Internal aliases preserve iOS source names and Codable fields.

The iOS `ProjectDocument` remains its typed semantic adapter because validation
currently depends on `SpeechCheckpoint` and mapping policy. This is an explicit
boundary, not a second generic JSON model or copied domain. Later authorized
passes can move additional caption/job behavior behind this contract. Native
security-scoped relink, AVFoundation, thumbnail generation, purchase state and
queue execution remain in iOS. Mac adoption is deferred. No generated project,
Mac identity/source/resource/purchase settings or existing core Transcript API is
changed. The `.inkribe` wrapper is internal; its extension alone does not claim
compatibility with current Mac transcripts.

## Evidence and acceptance

Source integration, diff/whitespace review and call-site review only. Regression
specifications are added in `ProjectPackageStoreTests.swift` but **not run**.
No compilation, typecheck, tests, fixture execution, model downloads, native
inference/export, UI/device check, project generation or workflow runs.

See [handoff](../handoffs/PROJECT_SYSTEM.md) for format, rollback, failure review,
scenario matrix and remaining user validation. Source-complete is not a
production-readiness certification. Only pass 1 is authorized.
