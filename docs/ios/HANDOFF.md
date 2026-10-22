# Live iOS handoff

Updated: 2026-10-22. Source of truth: [P0 handoff](handoffs/P0.md).

## Current state and authority

- Issue [#21](https://github.com/hoangbkit/Inkribe/issues/21) is the complete 467-item roadmap; no user-feature checkbox is implemented in P0.
- Planning PR [#22](https://github.com/hoangbkit/Inkribe/pull/22) was **squash merged**. Any instruction to wait for planning PR approval/merge is historical.
- Develop at P0 branch creation: `955196997b3fbc2683d59fcb44fbc4b11ec5ec9c`.
- P0 implementation branch: `feat/ios-p0-foundation`. Draft [PR #23](https://github.com/hoangbkit/Inkribe/pull/23) targets `develop`; **leave open for user review, do not merge or enable auto-merge**.
- P0 source now includes Mac target/scheme rename, independent iOS target, AppFoundation composition root, rational time/edit metadata contracts and a bounded Core Text/Core Image compositing spike.
- The iOS app entry scene deliberately has no feature UI; its Projects/import/editor workflows are not implemented. No native iOS inference target is linked.
- No builds, tests, XcodeGen regeneration, CI setup/runs, model downloads, UI tests, device validation, media uploads or deployment were performed.

## Next action

Review [PR #23](https://github.com/hoangbkit/Inkribe/pull/23), especially source-level target/scheme references, AppFoundation pin, rational-time validation, one-frame compositor and Mac preservation. The user will regenerate, build and test after implementation. Keep all P0 corrections in this same PR; never start P1 or merge until explicitly requested.

## Phase progress

| Phase | Implementation | Source verification | User device testing |
|---|---|---|---|
| [P0](phases/P0.md) | Code authored, review pending, runtime unverified — [#23](https://github.com/hoangbkit/Inkribe/pull/23) | Source audit only | Pending user |
| P1–P13 | Not started | Not run | Pending user |

## P0 outcomes / caveats

- Mac release/debug bundle IDs and product/display name unchanged. StoreKit configuration, product IDs, entitlements and Application Support data paths unchanged. The application/test targets and schemes are renamed; the Swift app module stays `Inkribe`, explicitly pinned alongside the preserved XcodeGen product name. All Mac app-module test imports use `Inkribe`.
- iOS uses a distinct bundle ID and source tree. AppFoundation version is pinned to `0.1.8`; iOS has an isolated empty StoreKit test file (zero products), empty entitlement dictionary (no permissions), and an empty asset catalog (no app icon); no paid IDs or UI assets were invented.
- The preview/export seam shares a deterministic scene evaluator and one-frame Core Image compositor. This is not a media reader/player, live preview, AVAssetWriter export, P4 caption styling, or production AVFoundation composition.
- Native XCFramework iOS slices, dynamic frameworks, model footprints/performance and device behavior remain **unverified**, regardless of package platform declarations.
- P1 owns document persistence/migration and import; P2 owns bounded inference and word timing; P3 owns editor session commands; P4/P5 own production render/preview/export; P6 owns nonidentity clip timing and effects.

## Resuming work

Read root AGENTS.md, README/WORKFLOW, this HANDOFF, P0 brief and [handoffs/P0.md](handoffs/P0.md), then inspect the current PR head and latest develop. Do not rely on an earlier planning snapshot. Resolve concrete source-review findings in the same PR. Do not mark any feature complete without integrated behavior.

**Review prompt:** Review PR #23 versus latest develop under the no-build/no-test/no-CI rules. Focus on Mac identity and storage/purchase regression risk, XcodeGen target membership and scheme paths, Swift 6/26 API assumptions, rational half-open intervals, CoreText/CoreImage frame layout and source-time mapping. Keep fixes on #23 and leave it open.
