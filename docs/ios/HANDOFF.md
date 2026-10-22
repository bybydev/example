# Live Inkribe iOS v1 handoff — 2026-10-22

P0–P7 and optional models are squash merged through PR #30, develop eb89f0fb3cd0f67054e6d29de2375342718c1651. The user's current request authorizes the previously deferred **V1.PRO** and AppFoundation premium themes. Work lives on feat/ios-pro-access-themes → develop; keep its PR open, no auto-merge.

**All 29 V1 acceptance items have source integration. None are claimed compilation/runtime/device verified.** See [phases/PRO.md](phases/PRO.md) for the exact approved offer and [handoffs/PRO.md](handoffs/PRO.md) for implementation, recovery behavior and pending user validation.

Free: 5 captioning minutes/week, basic caption look, 720p video, AF default theme. Pro: unlimited captioning, all existing caption fonts/templates/animations, 1080p and premium AF themes. Monthly $6.99; lifetime $24.99. Existing documents/styles/captions/export files and free editing/media/SRT remain available after expiry.

Current source uses pinned AppFoundation 0.1.8 for purchase lifecycle, live verified entitlements, contextual upsell/paywall/restore and theme picker/state. iOS has its own local StoreKit configuration and Debug simulator persistence. Mac is unchanged even though the approved monthly/lifetime product strings also exist in Mac's catalog. Live product configuration/prices and an actual Inkribe privacy destination remain release inputs; no store or website changes were made.

The repository owns a separate atomic weekly usage ledger and durable job reservations. Failed/cancelled work is released after terminal status; publication is charged exactly once with recognition-ID reconciliation. Accepted jobs survive expiry/reset, and pre-policy payloads remain readable. Default new export is 720p; access is checked before replacing the retained artifact. Theme changes affect app chrome, never footage or caption artwork.

Schema remains v5, reading v1–v4. Canonical timing, raw recognition and originals remain unchanged; retained-range preview/export mapping, bounded undo, serialized latest-draft saves, model selection/download/cache and export pins/delivery leases are retained. [MODELS.md](MODELS.md) and earlier handoffs retain these contracts. [handoffs/P7.md](handoffs/P7.md) records the previous source audit; its 28/29 accounting and Pro deferral are historical.

No builds/typechecks/tests, CI setup/triggers, generation, model downloads, inference, media exports, deployment or native/device/UI validation were performed. User runs [Pro scenarios](handoffs/PRO.md) and existing VALIDATION/P7 scenarios before release.

## Current naming and bundle correction — PR #33

The iOS source root is now Inkribe/ and the entry point is InkribeApp. Redundant IOS type/file prefixes are removed (the domain canvas is ProjectCanvas). Project specs, resource/StoreKit paths and source references follow the move. Both iOS configurations use com.hoangbkit.inkribe. Two legacy JobQueue adapters retain IOSSpeechJob/IOSExportJob as persisted type names; new work uses SpeechJob/ExportJob. No storage/default keys, encoded document/queue payload fields, model IDs, product IDs or Mac files change. Source review only; no builds/tests/generation/workflow/device actions. Keep #33 open.
