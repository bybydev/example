# BYOKchat iOS + macOS Development Review — 2026-09-08

**Reviewed branch:** `develop`  
**Reviewed head:** `b39661c50c109e30b48c361ae95a0248cfde2c9d`  
**Current execution decision:** finish and stabilize the macOS app first. iOS work is intentionally deprioritized until the Mac app is functionally dependable.

This file is the earlier cross-platform snapshot. The active implementation plan and Phase 1 status now live in `Documentation/macOS-v1.0-Deep-Review-2026-09-08.md` and in PR #21.

Do not use the older cross-platform priority ordering below to override the current Mac-first plan.

---

## Archived cross-platform review

BYOKchat is no longer an iOS-only product in implementation terms. The shared `BYOKchatProviderCore` is the strongest and most mature part of the codebase, and both applications now sit on the same provider, conversation, storage, project, MCP, telemetry, portability, and Pro-policy foundation.

The iOS target is in a late-stage / release-candidate phase. Its major product surfaces are implemented, the repository already contains an iOS 1.0 release checklist, and the remaining release work is dominated by build validation, physical-device smoke testing, StoreKit/App Store verification, and regression coverage rather than missing product architecture.

The macOS target has advanced quickly. PR #19 brought the Mac product to broad functional parity across Library, Projects, MCP, Providers, Analytics, Settings, onboarding, and purchase flows. PR #20 then replaced the main navigation/titlebar behavior with a custom macOS shell. That makes macOS best described as a **feature-complete beta entering stabilization**.

The current product decision supersedes the original review recommendation: **work on macOS functional correctness first; do not spend current implementation time on iOS release work, App Store screenshots/metadata, or packaging polish.**
