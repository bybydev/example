# Issue #38 — production pass 1 handoff

> Pass 1 historical record: its package work remains in PR #39. The user has now
> authorized/source-integrated pass 2 in that same PR; current processing scope and
> restrictions are in PROCESSING_DELIVERY phase/handoff and root AGENTS. Earlier
> pass-1-only/remaining-pass holds in this document describe its original delivery.

Date: 2026-10-23. Baseline develop `e39e223` (#37 merged).
Branch: `feat/ios-project-packages` → develop. Leave PR open without auto-merge.
Only project-system pass 1 is implemented; passes 2–5 remain unstarted.

## Result and entry points

| Responsibility | Implementation |
|---|---|
| Package format/domain contracts | `Packages/InkribeCore/Sources/InkribeCore/Projects/ProjectPackageLayout.swift` |
| Legacy adoption, reads/writes, lifecycle and accounting | `Projects/ProjectPackageStore.swift` in that shared module |
| Rational timing/revision/error contracts | Shared `Projects/MediaTime.swift`, `ProjectContract.swift`, `ProjectStoreError.swift` |
| Existing iOS domain validation adapter | `Inkribe/Storage/ProjectPackageDocument.swift` |
| Sole app transaction/recognition/allowance/export owner | `Inkribe/Storage/ProjectRepository.swift` |
| Derived preview publication | `Inkribe/Media/ProjectThumbnails.swift` and repository `publishThumbnail` |
| Existing Storage screen details/errors | `Inkribe/App/StorageView.swift` |
| Restore/cache invalidation | `Inkribe/App/ProjectsModel.swift` |
| Native target dependency | `project.yml`, local InkribeCore product added only to iOS |
| Unrun shared regression specifications | `Packages/InkribeCore/Tests/InkribeCoreTests/ProjectPackageStoreTests.swift` |

## Disk format and ownership

Root remains `Application Support/InkribeIOSProjects` so existing queues, usage,
export and cache locations do not change. Projects use `Projects/<UUID>.inkribe`;
Trash uses `Trash/<UUID>.inkribe`. UUID comparisons use parsed identity, including
case variants. Each package owns:

| Path | Policy |
|---|---|
| `package.json` | Wrapper format 1 + project UUID; independent of document schema |
| `document.json` | Canonical schema 1–7 document; new edits still use schema 7 |
| `document.previous.json` | Prior valid document for recovery, not disposable cache |
| `Originals/` | Immutable imported video/audio under existing relative paths |
| `speech-checkpoint.json` when present | Existing version-1 attempts/bindings/recovery; retained without rewrite |
| `RecognitionRecovery/` when present | Existing archived empty recognitions; retained as durable data |
| Other retained children | Migration preserves them; accounting classifies unknown data as durable |

No mandatory empty TTS/content/audio trees are created. `Cache/` and `Temp/`
inside a package, if present, are separately counted, but this pass does not put
working jobs or models there. Global `Cache/Thumbnails`, `Pending`, `Usage`,
`Exports` and queue files stay in their existing locations. A full project move
contains saved editing data; it is not a queue, entitlement or model backup.

The shared store bounds canonical metadata reads/writes consistently at 256 MiB
and wrapper reads at 16 KiB. Oversize/malformed input fails explicitly. This is a
metadata safeguard, not a video-duration/job quota. Native checkpoint limits are
unchanged (64 MiB / 20,000 cores). Real long-project memory/latency is unmeasured.

## Adoption and recovery procedure

1. Before resolving project media, find all managed entries with the same UUID
   in the requested location. No entries means missing; multiple entries means
   collision. Keep every entry on collision, including case/extension variants.
2. A `.inkribe` package must have a valid matching wrapper. Future wrapper
   versions fail before reading/falling back to editable documents.
3. For a legacy UUID folder, decode/validate its current document, or a valid
   previous copy if the current one is corrupt. A future current document is an
   explicit error, never an excuse to load/write an older backup.
4. Validate owned source paths without hashing/reimporting or requiring missing
   media to reappear. Retain every byte, timestamp, raw/native ID, manual edit,
   style, trim, checkpoint and archive. Write only the small wrapper marker.
5. Atomically rename the same directory on the same parent volume. Cancellation,
   storage failure or interruption before rename leaves the old directory
   recoverable. After rename the new path is immediately authoritative, without
   a post-commit cancellation error suggesting publication never occurred.

No persisted one-time flag or competing index controls adoption: opening/listing
uses disk truth. A marker in a legacy folder means an interrupted pre-rename
attempt and is validated/reused. Do not re-encode a project simply to migrate it.
Uncommitted imports remain visible under Pending; recovery excludes active
staging IDs, validates source sizes, and only publishes committed staging with a
valid document. Invalid/future staging is retained for explicit inspection/discard.

### Operational rollback

Older iOS builds enumerate bare UUID directories and will not discover the new
extension. This is not a downgrade-compatible library format. The document itself
still uses the existing schema. To roll back storage during user-controlled
recovery: stop the app and all workers, copy the complete app container first,
check that the target bare UUID name does not exist, then rename each package
back to its bare UUID name in the same Projects/Trash parent. Keep all children;
the old reader ignores `package.json`. Reopening this new version adopts it again.
Never run old/new writers concurrently or resolve a collision by overwriting.
No automatic rollback/downgrade or external file-import UI is implemented.

## Lifecycle and concurrency review

- `ProjectRepository` remains the one application actor. Shared store calls are
  synchronous within it and have no task/screen owners or native handles.
- Creation/duplicate publish validated staging; no partial destination package
  is shown. Save rechecks current revision and canonical encoded expected data,
  advances one revision, preserves a prior valid copy, then atomically writes
  the new document. The app keeps immutable originals/native anchors and narrow
  append-only inference rebase rules. It never recreates missing package structure.
- Speech workers resolve a package before receiving its media URL. Migration is
  therefore complete before a URL leaves the repository; it does not later move
  that live project from legacy to package. Persisted jobs identify projects by
  UUID/revision. All original Swift job names/payloads/default keys are retained.
- Job checkpoint/model/runtime binding is unchanged. Sidecars travel with
  packages through Trash/restore. Duplication copies/remaps canonical coverage
  and edits with fresh identities and no running job/sidecar/allowance copy.
- Allowance lookup resolves both Projects and Trash through the new layout.
  Duplicate identity across those regions stops settlement explicitly rather
  than guessing which publication to charge. Quota rules/products remain unchanged.
- Export manifests/payloads/directories are unchanged. Existing frozen source
  hard links remain valid across rename/Trash; fallback copies are independent.
  Package moves do not alter a captured export revision/profile or its delivery
  lease. The single-export limit remains until authorized pass 2.
- UI guards still prevent moving active transcription projects to Trash.
  Restore validates before moving. Corrupt/future Trash entries stay visible
  with an explanation and disabled Restore; explicit Empty Trash remains a
  separate destructive action and never follows symbolic links.
- Source lookup requires a regular file with the saved byte count. Missing or
  changed media makes the library state unavailable and native processing fails
  explicitly, while saved captions can still open. The existing streamed integrity
  review is the full SHA-256 check. Same-size corruption is not detected at every
  open; doing so would re-read all movies for routine navigation.
- Relink remains byte-identical, streamed and coordinated with native security
  scopes. It can restore the missing Originals leaf but cannot reconstruct a
  missing whole project. Late thumbnail generation checks current project/source
  in the actor before publishing; restore invalidates cached image state.
- Cache clearing touches only the existing derived global cache. Package data,
  recovery, originals, queue store, model files, allowance and frozen exports are
  not cleared. Aggregate accounting reports enumeration errors; per-project
  failures are surfaced separately instead of silently dropping damaged work.

## Shared iOS/Mac boundary

The existing InkribeCore package is extended, not replaced. Existing Transcript
and library-query APIs are untouched. The new public contracts/store have no
UIKit/AppKit/SwiftUI/Whisper/StoreKit dependencies. Rational time uses CoreMedia,
supported by both declared Apple platforms. iOS aliases preserve source names and
encoding. The app-owned ProjectDocument supplies its current typed validation
through `ProjectPackageDocument`; no second parallel editable model is introduced.

Native media/runtime/lifecycle, editing UI, purchases and relink presentation stay
in iOS. No Mac source/configuration/UTType/identity change. Current Mac uses its
existing transcript/media stores, not this iOS package format. Future Mac adoption
needs native access/window/delivery adapters and an explicit legacy-transcript
conversion policy. Portability of source is not a claim of Mac build/runtime parity.

## Evidence and remaining checks

Source/call-site/diff/whitespace review only. Shared regression specifications
cover schema-1–7 adoption preserving exact bytes, marker-before-rename interruption,
collisions, future schema/wrapper rejection, primary/previous recovery, damaged or
missing sources, stale/same-revision writes, Trash/restore, export hard links,
moved-package saves, symbolic links, staging exclusions and storage classification.
They have **not been run** and use a portable storage-contract fixture, not native
Whisper or an actual video. They do not prove app schema migration/device behavior.

| User validation still required | Expected result |
|---|---|
| User-controlled build/core tests | Shared product/aliases compile; regression specifications execute |
| Existing real schema-1–7 projects + partial mapping-1/2 captions | Same text/timing/edits/styles/IDs and usable checkpoints after adoption |
| Fresh import; cancel; relaunch around staging publication | No partial package, duplicate import or silently deleted pending data |
| Kill around marker/rename/save; low disk; unavailable/read-only path | Old or new authority retained, explicit errors, no ghost project/reset |
| Corrupt primary/previous/wrapper; future versions; case-variant duplicate | Valid recovery where allowed; future/collision blocked without overwriting |
| Edit during speech publication; targeted retry; undo/reopen | Existing incremental publication/edited anchors and allowance behavior retained |
| Pending speech and existing frozen exports across update | Same jobs, source bindings, progress and saved output; no duplicate charge |
| Duplicate partial/full project, rename, Trash/restore, relink | Independent identities/media; recovery and current export remain valid |
| Clear cache while generating thumbnail; Trash before completion | No durable data loss, no late orphan publication; restored previews regenerate |
| Storage with missing/corrupt projects and large media | Honest totals/errors; sources and durable recovery distinguished from cache |
| Small iPhone, large text, VoiceOver on Storage | Usable disclosure rows, issue explanations and restore controls |

No build/typecheck/test/fixture execution, CI triggers/setup, project generation,
weights, native inference/export, benchmarks, UI/device/accessibility execution or
deployment was performed. User validation is required before production release.
Passes 2–5 and PR merge are not authorized by pass-1 completion.
