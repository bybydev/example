# Pro phase source handoff

## Settings and AppFoundation follow-up — PR #34

The user requested iOS Settings matching Spokio, with AppFoundation paywall, simulated purchases and Developer Tools. The gear now pushes a native Settings list with AF's Pro plan/restore/subscription actions, weekly caption usage, inline theme picker, speech-model and storage sheets, support/legal links, version and a Debug Developer Tools destination. Appearance previews remain disabled and locked themes still show the contextual upsell.

AppFoundation is pinned to 1.6.4, matching Spokio iOS. The real paywall uses AF ProPaywallView and the same shared PurchaseManager used by gates, settings, theme access and AF FoundationDeveloperView. Four PurchaseFeature definitions feed paywall, plan comparison and upsells. Existing monthly/lifetime IDs, local prices, persistence keys and live expiry rules are retained. Debug simulation uses AF's effective entitlement because its simulated monthly records have no real subscription expiry; Release still uses live StoreKit and contains no Developer Tools/simulation controls.

Settings → Developer Tools provides AF's purchase mode toggle, simulated entitlement/catalog/price editing, pending/cancel/failure/restore controls, diagnostics and a replay of the real paywall. It starts in live mode unless the existing launch environment explicitly opts into simulation. The user explicitly requested a dummy privacy URL: https://example.com/inkribe/privacy is centralized in Commerce for Settings and paywall. Apple's standard EULA remains the terms destination. Replace the dummy before public release.

Source/API review only. No agent builds/typechecks/tests, UI/device validation, workflow runs, project generation or downloads. User validation remains: compact iPhone Settings/navigation and sheet dismissal, Debug simulated Free/monthly/lifetime/reset and failure flows, shared gate/theme updates, and live StoreKit purchase/restore.

## Outcome

V1.PRO is source-integrated on feat/ios-pro-access-themes from merged develop eb89f0f. All 29 V1 acceptance items now have source integration, with compilation/runtime/user validation still unrun. Earlier Pro deferral is historical. Leave the new PR targeting develop open until explicit merge instruction.

## Source map

| Owner | Entry points / responsibility |
|---|---|
| Pro/Commerce.swift | Two approved IDs, 5-minute policy, four-benefit comparison/paywall, isolated Debug simulator catalog |
| Pro/ProAccess.swift | AF verified monthly/lifetime state, expiration refresh timer, centralized style/action access |
| Pro/CaptionAllowance.swift | Validated schema-1 weekly usage, reservation model, full canonical audio duration and whole-second rounding |
| Storage/ProjectRepository.swift | Sole ledger owner; reserve/authorize/reconcile/finish/release; atomic publication and recovery |
| Transcription/TranscriptionController.swift and LocalTranscriber.swift | Serialize authorization/reconciliation, reserve before enqueue, captured policy in durable job, charge after saved result |
| Editor/EditorSession.swift and CaptionStylePanel.swift | Gate new premium fonts/effects before mutation, free Basic reset, contextual upsell, preserve existing style/edit/undo |
| Export/ExportController.swift, IOSExportRequest.swift, ExportView.swift | Default 720p; gate new 1080p before retained artifact replacement; saved job retry/delivery unchanged |
| Pro/ProViews.swift and App/SettingsView.swift | AF ProPaywallView/upsell, native Settings plan/usage/restore/themes, Debug AF Developer Tools, support and app surface tokens |
| App/InkribeApp.swift, ProjectsView.swift and other iOS surfaces | App-wide purchase lifecycle/transaction refresh and theme synchronization; Pro/Appearance entries |
| Resources/Inkribe.storekit | iOS-only local monthly $6.99 and lifetime $24.99 offers |

## Allowance and interruption contract

Application Support/InkribeIOSProjects/Usage/caption-allowance-v1.json stores weekStart, used seconds, charged operation IDs and reservations (job/project/revision/week/seconds). It is separate from schema-v5 projects, cache cleanup and Trash. Reads are capped at 1 MiB and validated; writes are atomic. Corrupt/unwritable quota storage shows retry/error rather than silently granting a new allowance or destroying projects.

Weeks start Monday 00:00 UTC. Each free job reserves ceil(sum of canonical audio-bearing clip source durations), at least one second, up to the remaining 300 seconds. Gaps, silent-only clips and overlapping decode context do not add usage; trims do not reduce recognition work. Clock rollback does not reset the stored week. Advancing a week clears charged/used totals while keeping earlier accepted reservations valid; old-week work completes against its original grant, not the new week's allowance. This is local policy, not a tamper-resistant/server quota.

One controller guard serializes ledger reconciliation and request publication. It rechecks queue/model state after suspensions, disables removal during authorization and protects accepted model dependencies. A reservation is durable before queue enqueue. Terminal failed/cancelled or unpublished orphan jobs release reserved time. A saved recognition ID is the idempotency receipt: if charging fails after document publication, the reservation remains; reconcile, acknowledgment retry or Trash settlement finishes it once without native work or a second charge. Trash operations settle published receipts before removal. Queue-storage failure blocks reconciliation until recovery so unknown pending jobs do not lose authorization.

Payload requiresAllowance is optional for compatibility: nil is accepted pre-policy work, false is a Pro grant, true requires its matching reservation. Accepted/recovered jobs can finish after Pro expiry or reset. Explicit new retries without a saved result request current access/allowance; a retry of an already published result only acknowledges it. Free and Pro results remain identical document data.

## Access and themes

AF PurchaseManager observes verified StoreKit updates, prepares on app entry and refreshes on foreground; the app refreshes at new speech/export requests and schedules subscription expiration refresh. No user-defaults Pro flag is trusted. Lifetime remains active until revocation; monthly access requires an unexpired verified entitlement. AF handles pending/cancel/error/restore/product loading and localized live prices.

Free can change basic style properties and edit the color/size/position of an existing premium look; a different premium font/effect requires Pro. Reset/undo/redo, project opening, captions, all text/timing/media edits and SRT stay available after expiry. Existing authorized export retries and completed-file delivery remain available; new 1080p requests need Pro. Choosing an app theme uses AF's actual picker and state manager; Rose is free, Sunset/Lavender/Midnight/Paper/Champagne require Pro. Previews are disabled. On expiry AF resolves the free fallback while retaining the saved selection for future verified access. Surfaces, tint and timeline selection follow AF; footage and rendered caption colors do not change with app theme.

## Release inputs and preservation

- The approved monthly/lifetime strings also exist in Mac's local catalog, with different local prices. This phase preserves Mac source/configuration/catalog completely, and does not resolve or alter cross-platform App Store product ownership. Verify the intended iOS App Store Connect records and live USD prices ($6.99/month, $24.99 lifetime) before release. Source/local StoreKit configuration does not create or reprice live products.
- The live paywall uses returned StoreKit prices; unavailable products show AF retry/error. The iOS StoreKit file is already referenced by the existing scheme. AF in-process simulation is opt-in Debug only, using a separate iOS persistence key; Release uses live StoreKit. No production Pro bypass.
- Apple's standard EULA is linked for terms. No verified Inkribe privacy page exists in the inspected project/site sources; PR #34 now uses an explicit dummy privacyURL at the user's request. Supply the actual Inkribe privacy destination before production submission. No website/store/account/signing changes were made.
- The original Pro phase changed no project.yml or dependency version. PR #34 upgrades AppFoundation in project.yml to 1.6.4 for Developer Tools. No shared-package source, generated project, entitlement/App Group, model packaging or Mac source is changed by this settings follow-up. Project schema remains v5 and export manifest remains v1.

## User validation (not run)

1. Regenerate/build yourself. Exercise local StoreKit then real Sandbox offers/restore, canceled and pending purchases, failed load/restore, offline relaunch, refund/revocation and accelerated monthly expiry. Confirm only approved plans and localized live billing/renewal copy. Lifetime must unlock the same four benefits.
2. Free usage: successful 60-second job leaves 240 seconds; cancel/fail/retry does not charge failed work; simultaneous taps cannot over-reserve. A >remaining/full >300-second project offers Pro before native work. Multi-clip audio counts its canonical duration despite trimming. Pro ignores the weekly cap.
3. Terminate before/after reservation/enqueue, recognition publication, charge and queue acknowledgment. Reopen/retry must preserve saved captions, release true orphans and charge once. Exercise full disk/corrupt ledger/job store, storage retry and Trash/empty Trash after a published result. Weekly rollover/old queued work/clock rollback must follow the contract above.
4. Choose all caption fonts/effects/templates as Pro; expire access with an existing premium project. Reopen, edit text/timing/basic style properties, reset/undo and export 720p/SRT; selecting a different premium look offers the AF upsell and leaves data unchanged. Repeat for new 1080p versus saved export retry/delivery.
5. Free default theme and locked premium AF picker → contextual upsell → AF paywall; purchase/restore applies verified access. Choose each dark/light premium theme, relaunch, expire/revoke, restore. Confirm surfaces/controls/timeline respond while footage/caption output remains identical. Check small iPhone, Dynamic Type, VoiceOver and nested sheet dismissals.

Source inspection only. No builds/typechecks/tests, CI operations, project generation, model downloads, native inference, media export, UI/device validation or deployment were performed. No runtime pass is claimed.
