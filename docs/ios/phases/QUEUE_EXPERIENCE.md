# Queue experience — four-pass scope

Date: 2026-11-01. Baseline develop b51e1b95e50aa3b2c731efb59e2040860ca1d3fb.
Branch feat/ios-queue-experience targets develop in one PR, left open without
auto-merge. All four passes are user-authorized and source-complete; leave the PR open.

| Pass | IDs | Scope |
|---|---|---|
| 1 | JOB.ACTIONS, JOB.CONCURRENCY | One queued Transcribe/Create Export path; project progress; JobQueue capacity 1/3; remove iOS global serialization |
| 2 | JOB.QUEUE_UI, JOB.PROJECT_ROUTE | Spokio iOS plain-list/scopes/toolbar/row/actions reference; rows open project Captions or matching Export activity/file; unavailable-project fallback |
| 3 | JOB.BACKGROUND | Adapt Spokio user-initiated BGContinuedProcessingTask coordination across both queues, system progress/expiration, GPU support/fallback and truthful lifecycle copy |
| 4 | JOB.INTEGRATION | Final source review of cancellation/retry, project navigation, interruptions/reopening, retained artifacts and every queue entry |

## Pass 1 contract

- Keep the existing Transcribe route through transcription enqueue/authorized
  retry. Do not introduce foreground/direct execution or a separate Queue action.
- Replace Export now and Queue export with Create Export. Capture the saved
  document/profile, enqueue one immutable request, remain in the Export sheet and
  show every project export's status, progress, cancel/retry and completed files.
  Progress derives from saved project/job identities, not an ephemeral latest ID.
- JobQueuePolicy admits 1 transcription total and 3 exports total across current
  and legacy types. Align export type limits and legacy adapters with those values.
  Pending work stays in the existing stores; these are execution limits, not new
  record quotas. Preserve retention and queue-full behavior.
- Remove only the iOS call to ProcessingWorkGate. Do not replace JobQueue with a
  custom scheduler or modify the shared package. Keep native task cancellation
  independent of queue-write success, and await teardown before terminal status.
- Preserve foreground/user-pause/control-storage eligibility and speech-only model
  switching. Transcription uses one shared engine; exports own independent frozen
  graphs, readers/writers, partial/result paths and delivery leases.
- Preserve allowance/revision checks, accepted captions, retry windows, job IDs/type
  names/storage paths, request/checkpoint/document formats and frozen outputs.
- No queue visual redesign/deep links/background request in pass 1. No unrelated
  editor, Mac, shared package, schema, model, purchase, dependency or CI changes.

## Pass 2 contract

- Extend PR #57 from faa33e8c; preserve all pass-1 behavior and concurrency.
- Follow Spokio iOS QueueListView/QueueRecordRow/QueueView: plain themed rows and
  separators; outlined icon/label/count scopes; large Queue title/status subtitle;
  native search; toolbar type filter and Sort By/Order; relevant notices only.
- Row tap opens its project Captions or matching export, with compact colored
  status, type/format, relative date, percentage/stage and short error. Full details
  remain available through context/VoiceOver action; retry/cancel/remove use existing
  live eligibility and confirmation rules. Sorting never changes execution order.
- Keep existing global pause available in the options menu; this pass changes its
  presentation only, not processing policy. Retained exports have a dedicated sheet
  instead of permanent queue footers; retained files/requests and corrupt inventory
  remain inspectable without a live project or queue record.
- Route by fresh request identity plus project/compound job IDs. Complete each
  owner sheet's actual dismissal before forwarding; no fixed sleep. Root handles
  Home/Storage, Settings handles its Storage sheet, and Editor closes its Queue,
  Export or Captions owner before reusing itself or opening another project.
- Focus/highlight the specific export row across activity, completed files and
  saved/unavailable requests. Missing rows explain unavailability rather than
  selecting another file. Do not repeatedly scroll after the initial focus.
- No background submission/lifecycle change, schema/package/engine/Mac/commerce
  changes, preview redesign, new player, or unrelated editor layout work.

## Pass 3 contract

- Extend PR #57 from 7d4b06fd. Adapt Spokio's dynamic registration, progress and
  lifecycle pattern using BGContinuedProcessingTask. This is an execution lease,
  not another job store or scheduler; retain JobQueue policy/type limits of 1/3.
- Successful explicit enqueue/retry/recovery and Resume may begin/extend a lease
  while foregrounded. Queue startup, scene activation, storage refresh, background
  handlers and automatic foreground recovery do not submit requests.
- One session per queue kind isolates speech/export permission and expiration.
  Actual handler delivery grants execution; registration/submission alone does not.
  Recheck user pause, control/queue storage and model-switch eligibility at delivery.
- Speech's existing useGPU=false path and SRT-only export queues use default
  resources. Any nonterminal MP4 or unreadable export payload makes the export
  session GPU-dependent. Request .gpu only when supported; enable the iOS GPU
  entitlement. Unsupported/denied access leaves that export queue foreground-only,
  including any SRT behind/in flight with video; CPU speech remains independent.
- A new explicit MP4 action replaces a CPU-only export session before it can
  authorize video outside the foreground. Do not create a software renderer or
  split stores/types to bypass GPU restrictions.
- Report genuine live per-job progress and terminal accounting through the system
  task. A growing set of user-requested jobs extends that queue-kind session.
  Handle fast completion before handler delivery, failed submission, stale callbacks,
  one-kind drain, retry with the same ID, user pause and speech-only model switching.
- Expiration/system cancellation invalidates the session before pausing/cancelling
  its queue kind. Keep system interruption separate from durable user pause.
  Capture existing native tasks for completion cleanup, so later work cannot extend
  an old lease. Foreground reentry recovers saved jobs without requesting a lease.
- Configure the iOS processing mode, permitted wildcard ID and generated Info.plist
  from project.yml. Exclude/ignore generated metadata; do not generate or commit it.
  Add only the iOS GPU entitlement; no Mac/config/dependency/CI changes.
- Keep accepted caption windows, allowance and independent frozen exports/delivery.
  Partial MP4 rendering still restarts after interruption; do not promise background
  completion after force quit or iOS resource termination. Preserve pass-2 design.

## Pass 4 contract and result

- Extend PR #57 from 2923c08b. Complete source integration review of passes 1–3;
  preserve the settled UI, queue limits, native ownership and persistence contracts.
- Source-review actions/authorization, current/legacy admission, cancellation and
  retry, all navigation owners, retained outputs/delivery and continued-task grant,
  resource, expiration, user-pause, model-switch and reopening paths.
- Move processing bootstrap/scene observation from the Home list to the stable
  NavigationStack owner, preserving refresh and pending-editor flushing behavior.
- Clear system interruptions automatically only after a real background return;
  transient inactive/active system UI does not override expiration/cancellation.
  Explicit Resume remains authorized to resume and request new background access.
- Recheck project availability after dismissal and use live Job details if the
  requested project has disappeared. Keep current-editor reuse for live projects.
- Track the latest export inventory refresh generation, wait for its settled
  result before initial focus, and avoid premature unavailable copy. Profile changes/reuse
  and Create Export suppress a pending initial focus so it cannot override user
  intent. Preserve the exact job ID and no-repeat-scroll rule.
- Remove the unused global cancellation helper and correct the stale engine
  ownership comment; no engine implementation or model change.
- Update final source evidence and PR summary. Do not expand design/scope, run
  restricted checks, merge, deploy or start another feature.

## Validation boundary

Source/call-site/diff/whitespace/publication review only. No builds, typechecks,
tests/fixtures, CI, project generation, model downloads, native inference/exports,
UI/device/accessibility execution or deployment. Compilation/runtime acceptance is
unverified. See [handoff](../handoffs/QUEUE_EXPERIENCE.md).
