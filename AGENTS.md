# Inkribe Working Rules

These rules apply to implementation work in this repository.

## Phase workflow

- Work on one implementation phase at a time.
- Every phase uses its own branch and pull request targeting `master`.
- Keep implementation for the active phase in that pull request until the phase is genuinely complete.
- Before finishing a phase, update the relevant project documentation and add or update the phase handoff.
- When the phase is complete, squash-merge the pull request so `master` keeps one coherent commit per phase.
- Report the merged phase with the implemented scope, important architecture decisions, tests added, documentation updated, and handoff location.

## Completion rule

Do not fake completion.

If a phase is blocked or materially incomplete:

- do not merge it;
- keep the pull request open;
- document the exact incomplete work or blocker;
- report the real state clearly.

Scaffolding, placeholders, skipped required behavior, or knowingly broken architecture do not count as a finished phase.

## Engineering focus

- Prioritize implementation quality, correctness, maintainability, clear ownership, concurrency safety, persistence safety, and useful tests.
- Preserve the package boundaries documented in `docs/ARCHITECTURE.md` and `docs/SHARED_PACKAGES.md`.
- Reusable product/domain logic belongs in shared packages; Mac-specific presentation and integration remain in `InkribeMac`.
- Do not create a second queue scheduler/state machine beside JobQueue.
- Keep user transcript/audio contents out of diagnostic logs by default.

## Automation policy

- Do not add, modify, or run GitHub Actions as part of phase implementation work.
- Keep phase work focused on the product implementation itself.
