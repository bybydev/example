# Shared Layer Release Lock

Status: **frozen for the iOS 1.0 release cycle**.

The shared layer is considered complete enough to ship iOS. Until iOS 1.0 is released, do not expand the shared architecture or macOS product surface unless an iOS release blocker requires it.

## Locked boundary

`BYOKchatProviderCore` owns:

- `BYOKStorageEnvironment` and canonical storage layout
- storage bootstrap, schema validation, and migrations
- provider registry/workspace/accounts/runtime
- conversation index + lazy conversation shards
- shared file/blob storage
- library and projects
- MCP workspace/runtime/tool execution
- telemetry recorder composition
- backup/data portability
- `BYOKCoreServices`, the shared composition root consumed by iOS and the macOS sentinel

The iOS target owns:

- app/presentation models
- SwiftUI navigation and screens
- onboarding, purchases, themes, developer UI
- iOS startup/recovery presentation and background behavior

The macOS target remains a compile/runtime sentinel only. It may bootstrap and load `BYOKCoreServices`, but no real macOS product UI should be added during the iOS 1.0 release cycle.

## Allowed shared changes before iOS 1.0

Only make shared-layer changes for:

- an iOS build blocker
- data loss/corruption
- security or credential correctness
- crash/startup failure
- provider/chat correctness required for release
- an App Store rejection blocker

Do not do package decomposition, sync architecture, macOS feature work, broad refactors, or speculative cleanup before iOS 1.0 ships.

## Release direction

All normal development effort now moves to iOS release hardening, App Store validation, and launch readiness.
