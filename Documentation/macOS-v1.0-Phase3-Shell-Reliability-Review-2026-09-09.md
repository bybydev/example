# BYOKchat macOS v1.0 — Phase 3 Shell / Reliability Review

**Branch:** `docs/ios-macos-development-review-2026-09-08`  
**PR:** #21 → `develop`  
**Date:** 2026-09-09  
**Status:** implementation complete; awaiting Xcode/runtime validation

## Scope reviewed

- main scene lifecycle and custom shell ownership;
- titlebar/sidebar/window behavior;
- app commands and navigation routing;
- shared `MacChatSessionModel` transient state;
- entitlement presentation during startup;
- utility-sheet keyboard/accessibility semantics.

The custom shell itself remains structurally consistent with `docs/macos-custom-app-shell-plan.md`: BYOKchat keeps a native `NSWindow`, native traffic lights/resize/full-screen behavior, the custom header, and the existing sidebar design.

## Product decision — one main chat window for v1.0

The Phase 3 review found that the macOS runtime intentionally centralizes chat/session state in one app-wide model:

- fresh-chat draft and target;
- queued Project/new-chat state;
- search task/results;
- generation state;
- command request counters;
- Library/Project source-chat navigation notifications.

Supporting multiple simultaneous main windows correctly would therefore require a separate per-window session architecture, not a small shell fix.

For v1.0 BYOKchat now explicitly uses a single `Window("BYOKchat", id: ...)` main scene rather than a `WindowGroup`. This matches the existing model ownership and removes unsupported multi-window semantics. Settings, onboarding, BYOK Pro, and Developer Tools remain independent windows.

Opening the main scene by ID now brings the unique main window forward instead of creating another chat window.

## Implemented fixes

### P0 — startup re-entry

`MacAppModel.start()` is now idempotent:

- it runs only from `.idle`;
- calling `start()` again after `.ready` is a no-op;
- explicit `retryStartup()`, reset, recovery, and data-mutation reload paths retain their intentional rebuild behavior.

This prevents view/scene lifecycle re-entry from replacing the shared provider/chat/workspace/MCP runtime graph.

Regression coverage in `MacStartupRecoveryTests.swift` now verifies that a repeated `start()`:

- composes services exactly once;
- preserves the exact existing core-services object;
- preserves the exact provider model;
- preserves the exact chat-session model;
- remains ready.

### P1 — unsupported multi-window command/navigation/session fan-out

The main scene is now a unique SwiftUI `Window` rather than `WindowGroup`.

That resolves the previously reported fan-out risks at their architectural boundary:

- Command-N has one main shell recipient;
- Command-K has one search surface;
- Toggle Sidebar has one shell recipient;
- Library/Project source navigation has one main-shell listener;
- the fresh-chat draft/target/attachment key has one active main composer;
- the shared search pipeline cannot be overwritten by another main window;
- generation/session presentation state is no longer presented as independent per-window state when it is actually shared.

This intentionally does **not** introduce a speculative per-window session coordinator. True multi-main-window chat support can be designed later as a dedicated feature if desired.

### P2 / residual Phase 2G — false Free header state while checking

The main workspace no longer renders after app-runtime startup until `PurchaseManager.entitlementState` has left `.checking`.

During that interval `MacStartupView` shows a neutral `Checking BYOK Pro status…` progress state. Therefore the custom header cannot render its Free `Unlock Pro` action before StoreKit has resolved the entitlement.

This makes the main-workspace startup behavior consistent with the explicit `.checking / .active / .inactive` policy already used by Analytics and the restored-resource gates.

### P3 — utility sheet close semantics

`MacUtilitySheetContainer` now gives its shared close button:

- `.keyboardShortcut(.cancelAction)`;
- an explicit destination-aware accessibility label such as `Close Library` or `Close AI Providers`.

## Implementation commits

Phase 3 implementation after review commit `9aa4032`:

- `3475558` — Make macOS startup idempotent
- `91d4646` — Test idempotent macOS startup
- `f0b4360` — Use a single macOS main window
- `42c82bf` — Avoid unresolved entitlement UI during startup
- `0f89336` — Improve utility sheet close semantics

## Validation matrix

Because v1.0 now intentionally has one main chat window, the Phase 3 runtime matrix is:

| Action | Expected result |
| --- | --- |
| Reopen main window by scene ID | Existing unique main window is brought forward; no second chat session is created |
| Re-enter startup task after ready | Existing runtime graph remains unchanged |
| ⌘N / New Chat | Main chat surface resets/focuses correctly |
| ⌘K / Search | Main sidebar search focuses correctly |
| Toggle Sidebar | Main sidebar toggles exactly once |
| Open Library/Project source chat | Main window selects the source conversation and scrolls if requested |
| Generate while opening Settings/Pro/utility windows | Generation continues; runtime models are not rebuilt |
| Launch as existing Pro user | Main workspace does not display `Unlock Pro` while entitlement is `.checking` |
| Escape on a utility sheet | Sheet dismisses consistently |
| Close and reopen main window | The same shared runtime remains usable |
| Resize/minimize/full-screen/theme change | Native window behavior and custom shell remain stable |

## Validation state

The changes and regression test were statically reviewed, but **the Mac target/tests have not been executed in Xcode in this environment**.

Before Phase 3 is runtime-validated:

1. regenerate/refresh the Xcode project if required so all `Tests/BYOKmacTests` files are included;
2. compile the macOS target;
3. run `MacStartupRecoveryTests` and the existing Mac regression suite;
4. exercise close/reopen, resize, minimize, full screen, titlebar dragging, sidebar toggling, Command-N/K/Period/Comma, utility-sheet Escape dismissal, Settings/Pro windows, and Library/Project source navigation;
5. launch in entitlement `.checking`, Free, and Pro states and verify the main workspace never flashes a false Free upsell;
6. run a long generation while opening/closing secondary windows and confirm generation/runtime identity remains stable.

Any failure exposed by Xcode/runtime validation stays in Phase 3 until fixed.

## Exit gate

Phase 3 implementation is complete at source level. The exit gate is now runtime validation: no known P0/P1 daily-use shell/reliability bugs after the Mac smoke matrix passes.
