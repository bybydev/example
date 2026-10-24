# Consolidation — issue #38 / PR #39

2026-10-24 (Vietnam). The user requested consolidation of all five implemented
source passes in the same open PR targeting develop. Baseline PR head cb594c3;
develop e39e223. No new feature phase, data schema, purchase rule or native runtime
expansion is introduced. Mac source/configuration remains unchanged.

## Follow-up: simple project saving

The user rejected the separate draft/recovery workflow during fresh development
and requested friendly project behavior. This instruction supersedes the earlier
editor-journal design and rename/draft follow-ups below; those remain historical.

- Remove the iOS editor-sidecar read/write/recovery/readiness flow and its library
  flags/repository action gates. Ordinary edits now save directly to document.json
  through the existing single actor, serialized writer and atomic replacement.
- Keep revision/expected-state validation, append-only speech rebase, original/raw
  caption protection, newer typing, undo/context, native Back/background flushing
  and strong session retention. Saved is shown only when no write is pending.
- Show Saved/Saving… or one Couldn’t save changes panel with plain guidance and
  Try again. No recovery jargon, destructive discard/reload controls, or forced
  Project details dismissal gate. Home attention is derived only from a failed
  write, not a transient autosave or the presence of an extra file.
- Keep editor/Home Rename accessible. A pending save, missing media or active
  transcription opens the existing editor/title field; genuinely missing files
  can still prevent a successful save, with changes retained in memory.
- Use Continue transcription / sections / Start over for existing transcription
  progress. Checkpoint/native/allowance logic is untouched. A checkpoint failure
  is reported in the transcription controls instead of duplicated by the editor.
- No new migration, sidecar cleanup or deletion. Generic shared sidecar I/O and
  its old specifications are unused by the app, retained as library source.
  Existing saved canonical projects, speech checkpoints and export/job files stay
  in place. Older uncommitted editor sidecars are no longer applied automatically.

**Persistence limit:** failed or not-yet-written edits stay in memory while Inkribe
runs. Without a completed atomic project save, those edits are not guaranteed
across termination. This replaces the earlier durable editor-journal claim.

**Evidence:** source/call-site/diff/whitespace and exact publication checks only.
Two new unexecuted core specifications cover direct saves with no sidecar dependency
and preservation of the last saved project when a save fails. No builds/typechecks,
tests/fixtures, CI, generation, models/native inference/exports, UI/device/accessibility
execution or deployment. The source-only execution limits remain in force.

**Pending user checks:** fresh Photos project → rename → caption/style/media edits
→ Back → reopen; no draft/recovery warning or extra file. Type during a slow save
and verify the latest text/revision persists. Simulate a failed write, leave via Back
or Done, reopen and retry while the app runs; verify one clear error and retained
changes, then successful retry clears Home/editor warnings. Repeat backgrounding,
partial transcription while editing and frozen export after a successful save.
Inspect actual on-device saved bytes and output only when execution is authorized.

## Follow-up: rename access

The user could not rename a project. Source review found the editor's only title
field under Project details and no explicitly named Rename action. The library
disabled Rename whenever a durable or in-memory draft needed attention, including
the recovery failure reported above.

The editor now exposes Rename in its actions menu and focuses the existing title
field in Project details. Library Rename for pending drafts routes to that same
app-owned editor/title field after opening/recovering the project; it does not
issue a separate title-only transaction over unsaved edits. Clean projects keep
the native rename alert and revision-checked repository transaction. Existing
busy/missing-media/transcription restrictions, journal conflict protection,
autosave/error retention and title validation remain intact.

Source/call-site/diff/publication checks only; no builds/tests/UI execution. User
checks pending: editor actions → Rename → edit → Done → reopen; Home Rename with
a pending draft must retain caption/style edits and save the title through the
same writer. Cancel the clean-project alert and verify no title changes. A genuine
unreadable/conflicting draft must remain visible rather than be discarded.

## Follow-up: fresh Photos project failure

The user supplied a device screenshot of a new project showing its temporary
UUID filename and the same unsafe-path error in retained-caption restoration,
editor recovery and speech recovery. This is observed failure evidence, not
acceptance of the earlier source passes.

Source tracing found two defects:

- `ProjectPackageStore.file` independently resolved a prospective, absent leaf
  and compared its path string with an existing directory's resolved string.
  Fresh projects have no `editor-draft.json` or `speech-checkpoint.json`; their
  absence must return nil, not become a path violation. Darwin sandbox aliases
  and directory URL spelling make those separate string resolutions unsuitable
  as the containment boundary. The old import `OwnedPath.secureURL` duplicated
  the same pattern for a not-yet-created original.
- Photos copied each movie to a UUID filename and then used that owned filename
  as `ImportInput.displayName`, which became the new project's actual title.

Both storage paths now use shared `ProjectFilePath`: validate components, require
an existing nonlinked owner, canonicalize that owner once, append safe children
and reject existing child symlinks (including dangling links) and nondirectory
ancestors. Missing descendants are allowed without independently resolving them.
No path rejection was suppressed; packages, originals, journals and checkpoints
are not deleted or rewritten to clear the error. Photos keeps the provider's name
separate from storage identity; a missing/UUID provider name uses Imported Video.
Existing project titles are not automatically renamed.

Three additional unexecuted specifications cover missing sidecars and the first
journaled canonical save, equivalent directory URL forms and aliased ancestors,
and traversal/linked-owner/linked-child/dangling-link rejection. Source/diff and
remote publication checks only. The alias mechanism is a source-based diagnosis
consistent with the screenshot; it has not been reproduced or verified on device.

Pending user check: create a Photos project on the affected phone, verify a usable
title, preview, no recovery warnings, first edit/save/reopen, then transcription.
Also reopen the previously affected project without discarding its data and
verify real corrupt drafts and unsafe links still produce errors. Do not discard
the user's existing recovery draft merely to work around this defect.

## Findings and integrated fixes

| Finding | Trigger / effect before consolidation | Source fix |
|---|---|---|
| New resolved styles could silently default missing fields | A format-2 payload lost a layout/shadow/weight field or contained null; the decoder substituted a legacy default and could reopen with altered appearance | Require all nonoptional format-2 extension fields. Only legacy format-1 omissions default. Unknown/future format protection and optional preset ancestry stay intact |
| Covered editor retained its native player layer | Export/Queue presented a nested editor for the same app-owned session, while the covered editor still attached that player's layer | Relinquish the covered main layer for Style, Export and Queue presentations; preserve the session/player/document/history and restore the main layer on return |
| Error callbacks could outlive the frame/surface they described | A bounds-only redraw succeeded before a queued failure callback, or a new overlay succeeded while the parent's old error remained | New generation on every actual draw; invalidate on dismantle; report initial success as well as failure. Old callbacks cannot overwrite current status |
| Documentation had multiple competing “current” states | Top-level guides still repeated old open-PR, schema, fixed-preview, one-export and Pro-deferral instructions | Consolidate current README/PLAN/FEATURES/WORKFLOW/HANDOFF/ARCHITECTURE/DESIGN; preserve previous records in a clearly historical archive with relocated links |

Format-2 encoding already writes the full resolved fields, so no migration or
version bump is needed. Missing/null extension data is ordinary corruption and
follows existing prior-valid recovery; an unsupported future style remains a
non-corruption error that must not fall back over newer data. Existing valid
format-1/2 looks, tagless legacy content and unknown supported preset references
retain their contracts. Caption text/native IDs/timing/grouping are untouched.

## Consolidated source review

Reviewed style codec/catalog/access/reset and shared motion/layout boundaries;
editor session/save/recovery and native presentation/error paths; processing
coordinator/runtime admission/cancellation; independent frozen export/delivery
ownership; current platform/resource/commerce and documentation contracts. Retain
one journal/writer per project, conditional draft cleanup, exact frozen outputs,
existing queue names/files/IDs, allowance/retry authorization and one heavy native
operation. No incidental rewrite of the working transcription pipeline.

The feature ledger retains all 29 approved IDs and original owners. Current docs
link the five detailed phase/handoff records rather than repeating old histories.
Archived text is historical evidence, not active execution/scope authorization.

## Validation record — source only

- Source/call-site/diff/whitespace review and exact publication hash/preservation
  checks. This is not a compiler, automated behavioral or native acceptance result.
- CaptionStyleTests now contains 12 unexecuted shared specifications. The added
  case removes and nulls each required extension field from a resolved format-2
  payload and expects rejection. Existing legacy-default and complete round-trip
  cases remain, protecting the allowed compatibility paths.
- No builds/typechecks/tests/fixtures, CI setup/triggers/runs, generation, model
  downloads, native inference/exports, UI/device/accessibility or deployment ran.

## Pending user scenarios

1. Reopen intact schema 1–8/format-1/2 projects and historical/unknown references.
   Corrupt one required format-2 field at a time; verify existing prior-valid
   recovery or a read error, with no silent per-field substitution. A future format plus a valid previous document
   must still refuse downgrade. Run shared specifications only after authorization.
2. Editor → Export/Queue → same project editor → return/dismiss, repeatedly.
   Confirm only the visible editor receives video, with retained selection/time/
   draft/history and functioning playback after returning. Repeat Style sheet,
   native Back/swipe completion/cancellation and different-project routes.
3. Trigger a caption render failure, then correct size/text/style and resize,
   switch tools or replace the overlay. Error should clear on the current successful
   frame and never reappear from an old surface; newer genuine errors stay visible.
4. Repeat the prior pass regression matrix, especially legacy migration/recovery,
   partial publication while editing, queue interruption/authorization, multiple
   frozen exports and per-output delivery/retention. Actual native output and
   supported-iPhone performance/accessibility acceptance remain pending.

[PRODUCTION_READINESS](PRODUCTION_READINESS.md) remains the owner-input/release
record. Privacy URL, live commerce, signing/model lane and execution evidence are
still unresolved. Leave PR #39 and issue #38 open; no auto-merge or release.
