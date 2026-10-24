# Issue #38 — production pass 2 handoff

> Historical pass-2 record: pass 3 is now source-integrated in the same PR #39.
> HOME_NATIVE_FLOW phase/handoff and root AGENTS define current scope. Earlier
> pending-pass/authorization statements here describe the pass-2 delivery point.

Date: 2026-10-23. PR #39: feat/ios-project-packages → develop. Pass 1 remains in
the same PR. Passes 1–2 are source-integrated; pass-2 baseline is a035dd3. Leave
open without auto-merge. Passes 3–5 and merge are not authorized by completion.

## Result and ownership

| Responsibility | Source |
|---|---|
| Portable request/profile/control wire contracts | InkribeCore/Processing/ProcessingContracts.swift |
| FIFO single-heavy-operation admission | InkribeCore/Processing/ProcessingWorkGate.swift |
| App composition, live IDs, actions/bulk authorization | Inkribe/Processing/ProcessingCoordinator.swift |
| Durable pause vs foreground state | ProcessingLifecycle.swift |
| Native interruption independent of queue-write success | ProcessingRuntime.swift |
| Speech recovery/allowance/model checks | TranscriptionController.swift; existing LocalTranscriber/repository |
| Independent requests/results/delivery leases | ExportController.swift; repository export methods |
| Scopes/counts/filters/rows/bulk actions | ProcessingQueueView.swift |
| Live details/actions/project route | ProcessingJobDetail.swift |
| Capture saved revision and follow exact export ID | ExportView.swift |
| Per-artifact native delivery | ExportResultView.swift; existing ExportDelivery.swift |
| Unexecuted compatibility/resource specifications | ProcessingContractsTests.swift |

## Shared boundary and compatibility

The existing InkribeCore gains consumed Codable transcription/export requests,
export format/resolution/profile, versioned control state and the resource gate.
Field names and mp4/srt/720/1080 wire values remain unchanged. Optional speech
projectTitle adds useful history metadata; old jobs decode without it. Nil model
still resolves to Small in the app; nil requiresAllowance retains pre-policy
semantics and false remains Pro-granted. Current SpeechJob/ExportJob and legacy
IOSSpeechJob/IOSExportJob names/IDs decode as before. Project schema 7, reads 1–6,
checkpoint version/runtime bindings and usage ledger are unchanged. Native runtime,
lifecycle, registry, project validation, Photos/Files/Share and renderer stay in iOS.
Mac Transcript APIs and all Mac source/configuration remain untouched.

## Scheduling, cancellation and pause

Both original JobQueue 1.0.0 stores remain in place. Each queue admits one execution
including legacy jobs. JobQueue preserves enqueue sequences, FIFO within each
registered job type, priority weighting and fair rotation between registered types.
Legacy/current type names remain distinct and retain their existing priorities;
this is not a promise of global FIFO across legacy/current types or both stores.
No combined-store migration, ID conversion or history replacement is needed. One head per queue can
be admitted; one heavy native operation total can own the shared FIFO permit. A
capacity waiter reports Waiting for processing capacity and appears Pending with
no percentage. An existing waiter owns the next turn before the current type can
reacquire. Individual long jobs are not preempted for fairness. Display sorting
never changes execution order.

Waiting jobs hold no loaded model/decoder/AVFoundation writer/media graph. The
permit spans setup, processing/publication and teardown/unload. Cancellation removes
waiting requests; admitted capacity releases after operation exit, including errors.
The iOS runtime tracks child tasks and cancels them on interruption even if queue
pause cannot be saved. The parent awaits native teardown before JobQueue can mark
the record terminal and permit deletion/retry. Cancellation remains cooperative;
no immediate native/OS cancellation guarantee is claimed. No background capability,
continued-processing submission or background completion promise was introduced.

Application Support/InkribeIOSProcessing/processing-control.json version 1 records
user pause only. Foreground state is runtime-only. A restored queue is synchronously
paused before yielding when ineligible; native admission rechecks eligibility.
Foregrounding/enqueue/retry never overrides deliberate pause. Corrupt/future/
unavailable control storage blocks processing and shows Retry, without reset.
Failed pause writes keep pending intent in memory and retry that write first. An
uncommitted write cannot guarantee pause across process death; the error is shown.
Native cancellation after queue-pause persistence failure can leave a cancelled/
failed job requiring manual retry after storage recovery; automatic resume is not
promised in that case. JobQueue restores interrupted processing/pausing as Pending,
cancelling as Cancelled and unknown types as unrecoverable. No reset UI was added.

## Transcription and project conflicts

The per-project active-job guard and authorization serialization remain. Retry
re-resolves the live record/payload and uses application model/revision/allowance
checks, retaining captured model/language/ranges. It never calls generic retryAll.
An incompatible queued source graph/revision fails explicitly; retry captures the
latest saved revision through existing recovery. Accepted partial captions, edits,
IDs/native/manual anchors and incremental window publication remain canonical.

Allowance reconciliation uses all active/pending/waiting IDs. Complete nonempty
publication remains the only charge point, including crash acknowledgement of an
already published result. Removal/cancel/failure reconciles reservations while
preserving saved work. Removing a speech record keeps captions/checkpoints. Speech
history retains its existing 100-record metadata cleanup. Active records and runtime
model leases protect removal. Editor/transcription Queue entry drains the draft;
returning refreshes saved state. Stale editor saves retain revision conflict checks.

## Independent exports, retention and delivery

Each export retains its UUID and version-1 request.json under
InkribeIOSProjects/Exports/UUID. Its saved document/profile captures style, trim,
media graph and available captions immediately. MP4 pins retained immutable media
by hard link with copy fallback; SRT needs only its snapshot. Package adoption,
rename/Trash/cache cleanup cannot invalidate these independent inputs. Completion
atomically publishes Result/title.ext then releases Media pins/working partials.
Failed/cancelled requests keep pins for retry or explicit removal; this can retain
substantial disk space. Queue and Storage show that usage.

Starting B never cancels/removes A. The old single export loads in place. Accepted
frozen requests retry with their original snapshot even after entitlement changes;
a new 1080p request still checks Pro. Partial-caption export does not depend on
future speech or silently refresh its snapshot.

| Operation/failure window | Behavior |
|---|---|
| Crash after prepare, before enqueue | Orphan request visible; explicit Recover re-enqueues same ID |
| Enqueue failure/cancel | Remove only new unaccepted staging if possible; failed cleanup stays discoverable |
| Crash after output publication, before queue success | Validate/acknowledge same MP4/SRT output, without rerender/replacement |
| Failed/cancelled rendering | Keep frozen request/media pins; remove working partial |
| Remove terminal record | Keep request/result/pins under Retained files and requests |
| Delete local export files | No execution/delivery lease; persist record removal first, then delete only that folder |
| Deletion fails after record removal | Remaining orphan visible with recovery/error/removal paths |
| Queue persistence/load failure | Explicit retry, no reset/empty fallback/orphan deletion |
| Missing/corrupt/future request or output | Explicit issue/unavailable state; never substitute another file |
| Delivery A while enqueue/render/delivery B | Each token pins its own immutable job URL |
| Project Trash/deletion while queued | Frozen inputs survive; project route only if live project exists |

Metadata encode/read is bounded at 256 MiB and read in bounded chunks. Owned paths,
symlinks and case-variant identity collisions are checked. Unknown/future/corrupt
data is retained. Corrupt requests cannot restore to queue but may be explicitly
deleted when folder identity is safe/unambiguous.

Export records are bounded at 100 with automatic cleanup disabled. All UUID export
folders, including orphans/results, count toward a separate 100-export retention
bound checked under the repository actor before preparation. No unsaved file is
automatically expired/evicted. At capacity, save/share needed files then explicitly
delete older local exports. Removing records alone retains files and does not free
file retention. Existing over-capacity data is preserved and blocks new additions.
This is local storage retention, not a new Pro feature or purchase quota. Invalid
folder sizes can be incomplete; aggregate Storage includes exports or reports an
enumeration error. Neither package originals nor cache cleanup owns export results.

Delivery tokens pin exact artifact URLs through native completion/cancellation.
Photos add-only denial keeps the file with Files fallback. Files exports a copy
without movie Data loading. Share success/cancel/error releases only its own lease,
idempotently. Per-job deletion/recovery is blocked during delivery; unrelated new
exports remain allowed. Missing completed files are reported; create a new export
from the saved project. External file-provider completion/device behavior is unrun.

## UI and unrun validation

Queue uses AppFoundation surfaces, native List/navigation, semantic fonts, 44-point
scope controls, bounded async thumbnails, selectable full errors and actual progress.
Scope counts follow type/search filtering; Failed includes Cancelled/Unrecoverable
with explicit labels. Bulk actions capture filtered IDs and recheck each live action;
errors stay inline. Cancellation, record removal, file deletion and project Trash
have different confirmations/effects. Home/editor/transcription/export/Storage route
to Queue. Activity content scrolls; no sticky job panel was added. Full home/editor/
navigation/style redesign remains later passes.

Source/call-site/diff/whitespace review only. Shared regression specifications cover
old payload/wire values, targeted bindings, resource exclusion, cancelled waiters
and failure release. They are authored but **not executed**. They do not prove
compilation, native teardown, actual scheduling order or device memory performance.

| User-run scenario still required | Expected observation |
|---|---|
| Build iOS/shared tests with supported Xcode/Swift | APIs/concurrency/UI expressions compile; regression specs execute |
| Three speech projects + two MP4 + SRT | Automatic progress; one heavy native operation; FIFO within registered types/fair turns |
| Pause running/waiting; foreground cycle; relaunch | No permit leak; user pause persists; interruption resumes only when eligible |
| Low disk on pause/save/completion | Native cancellation despite queue-write failure; visible recoverable state |
| Rapid/same-project/bulk retry while editing | No duplicate owner/charge or clobbered edits; captured bindings remain |
| Partial captions/targeted missing-range retry/export | Accepted text/IDs/manual timing survives; export captures available cues |
| Free/Pro, weekly reset, expiry while queued | Existing idempotent allowance and entitlement policy; no queue Pro gate |
| Upgrade legacy/current records + old single output | Same IDs/checkpoints/artifact without replacement/conversion |
| Kill around prepare/enqueue/publish/queue success | Orphans visible/recoverable; published result acknowledged without rerender |
| Export A at N; edit; B at N+1 | Independent captions/styles/media/profile/filenames/results |
| Save/share A while B runs; remove B's record | A remains pinned; B's files retained independently |
| Photos denied/limited, provider/share cancel/error | Accurate feedback, no output loss or leaked lease |
| Remove record, recover/delete orphan | Captions preserved; original export ID restored; one-folder deletion |
| Trash/empty Trash/cache/model cleanup during work | Speech/model guards hold; frozen MP4 pins survive project cleanup |
| Corrupt/future queue/control/request; symlinks/collisions | Explicit failure; no empty fallback, orphan loss or unsafe overwrite |
| Fill retention, remove records vs delete files | No unsaved eviction; correct full/room/storage explanations |
| Small iPhone, large text, VoiceOver/reduced motion | Scrolling usable controls/details/delivery; no clipped/floating panel |

No builds/typechecks/tests/fixtures, CI setup/triggers/runs, Xcode generation,
weights, native inference/exports, benchmarks, UI/device/accessibility checks or
deployment ran. User validation is required before release. Black-nav/swipe-back
and full scrolling editor repairs remain later passes, not validated by this work.
