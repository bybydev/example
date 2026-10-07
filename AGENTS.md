# Repository Working Rules

## Scope

These rules apply to work in the ReadAloud repository.

## Source of truth

- `project.yml` is the XcodeGen source of truth.
- Do not hand-edit generated Xcode project files.
- The generated `ReadAloud.xcodeproj` and `Package.resolved` follow the portfolio convention: they are checked-in, owner-managed artifacts.
- Do not run XcodeGen, regenerate the project, resolve packages, or update `Package.resolved` unless explicitly requested.
- Product architecture lives under `docs/`.
- `docs/PERSISTENCE_CONTRACT.md` is authoritative for durable 1.0 project semantics once implementation begins.

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

## CI workflows

ReadAloud has exactly three primary GitHub Actions workflows:

- Fast CI
- Full CI
- Release

All are manual-only and must work against the branch/ref selected at dispatch time.

Do not add automatic push, pull-request, or scheduled triggers. Do not hardcode checkout to `master` or `develop`.

Follow `docs/CI_RELEASE.md`.

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
