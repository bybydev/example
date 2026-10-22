# Validation and honest completion

## Execution policy

No CI setup/triggers and no device validation. The user tests after implementation. Root AGENTS.md also forbids builds/tests unless asked. These documents describe correctness expectations and future checks; they do not authorize running them.

For this planning PR, review document consistency, feature preservation, links, repository paths, scope and the remote docs-only diff. Do not build the app, resolve packages or download models to validate Markdown.

For implementation, use source inspection and careful diff review by default. If the user explicitly requests a build/test, scope it to affected targets and the relevant behaviors; do not treat one request as permission for CI or device testing. Obtain required UI-test approval separately if not included in the request.

## Correctness cases to implement and review

| Area | Cases | Primary owner |
|---|---|---|
| Import/storage | Cancellation mid-copy, low storage, missing source, traversal, duplicate IDs, atomic commit, delete with active jobs | P1 |
| Recognition | No audio, corrupt media, chunk offsets/overlap, Unicode words, cancel/retry, manual-edit preservation | P2 |
| Editor | Split/merge/insert/delete, undo/redo, selected word/cue, relaunch, async result against newer revision | P3 |
| Styling/render | Reproducible layout, graphemes/emoji/RTL/CJK, seek backward, export and preview at same timestamp | P4/P5 |
| Composition | Trim/split/reorder/speed changes, audio rate/mix, source-to-project mapping, cues outside cuts | P6 |
| AI/providers | Proposal review, stale revisions, offline/cancel/error, idempotent billing/retry, consent | P7/P8/P12 |
| Lifecycle | Recording interruptions, queued export restoration, temporary artifacts, missing fonts/assets | P5/P9/P13 |
| Commerce | Restore, expired/revoked entitlement, export-time policy, readable existing projects | P5/P12 |

Write meaningful focused fixtures when implementation warrants them. Do not add superficial tests that merely mirror implementation. No statement here overrides the no-execution instruction.

## Deferred user testing

Keep phase-specific steps in its handoff, with expected behavior and input requirements. Device checks include memory/heat/battery, actual inference speed, long media, camera/audio interruptions, supported formats, Photos/Files permissions, export fidelity and compact-screen usability. Do not block source implementation solely to obtain these measurements.

Unperformed tests are “not run”; unmeasured properties are “not measured.” “Source review passed” does not mean “device validated” or “ready for release.”

## Completion distinctions

| Status | Meaning |
|---|---|
| Implemented | Behavior is integrated into actual app/service flow; no fake outputs or dead controls |
| Reviewed | Evidence describes the exact source/diff/fixtures inspected |
| Build/test not run | Code execution was not authorized or available; report this explicitly |
| Device testing pending user | Expected by agreement; not a phase merge gate |
| Dependency pending | Feature awaits a named later phase and remains unchecked |
| Blocked / partial | Essential behavior cannot be completed; report it without claiming completion |
| Accepted limitation | Specific platform/API/legal limit documented and explicitly accepted by user |

A phase may be implementation-complete with user testing pending. It may not be called complete if its essential implementation is absent. Continuous P13 work means adding robust handling during each phase, not delaying all reliability work until the end.

## P0 review-only execution record (2026-10-22, PR #23)

The current P0 PR has been evaluated by reading source and target configuration only. No test/build/XcodeGen project generation, prototype execution/pixel-diff, CI operation, model download, UI interaction/test or device validation was performed. The caller-supplied-frame renderer is a source-feasibility prototype; the user can exercise it after generating the project and authorizing tests. See [handoffs/P0.md](handoffs/P0.md) for specific checks. Do not treat feature paths absent by design as UI-test failures.
