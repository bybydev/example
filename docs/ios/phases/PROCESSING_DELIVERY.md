# Issue #38 — production pass 2: processing and delivery

> Historical pass-2 record: pass 3 is now source-integrated in the same PR #39.
> HOME_NATIVE_FLOW phase/handoff and root AGENTS define current scope. Earlier
> pending-pass/authorization statements here describe the pass-2 delivery point.

Date: 2026-10-23. Authorized in existing PR #39 alongside pass 1, targeting
develop. V1 IDs: JOB, LOCAL_STT, RECOVERY, MP4, SRT, DELIVERY, STORAGE, BOUNDS,
HANDOFF. Preserve the 29-item v1 contract and existing Pro/free policy.

## Outcome and UI plan

Several projects queue transcription and several MP4/SRT exports coexist. One app
coordinator owns lifecycle/actions over the existing JobQueue stores. One heavy
native operation runs at a time, with one admitted/waiting job per type. This is
the conservative iPhone resource policy until device evidence supports more
concurrency. Do not copy Spokio's three-job TTS concurrency/background setup.

The custom queue follows inspected SpokioNano controller/view patterns: scrolling
controls/status scopes/counts, type/search/display sorting, title/thumbnail/stage/
error rows, live details by ID and state-derived confirmed actions. Home, editor,
transcription, export and Storage provide Queue entry points. Export selection
captures a saved revision and opens that exact job's details. Completed details
provide Photos/Files/Share. No sticky job panels, home hero redesign, editor
re-layout, navigation repair or caption-style changes in pass 2.

## Implementation contract

- Preserve speech-jobs.json/export-jobs.json, current/legacy job type names, IDs,
  payload decoding, checkpoints/schema 7, native/manual anchors and usage ledger.
- Keep JobQueue priority/type fairness and FIFO within each registered job type.
  FIFO shared permit waiters give the other queue a turn
  before one type starts another native operation. Display sorting is separate.
  Waiters acquire no native resources; admitted capacity releases after cleanup.
- Persist user pause separately from foreground interruption. Check eligibility
  again after capacity admission. Cancel native tasks even if saving the queue
  pause fails, and await teardown before the queue can mark the job terminal.
  Add no background capability/entitlement or promise of background completion.
- Recheck live actions/per-project ownership. Retry through model/revision/allowance
  checks, retaining captured model/language, ranges, accepted caption IDs and edits.
  Never generic retryAll for speech. Only complete nonempty publication charges.
- Every export owns a frozen manifest/document/profile/media graph, source pins,
  partial/result paths and immutable output URL. New exports never remove others.
  Partial-caption export captures available captions without waiting for speech.
- Per-job delivery tokens pin the exact URL through native completion/cancellation.
  Block deletion/recovery of that artifact, not new unrelated exports globally.
- Distinguish cancellation, record removal, export-file deletion and project Trash.
  Record removal preserves files. Startup preserves orphaned requests/results;
  explicit Recover restores the same ID rather than silently deleting it.
- Bound local retention at 100 export folders and 100 export records, without
  automatic unsaved-result eviction. Show per-output/aggregate storage and full-
  store recovery. Speech metadata retains its existing 100-record bounded cleanup.
- Corrupt/future/unavailable queue/control storage fails visibly; retry the same
  file, with no reset/empty fallback. Keep retained outputs independently visible.
- Consume portable request/profile/control contracts and FIFO work gate from the
  existing InkribeCore. Native execution/lifecycle/delivery remain app-owned.
  Mac APIs/source/configuration remain unchanged.

## Evidence

Source integration and call-site/diff/whitespace review only. Shared regression
specifications are authored but unexecuted. No build, typecheck, test, fixture,
native inference/export, model download, CI, generation, UI/device or accessibility
execution under current restrictions. User validation remains required. See
[handoff](../handoffs/PROCESSING_DELIVERY.md). Leave PR open without auto-merge;
passes 3–5 remain pending and are not automatically authorized.
