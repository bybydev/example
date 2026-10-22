# Live iOS handoff

Updated: 2026-10-22.

## Current state

- This PR adds planning documentation only. **No iOS phase has started.**
- Planning base: develop `e860f0fac71ce923ee594ac1a9e6dd636750e2d3`.
- Source issue: [#21](https://github.com/hoangbkit/Inkribe/issues/21), copied in full to [ISSUE_21.md](ISSUE_21.md).
- All 467 source feature items are mapped in [FEATURES.md](FEATURES.md).
- Design image is included at [assets/main-screens-reference.jpeg](assets/main-screens-reference.jpeg).
- **This planning PR must remain open until the user explicitly requests merge.** No auto-merge.
- No code changes, app targets, generated projects, dependencies, build/test execution, model downloads, CI setup/runs, device validation or deployment are authorized by this planning request.

## Next action

Wait for the user's review/merge instruction for this planning PR. P0 is the first implementation candidate, but requires a separate request. When authorized, inspect latest develop and refresh [BASELINE.md](BASELINE.md); do not assume this snapshot is the future source state.

## Phase progress

| Phase | Implementation | Verification | User device testing |
|---|---|---|---|
| [P0](phases/P0.md) | Not started | Not run | Pending user |
| [P1](phases/P1.md) | Not started | Not run | Pending user |
| [P2](phases/P2.md) | Not started | Not run | Pending user |
| [P3](phases/P3.md) | Not started | Not run | Pending user |
| [P4](phases/P4.md) | Not started | Not run | Pending user |
| [P5](phases/P5.md) | Not started | Not run | Pending user |
| [P6](phases/P6.md) | Not started | Not run | Pending user |
| [P7](phases/P7.md) | Not started | Not run | Pending user |
| [P8](phases/P8.md) | Not started | Not run | Pending user |
| [P9](phases/P9.md) | Not started | Not run | Pending user |
| [P10](phases/P10.md) | Not started | Not run | Pending user |
| [P11](phases/P11.md) | Not started | Not run | Pending user |
| [P12](phases/P12.md) | Not started | Not run | Pending user |
| [P13](phases/P13.md) | Not started | Not run | Pending user |

## Starting or resuming a phase

Read root AGENTS.md and the reading order in README.md. Check open PRs/branch heads and the current user's scope before editing. Inspect source symbols listed in the phase brief. Record newly discovered baseline differences; do not broaden the phase silently.

At the first pass create `handoffs/Pn.md` using [the template](handoffs/TEMPLATE.md); keep it current within the same phase PR. Record branch/base/head, feature IDs, document/schema contracts, remaining work, explicit next step and user instructions. Do not rely on an earlier chat or model memory.

## Completion handoff

Update FEATURES.md only for integrated functioning behavior; preserve unchecked dependency-pending items. Set implementation, source review, build/test and device-test statuses separately. Link actual PR/commit results once available. Do not manufacture evidence, future PR numbers or device metrics.

For review of a critical phase:

> Review the entire diff of phase Pn against latest develop. Read docs/ios/WORKFLOW.md, ARCHITECTURE.md, phases/Pn.md and handoffs/Pn.md. Focus on correctness, state/persistence boundaries, timing and Mac regressions. Do not run CI, builds/tests or device validation unless explicitly requested. Keep fixes in the same phase PR and respect its current merge hold.

## Phase outcomes / known limitations

None yet. Unresolved design/technical choices are in [DECISIONS.md](DECISIONS.md); planning risks are in [RISKS.md](RISKS.md). Append real outcomes here as phases land.
