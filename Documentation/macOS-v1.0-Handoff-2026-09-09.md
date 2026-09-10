# BYOKchat macOS v1.0 — Current Handoff

**Branch:** `docs/ios-macos-development-review-2026-09-08`  
**PR:** #21 → `develop`  
**Updated:** 2026-09-09  
**Primary review plan:** `Documentation/macOS-v1.0-Deep-Review-2026-09-08.md`

## Current resume point

Source implementation is complete for:

- **Phase 1 — Core correctness**
- **Phase 2A — Providers & Models**
- **Phase 2B — Attachments**
- **Phase 2C — Projects**
- **Phase 2D — Library**
- **Phase 2E — MCP**
- **Phase 2F — Backup & Data Management**
- **Phase 2G — Free / Pro Integration**
- **Phase 3 — Mac shell / reliability**

All of these phases still require Xcode/runtime validation before they can be called release-validated.

Do not restart an earlier phase unless Xcode/runtime testing exposes a regression in that phase.

The working protocol remains:

`review → identify bugs → report findings → approve → implement fixes + regression tests → runtime validation`

App Store packaging, screenshots, metadata, submission polish, and unrelated feature expansion remain deferred until functional validation is complete.

## Phase 2G final state

Restored Free-overflow restrictions are enforced at provider/MCP model boundaries:

- restricted restored providers remain visible/removable but cannot be activated, edited into use, selected as default, refreshed/tested, or reveal credentials;
- restricted restored MCP servers remain visible/removable but cannot be activated/configured/discovered into use or receive active tool permission;
- deleting the currently allowed Free-slot resource dynamically unlocks the next restored candidate;
- explicit entitlement `.checking` remains distinct from Free;
- regression tests cover provider/MCP overflow and dynamic unlock.

Final 2G tail:

- `38679a1` — Enforce restored provider access at model boundary
- `2051d3e` — Enforce restored MCP access at model boundary
- `20b4cba` — Test restored provider model enforcement
- `2a62569` — Test restored MCP model enforcement
- `37d8189` — Record Phase 2G handoff and next phase

## Phase 3 — Mac shell / reliability

Review report:

- `Documentation/macOS-v1.0-Phase3-Shell-Reliability-Review-2026-09-09.md`

### Product decision

BYOKchat v1.0 now intentionally supports **one main chat window**.

The app-wide runtime already owns fresh-chat draft/target state, search, generation, command requests, and source-chat navigation. A `WindowGroup` exposed those shared objects as if each window were an independent session, causing command/navigation/draft/search fan-out risks.

The main scene is therefore now a unique SwiftUI `Window`. Settings, onboarding, BYOK Pro, and Developer Tools remain separate windows. True multi-main-window chat support is deferred until it has a dedicated per-window session architecture.

### Implemented Phase 3 fixes

- `MacAppModel.start()` runs only from `.idle`, so scene/view re-entry after `.ready` cannot tear down and rebuild the active runtime;
- regression coverage verifies repeated startup preserves the exact services/provider/chat objects;
- main `WindowGroup` changed to unique `Window`, removing unsupported multi-main-window command/navigation/search/draft semantics;
- `MacStartupView` keeps the main workspace behind a neutral `Checking BYOK Pro status…` state while StoreKit entitlement is unresolved, preventing a false Free/`Unlock Pro` flash;
- shared utility-sheet close controls now support Escape and explicit destination-aware accessibility labels.

Phase 3 implementation tail:

- `3475558` — Make macOS startup idempotent
- `91d4646` — Test idempotent macOS startup
- `f0b4360` — Use a single macOS main window
- `42c82bf` — Avoid unresolved entitlement UI during startup
- `0f89336` — Improve utility sheet close semantics
- `67396a7` — Record Phase 3 shell reliability implementation

## Validation state

The new code/tests have been statically reviewed, but **the Mac target and regression suite have not been executed in Xcode in this environment**.

Before treating the branch as functionally validated:

1. regenerate/refresh the Xcode project if required so all files under `Tests/BYOKmacTests` are included;
2. compile the macOS target and run the full Mac/shared regression suite;
3. smoke-test startup/retry/recovery/reset;
4. exercise provider, attachment, Project, Library, MCP, backup/import, Free/Pro, and Analytics workflows;
5. verify titlebar dragging, resize/minimize/full-screen, close/reopen, sidebar, Command-N/K/Period/Comma, Settings/Pro/utility windows, and Escape dismissal;
6. run a long generation while navigating secondary surfaces and confirm generation/runtime state remains stable;
7. launch in entitlement checking/Free/Pro states and verify no false Free gate or upsell appears while checking.

Any failure stays in its originating phase and should be fixed before release packaging.

## Next step

The branch is now at the **runtime validation gate**. There is no additional feature phase before validation; after the functional smoke matrix passes, move to the deliberately deferred release-packaging work.
