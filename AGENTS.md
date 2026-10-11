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
- keep ONNX model, G2P and voice assets bundled via scripts/onnx-assets.py
- preserve the internal engineering name `ReadAloud` even if the public app brand changes

## Monetization and entitlement decisions

**Never invent, infer, extend, or silently preserve a paywall restriction as a product decision.** The product owner must explicitly approve **what is Free and what requires Pro**. Existing code, old plans/docs, paywall copy, feature flags, framework defaults, sibling apps (including Spokio), and previous assistant implementations are **not** evidence of approval.

Current **explicitly approved** Riidrr access boundaries:

- **Voices:** Heart (`af_heart`) is Free. The other 27 bundled English Kokoro voices require Pro. Voice selection at app, project, and chapter levels is allowed, but applying a Pro voice still requires Pro.
- **Themes:** ReadAloud Light and Dark are Free. Additional themes require Pro.
- **Everything else is Free for now**, including unlimited Library projects/imports, chapter-level voice and speed customization, bulk/selected/all offline generation, automatic prefetch, generate while listening, and clear-cache/advanced regeneration.

Non-negotiable implementation rules:

- Do not add, change, or reintroduce a Pro gate, Free limit, paywall entry point, locked badge, entitlement fallback, or Free/Pro marketing claim **without explicit owner approval for that exact boundary**.
- Copying or adapting UI/features from Spokio or another app **does not authorize copying its monetization or restrictions**. Reuse UI and behavior independently from access rules.
- If a task touches an existing restriction, **flag it as existing behavior, not an approved requirement**. Do not assume it should remain or be expanded. Ask for an explicit decision when the intended access is unclear; do not quietly choose a paywall rule.
- Implement approved access rules consistently in UI, runtime/domain enforcement, settings, paywall comparisons, App Store copy, and release checks. Do not unlock a button while leaving the same operation blocked deeper in the runtime.
- Keep purchase infrastructure available, but gate **only** the expressly approved features. New functionality defaults to Free unless the owner explicitly decides otherwise.
- Before completing a PR with entitlement-related changes, statically audit every added or modified `hasPro`, `requirePro`, access-policy, locked-label, and paywall path against the approved list. State the exact gates retained or changed.

## CI and release automation

The canonical App Store shipping path remains manual/local using Xcode/mycli and
`docs/RELEASE_CHECKLIST.md`.

`.github/workflows/release.yml` is the implemented manual mycli artifact
workflow. It must build the exact selected GitHub ref and expose two independent
choices:

- configuration: Debug or Release
- Kokoro ONNX INT8 + G2P assets: always bundled (no fixture mode)

The workflow publishes one unsigned iOS `.xcarchive` prerelease under the
`mycli-build-*` namespace. It does not upload to App Store Connect.

Fast CI and Full CI remain deferred. `docs/CI_RELEASE.md` records the current
Release contract plus the deferred Fast/Full blueprint.

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
