# Repository Working Rules

## Scope

These rules apply to work in the ReadAloud repository.

## Source of truth

- `project.yml` is the XcodeGen source of truth.
- Do not hand-edit generated Xcode project files.
- The generated `ReadAloud.xcodeproj` and `Package.resolved` follow the portfolio convention: they are checked-in, owner-managed artifacts.
- Do not run XcodeGen, regenerate the project, resolve packages, or update `Package.resolved` unless explicitly requested.
- `docs/CURRENT_ARCHITECTURE.md` is the current implemented-system overview.
- `docs/PERSISTENCE_CONTRACT.md` is authoritative for durable project/audio/resume semantics.
- `docs/RELEASE_CHECKLIST.md` is authoritative for the current 1.0 shipping checklist.
- Phased planning/baseline documents are historical context unless a new task explicitly reactivates them.

## Branching

- normal feature work targets `develop`
- use focused feature branches/PRs
- stacked PRs are acceptable when a later phase depends on an unmerged earlier phase
- do not target `master` unless explicitly requested

## Implementation behavior

- focus on implementation when implementation is requested
- do not expand scope into unrelated cleanup
- reuse sibling packages and proven Spokio/AppFoundation patterns instead of duplicating solved infrastructure
- follow `docs/IOS_APP_BASELINE.md` for generic iOS app setup before inventing ReadAloud-specific infrastructure
- keep ReadAloud-specific integration code in this repo
- keep generic Kokoro runtime fixture/model infrastructure in KokoroCoreML
- preserve the internal engineering name `ReadAloud` even if the public app brand changes

## CI and release automation

The canonical ReadAloud 1.0 shipping path is manual/local using Xcode/mycli and
`docs/RELEASE_CHECKLIST.md`.

The existing `.github/workflows/release.yml` is legacy/non-canonical for 1.0.
Do not modify, trigger, repair, or expand CI/release workflows unless explicitly
requested.

`docs/CI_RELEASE.md` is a deferred blueprint for a future manual Fast CI /
Full CI / Release setup; it does not describe the currently implemented
workflow set.

If workflow work is explicitly requested:

- keep workflows manual-only;
- do not add push, pull-request, or scheduled triggers;
- do not hardcode checkout to `master` or `develop`;
- preserve branch/ref-aware execution.

## Testing/build policy

Do **not** run tests, UI tests, browser verification, simulator/device builds, or other validation unless explicitly requested/approved.

After implementation:

1. review the diff statically
2. explain what validation would be useful
3. wait for explicit approval before running it

Do not add expensive UI testing or verification work by default.

## Platform

ReadAloud 1.0 targets:

- iPhone
- iOS 26+
- `TARGETED_DEVICE_FAMILY = 1`
- no Mac Catalyst

The prototype macOS target is not part of the 1.0 product. iPad is explicitly unsupported; do not add iPad device-family support or iPad-specific UI.

## Dependencies

Use immutable dependency revisions for implementation baselines.

Do not silently advance package branches while debugging unrelated behavior.

When intentionally updating a dependency, record/review the compatibility impact.

## Persistence

Once persistent `.readaloud` projects exist:

- stable IDs must remain stable
- schema changes require explicit migration
- never silently delete projects to recover from decode errors
- preserve original imported source
- derived caches may be rebuilt
- generated audio compatibility is determined by metadata/generation key, not filename existence

## Runtime

- views observe runtime state; SwiftUI views do not own synthesis/queue persistence
- background playback is supported
- background synthesis is opportunistic and recoverable, not guaranteed indefinitely
- never use audio playback merely to keep synthesis alive in background

## Branding

Keep these internal unless there is a technical migration reason:

- repository name: ReadAloud
- bundle ID: `com.hoangbkit.readaloud`
- `.readaloud` package extension
- internal ReadAloud type/module names

Public display/App Store branding can be changed independently.
