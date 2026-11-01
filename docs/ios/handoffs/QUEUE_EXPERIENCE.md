# Queue experience — all four source passes complete

Date: 2026-11-01. feat/ios-queue-experience -> develop, based on b51e1b95.
Scope: [JOB.ACTIONS / JOB.CONCURRENCY / JOB.QUEUE_UI / JOB.PROJECT_ROUTE](../phases/QUEUE_EXPERIENCE.md).

## Pass 1 delivered

- [x] ExportView exposes only Create Export, always saving/freezing/enqueuing the
  request and remaining in the project's Export sheet.
- [x] Remove immediate-versus-queued routing/state. ProjectExportsSection resolves
  all noncompleted jobs for its project on every render/reopening, with format/date,
  live status/progress and per-job cancel/retry. Completed files keep existing
  preview/save/share/delete and profile reuse.
- [x] Source-trace Transcribe and retry/missing-range actions through the existing
  durable JobQueue and revision/model/allowance authorization; no direct inference
  or now-versus-queue choice exists.
- [x] Speech job/type/queue capacity is 1. Export job/type/queue capacity is 3.
  Legacy adapters use their corresponding current type limit; each queue's global
  policy caps the aggregate of legacy and current executions.
- [x] Remove iOS use of ProcessingWorkGate and capacity-waiter presentation/copy.
  Keep ProcessingRuntime tracking, cancellation handler and awaited teardown.
- [x] Keep user/foreground/storage eligibility, speech-only model switch, export
  input/output ownership, delivery tokens and bounded retention unchanged.

## Source review evidence

| Path/scenario | Review result |
|---|---|
| JobQueue 1.0.0 JobQueuePolicy / JobScheduler / advanceIfPossible | Queue-wide executions and registered-type limits both apply; no custom scheduler needed |
| Current and legacy speech records | One speech store/global execution slot protects the shared engine across both registered types |
| Current and legacy export records | Three aggregate slots; both type limits permit three, independent UUID directories and native worker resources |
| Cancel/foreground interruption/storage pause failure | Runtime child task is cancelled; parent awaits native cleanup before JobQueue terminal state |
| Model switching during exports | Only transcription tasks are cancelled/drained; exports remain independent |
| Create Export and repeat creation | One enqueue path, saved profile captured per request, preparation guard prevents duplicate rapid taps; jobs retain independent IDs |
| Leave/reopen Export | Activity derives from model.processing by project ID; no latest-job state or activity exclusion; finished artifacts come from inventory |
| Concurrent completions/inventory | Existing inventory generation rejects stale refresh responses; repository serializes per-ID publication |
| Retry/removal/delivery | Existing live eligibility, request reuse and per-ID execution/delivery ownership are retained |

The unused portable work gate and its historical tests remain unchanged to avoid
altering shared-package/Mac contracts. This pass does not promise background
execution; leaving the foreground still pauses work until pass 3 is authorized.
Interrupted MP4 jobs retain frozen requests and restart partial rendering as before.

## Pass 2 delivered (baseline faa33e8c)

- [x] Plain themed queue with subtle separators, outlined icon/count pills, compact
  colored status/format/date/chevron rows, live percentage/stage and short errors.
- [x] Large title/count subtitle, native automatic search drawer, toolbar type
  filter and separate sort-field/order menus. Queue controls leave the list body.
- [x] Retry swipe; confirmed cancel/remove swipe; long-press and VoiceOver Job
  Details access. Existing coordinator rechecks live eligibility for individual
  and filtered operations; record removal keeps files.
- [x] Relevant pause/storage/action notices only; retained files/storage policy
  move to a dedicated Retained Exports sheet with independent job details/delivery.
- [x] Caption row opens its project's Captions sheet. Export row opens that
  project's Export sheet, scrolls once to the exact job/file and highlights it.
- [x] Saved requests without records and unavailable files are visible in the
  project Export sheet, preserving full details/recovery/delete access.
- [x] Fresh route IDs, current/legacy compound keys, same-editor reuse, explicit
  owner-dismissal callbacks and unavailable-project fallback. No timing sleep or
  nested editor inside Queue/Export/Storage.

## Pass 2 source navigation review

| Entry/state | Source handoff |
|---|---|
| Home Queue | Root typed project route -> acquire session -> open requested tool after editor preparation |
| Editor Queue | Dismiss Queue owner -> refresh saved session -> reuse own project/tool or forward to root |
| Captions -> Queue | Dismiss owning Captions (including nested Queue) -> existing active-tool dismissal -> requested project/tool |
| Export -> Queue or Job details | Dismiss owning Export -> requested project/tool; same project reuses editor |
| Home Storage -> Queue | Root dismisses Storage (including nested Queue) before appending project route |
| Settings Storage -> Queue | Settings dismisses its Storage owner before forwarding to root |
| Queue Job details -> project | Dismiss details before enclosing Queue/Export/Storage handoff |
| Queue Retained Exports -> project | Dismiss optional details, then retained sheet, then enclosing owner |
| Missing/trashed project | Live ID resolution falls back to details; retained output preview/save/share remain independent |
| Missing original media | Active project remains reachable; existing editor relink/error handling remains |
| Export completes/removes record during navigation | Resolve exact ID from live activity/inventory; wait for row, focus once; retained request/result or unavailable message |
| User delivery active | Navigation/dismissal gates keep existing delivery ownership intact |
| Same destination repeated/rapid taps | Fresh route identity for later requests; pending-route/tap guards prevent duplicate handoffs |

These are source-reviewed paths, not executed UI claims. Pass-1 limits/actions,
foreground-only lifecycle, model switching, allowance/retention, request identities,
frozen graphs/results and delivery leases remain unchanged.

## Pass 3 delivered (baseline 7d4b06fd)

- [x] ContinuedProcessing owns independent speech/export system sessions, observing
  events from both existing queues without changing concurrency, stores or payloads.
- [x] Every successful explicit enqueue/retry/replacement/recovery and Resume reaches
  beginOrExtend while foregrounded. Ordinary launch/scene/storage recovery does not.
- [x] Dynamic MainActor registration follows Spokio; actual handler delivery alone
  grants background access. Pending requests retain a foreground fallback.
- [x] Genuine bounded progress/phase updates, mixed outcomes, same-ID retries,
  fast completion, stale callbacks and per-kind completion/expiration handling.
- [x] Per-kind lifecycle eligibility and cancellation. System expiration revokes
  that grant, pauses durable work and drains a snapshot of current native tasks
  before finishing the system task; user pause remains durable and independent.
- [x] CPU transcription/SRT-only continuation; GPU resource requirement for any
  active/pending video (unknown payloads fail closed). Unsupported/denied GPU access
  keeps the export queue foreground-only while transcription can continue.
- [x] CPU-to-GPU session replacement occurs only around a new user request; an
  existing CPU lease never silently authorizes background MP4 work.
- [x] iOS processing/wildcard metadata in project.yml; GPU entitlement; generated
  Info.plist excluded from resources/git. No generated project/plist produced.
- [x] Queue/project status explains waiting, unavailable, system pause and resource
  fallback; active details explain app-switcher closure. Prior queue design remains.

## Pass 3 source lifecycle review

| State/path | Source result |
|---|---|
| Fresh Transcribe/Create Export/retry/missing-range retry | Post-admission callback requests only for foreground user intent |
| Explicit retained-request recovery / Resume | Same callback or coordinator request path; no additional job store |
| CPU speech and SRT-only exports | Separate default-resource sessions; no GPU requirement |
| Any current/legacy queued/running MP4 | Export session requests GPU only if supported; otherwise its queue pauses outside foreground |
| CPU session then new video | Revoke old export grant before replacement; native work stays on JobQueue |
| Registration/submission fails or handler waits | Foreground work proceeds; background requires a delivered handler |
| Task delivered after pause/switch/storage error/replacement | Live eligibility/identifier check rejects stale permission |
| One queue drains while other runs | Complete only that session; no cross-kind grant or global cancellation |
| Progress/failed/cancelled/removed/same-ID retry | Track per-kind operation IDs, genuine fractions and current terminal states |
| iOS expiration/system cancellation | Invalidate -> system pause/cancel affected kind -> await captured native teardown -> complete false |
| Global user pause / pause-write failure | Stop leases and cancel native work; existing storage failure handling remains |
| Foreground return / relaunch / force quit | Existing durable restore/foreground resume; no automatic continued-task submission |
| Model switch | End speech lease/cancel speech only; independent exports/grant remain |

The fallback is deliberately queue-wide for exports: when video is present, SRT
work sharing that queue also needs the foreground unless a GPU lease is active.
This preserves the existing JobQueue/store architecture and avoids a second
scheduler. MP4 reader/writer/Core Image pipeline and frozen formats are unchanged.
An interrupted MP4 starts over from its frozen request; accepted caption windows
remain available. Force quit/iOS termination can end work without an expiration
callback; continuation and resource/device/signing acceptance are unverified.

Primary references inspected: [Spokio continued processing](https://github.com/hoangbkit/Spokio/blob/develop/SpokioNano/Core/Queue/SpokioContinuedProcessing.swift),
[Apple long-running work](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados),
[Apple WWDC25 dynamic registration](https://developer.apple.com/videos/play/wwdc2025/227/),
[GPU resources](https://developer.apple.com/documentation/backgroundtasks/bgtaskscheduler/supportedresources),
and [XcodeGen plist configuration](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md).

These are source/call-site/configuration review results, not executed background,
GPU, expiration, media, lock-screen or UI observations. No builds/typechecks/tests,
fixtures, CI, project/plist generation, models, native processing, UI/device runs,
signing or deployment occurred.

## Pass 4 final source integration (baseline 2923c08b)

- [x] Review the complete scoped flow from queued user action through native work,
  independent background grants, progress, completion/retry, navigation and delivery.
- [x] Processing bootstrap/scene observer lives on the stable navigation owner,
  including while Home is covered by a project/settings/queue destination or sheet.
- [x] Track actual background entry separately from temporary inactive system UI.
  An inactive/active cycle does not clear an iOS interruption; explicit Resume or
  a true background return can recover saved work without automatic lease submission.
- [x] Revalidate project availability after presentation dismissal. Missing/trashed
  projects fall back to live Job details rather than stale same-editor navigation.
- [x] Export focusing waits for initial/current inventory to settle; overlapping
  reads clear busy state only for the latest generation. Loading does not show a
  false unavailable message. Profile changes/reuse/Create Export suppress pending focus, including after the task yields.
- [x] Remove the obsolete global cancellation helper; correct speech serialization
  ownership comment. No engine implementation/shared package/model change.

## Final source review matrix

| Concern | Reviewed source outcome |
|---|---|
| One user action / queued execution | Transcription enqueue/authorized retry and one Create Export path; no direct/now bypass |
| Current/legacy capacity | Queue-wide speech 1/export 3 plus matching job-type limits; no global permit |
| Concurrent exports | Each UUID owns frozen document/profile/media graph, reader/writer/renderer/context/partial/result and delivery leases |
| Rapid create / cancellation during preparation | Existing preparation guard and saved-document capture; only unaccepted staging cleanup; accepted jobs remain durable |
| Pause/cancel/retry/model switching | Existing JobQueue status/teardown and authorization; speech-only switch; no cross-kind cancellation/grant |
| Background grants and resource changes | Delivered handler only; CPU/SRT-only default resources, MP4 GPU support check/foreground fallback; stale IDs rejected |
| System pause vs user pause | Runtime system flags, durable user intent; temporary inactivity cannot clear a system pause |
| Launch / true foreground recovery | Durable restore/foreground resume, no background task submission without new explicit work/Resume |
| One queue drains / system cleanup | Finish only its lease after captured native teardown; other queue remains eligible |
| Queue scopes/search/sort/actions | Display-only ordering, live compound IDs/eligibility, confirmed cancellation/record removal, full error details |
| Home / Editor / Captions / Export / Settings / Storage | Owner dismissal before root handoff; existing editor reused for its live project; preview/session ownership preserved |
| Project disappears during dismissal | Recheck active library at final owner, live job-detail fallback and independent files |
| Exact export focus / concurrent inventory reads | Initial/current read settlement and stable job IDs; no repeated scroll or override of subsequent user action |
| Record removal / retained request / missing output | Captions/files survive record removal; orphan inspection/recovery/deletion and unavailable state remain |
| Photos/Files/Share/artwork | Existing exact-URL ownership and per-job deletion guards; user delivery blocks unsafe presentation teardown |
| Corrupt/control/queue/inventory/storage failure | Existing visible retry paths; no resets, empty replacements, hidden file deletion or schema migration |
| Configuration and protected scope | YAML/plist source parses; generated metadata absent; Mac targets/settings/packages and runtime policies unchanged |

All four source passes are complete. These findings are source/call-site/diff and
configuration evidence only. No build/typecheck/test/fixture, CI, generation,
model/native-media operation, background/GPU run, lock-screen/UI/device execution,
signing or deployment was performed. Compilation and runtime acceptance remain
unverified. Keep PR #57 open without auto-merge; no automatic new feature or merge.

## Review follow-up — Create Export acceptance

2026-11-01. The user authorizes the acceptance-feedback finding only in PR #57.
After durable enqueue returns, focus/highlight that exact job once using the
existing activity/completed-file anchors, and end preparation before refreshing
storage totals. Each later successful create replaces the focus target;
failed/cancelled preparation does not announce acceptance. Existing inventory-
settlement and post-yield focus checks still apply, including suppression by
subsequent profile changes/reuse.

The user then requests a toast referencing Spokio iOS. Replace the inline success
message with “Export added” in a floating top glass card, matching the inspected
SpokioNano/App/ToastCenter.swift at 80fc72fe: success icon, two-second timeout,
tap/vertical-swipe dismissal, success haptic and VoiceOver announcement. Mount the
presentation on Export's NavigationStack so it remains above the form as it
scrolls. Toast identities cancel/replace the previous timeout, check identity
before dismissal and clear on presentation disappearance. Cancellation feedback
remains inline. No global toast service, settings or unrelated feedback changes.

Source/call-site/diff review only; no builds/typechecks/tests, CI, generation,
native work or UI/device execution. Other review findings are unchanged.

## Approved Export list design follow-up

2026-11-01. The user approves the compact Export-sheet visualization for PR #57.
Keep creation/configuration and the acceptance toast, and replace stacked inline
actions with square aspect-fit thumbnails, compact format/size/date/version or
live status/progress, and one unboxed 44-point ellipsis target per row. The same
available actions appear on long press. Video-row tap opens the existing native
preview; subtitle-row tap opens its file-action menu. Cancellation and local
deletion are confirmed.

The file menus retain preview, Photos/Files/share, profile reuse, Details and local
deletion as applicable. Activity menus use live coordinator retry/cancel/delete
eligibility. Details use the existing dismissal-aware presentation owned by Export.
All row IDs, focus/highlight anchors, inventory/error paths, frozen files and
retention remain. Extract the existing delivery owner for reuse by compact rows
and detailed inspection; native picker/share/player callbacks, Photos handling and
exact-file delivery leases are preserved. Artwork continues using its separate
lease, and delivery/storage/mutation guards protect local deletion and navigation.

The user subsequently simplifies the layout to exactly Create Export and one
Exports section. Merge every project queue record and retained request/file by
UUID, with no duplicate rows or status-based sections. Sort newest update first,
with UUID as a deterministic tie-breaker. Use the latest queue update and retained
request/output filesystem modification date (creation date is a fallback); these
are inventory-only dates, not persisted schema changes. Completed, pending,
running, cancelled and failed states remain visible on their individual rows.
Cancelled uses a neutral label. Keep background notes in the Exports footer
and relevant error/retry messages within the same section. Completed records with
missing files also retain their exact focus anchor and open Details.

The user removes the redundant Open Queue controls from Export and Captions.
Remove the Export footer navigation link and TranscriptionView's button, dedicated
presentation state and nested Queue sheet. Live progress, local cancel/retry,
storage/error feedback and saved-result refresh remain hooked to the existing
controllers/editor. Home and the editor's Queue menu remain available.

Source/call-site/diff/whitespace review only. No builds/typechecks/tests, CI,
generation, native processing or UI/device execution. Keep PR open without
auto-merge. Other review findings and unrelated editor/queue design are unchanged.

## Pass completion

- [x] Pass 2: queue design and project Captions/specific-export navigation.
- [x] Pass 3: continued background processing and GPU-aware export fallback.
- [x] Pass 4: final scoped source integration review.

Source review only. No builds/typechecks/tests/fixtures, CI, generation/models,
native processing/exports, UI/device execution or deployment. Compilation and runtime
acceptance remain unverified. Keep PR open without auto-merge; await next signal.
