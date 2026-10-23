# Live Inkribe iOS v1 handoff — 2026-10-22

## Settings and AppFoundation follow-up — PR #34

Crown flow follow-up: the Projects crown uses Spokio's single Pro-sheet route. Free users see AF ProPaywallView; active Pro users see AF ProCelebrationView. A successful purchase or restore that grants Pro presents celebration after the paywall finishes dismissing; cancelling while still Free does not celebrate. The crown switches between outline/filled according to access. Settings' plan action uses the same root route, and Debug Developer Tools can replay both real screens. Source review only; purchase/restore/dismissal/device checks remain unrun.

The user requested iOS Settings matching Spokio, with AppFoundation paywall, simulated purchases and Developer Tools. The gear now pushes a native Settings list with AF's Pro plan/restore/subscription actions, weekly caption usage, inline theme picker, speech-model and storage sheets, support/legal links, version and a Debug Developer Tools destination. Appearance previews remain disabled and locked themes still show the contextual upsell.

AppFoundation is pinned to 1.6.4, matching Spokio iOS. The real paywall uses AF ProPaywallView and the same shared PurchaseManager used by gates, settings, theme access and AF FoundationDeveloperView. Four PurchaseFeature definitions feed paywall, plan comparison and upsells. Existing monthly/lifetime IDs, local prices, persistence keys and live expiry rules are retained. Debug simulation uses AF's effective entitlement because its simulated monthly records have no real subscription expiry; Release still uses live StoreKit and contains no Developer Tools/simulation controls.

Settings → Developer Tools provides AF's purchase mode toggle, simulated entitlement/catalog/price editing, pending/cancel/failure/restore controls, diagnostics and a replay of the real paywall. It starts in live mode unless the existing launch environment explicitly opts into simulation. The user explicitly requested a dummy privacy URL: https://example.com/inkribe/privacy is centralized in Commerce for Settings and paywall. Apple's standard EULA remains the terms destination. Replace the dummy before public release.

Source/API review only. No agent builds/typechecks/tests, UI/device validation, workflow runs, project generation or downloads. User validation remains: compact iPhone Settings/navigation and sheet dismissal, Debug simulated Free/monthly/lifetime/reset and failure flows, shared gate/theme updates, and live StoreKit purchase/restore.

P0–P7 and optional models are squash merged through PR #30, develop eb89f0fb3cd0f67054e6d29de2375342718c1651. The user's current request authorizes the previously deferred **V1.PRO** and AppFoundation premium themes. Work lives on feat/ios-pro-access-themes → develop; keep its PR open, no auto-merge.

**All 29 V1 acceptance items have source integration. None are claimed compilation/runtime/device verified.** See [phases/PRO.md](phases/PRO.md) for the exact approved offer and [handoffs/PRO.md](handoffs/PRO.md) for implementation, recovery behavior and pending user validation.

Free: 5 captioning minutes/week, basic caption look, 720p video, AF default theme. Pro: unlimited captioning, all existing caption fonts/templates/animations, 1080p and premium AF themes. Monthly $6.99; lifetime $24.99. Existing documents/styles/captions/export files and free editing/media/SRT remain available after expiry.

Current source uses pinned AppFoundation 1.6.4 for purchase lifecycle, live verified entitlements, contextual upsell/paywall/restore and theme picker/state. iOS has its own local StoreKit configuration and Debug simulator persistence. Mac is unchanged even though the approved monthly/lifetime product strings also exist in Mac's catalog. Live product configuration/prices and an actual Inkribe privacy destination remain release inputs; no store or website changes were made.

The repository owns a separate atomic weekly usage ledger and durable job reservations. Failed/cancelled work is released after terminal status; publication is charged exactly once with recognition-ID reconciliation. Accepted jobs survive expiry/reset, and pre-policy payloads remain readable. Default new export is 720p; access is checked before replacing the retained artifact. Theme changes affect app chrome, never footage or caption artwork.

Schema remains v5, reading v1–v4. Canonical timing, raw recognition and originals remain unchanged; retained-range preview/export mapping, bounded undo, serialized latest-draft saves, model selection/download/cache and export pins/delivery leases are retained. [MODELS.md](MODELS.md) and earlier handoffs retain these contracts. [handoffs/P7.md](handoffs/P7.md) records the previous source audit; its 28/29 accounting and Pro deferral are historical.

No builds/typechecks/tests, CI setup/triggers, generation, model downloads, inference, media exports, deployment or native/device/UI validation were performed. User runs [Pro scenarios](handoffs/PRO.md) and existing VALIDATION/P7 scenarios before release.

## Current naming and bundle correction — PR #33

The iOS source root is now Inkribe/ and the entry point is InkribeApp. Redundant IOS type/file prefixes are removed (the domain canvas is ProjectCanvas). Project specs, resource/StoreKit paths and source references follow the move. Both iOS configurations use com.hoangbkit.inkribe. Two legacy JobQueue adapters retain IOSSpeechJob/IOSExportJob as persisted type names; new work uses SpeechJob/ExportJob. No storage/default keys, encoded document/queue payload fields, model IDs, product IDs or Mac files change. Source review only; no builds/tests/generation/workflow/device actions. Keep #33 open.
