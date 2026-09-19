# Inkribe v1 — MacAppFoundation Integration

## Current implementation status

PR #12 completes all four previously deferred MacAppFoundation Pro surfaces against a centralized policy:

- `ProPaywallView` is the single purchase surface opened from the titlebar plan button, Settings → Plan, contextual upsells, and gated app-menu subtitle export;
- `ProUpsellView` is used for contextual Local AI, batch-import, and subtitle-export upgrade moments;
- `ProBadge` marks locked AI actions, batch import, and subtitle export without labeling Free features as premium;
- MAF gate primitives are used at action boundaries, including `ProGateButton` for multi-file import, while `PremiumAccessPolicy` preserves existing user content after entitlement loss.

The locked v1 Pro capabilities are:

1. Local AI Tools — Clean, Polish, Summarize, Notes, Action Items.
2. Batch Transcription — multi-file Finder selection / drag-drop import into the persistent queue.
3. Subtitle Export — SRT and WebVTT.

Free retains recording, single-file transcription, Library/editor/playback/search, Copy/TXT/Markdown, and access to existing local content.

The paywall currently uses two explicit development placeholders: `https://example.com/inkribe/terms` and `https://example.com/inkribe/privacy`. Replace both before App Store submission.

First-launch onboarding is also fully wired through MAF `OnboardingState`, `OnboardingWindow`, `OnboardingView`, shared theming, and Developer Tools replay.

## Decision

Inkribe v1 must use the latest tagged release of `hoangbkit/MacAppFoundation` available when implementation begins. At planning time, the latest tag is **1.0.0**.

For reproducible builds, `project.yml` should pin the resolved latest tag exactly rather than track a branch or floating range. Phase 0 must re-check the repository tags before implementation and update the pin if a newer stable tag exists.

Current XcodeGen package shape:

```yaml
packages:
  MacAppFoundation:
    url: https://github.com/hoangbkit/MacAppFoundation.git
    exactVersion: 1.0.0
```

Link the `MacAppFoundation` product into the Inkribe app target and test targets where needed.

MacAppFoundation 1.0.0 requires macOS 15+ and Swift 6.2+, which matches Inkribe's planned macOS 15+ baseline.

## Ownership boundary

MacAppFoundation is shared infrastructure, not the Inkribe application shell.

**Inkribe owns:**

- the custom two-column main window shell
- the full-height expanded-sidebar divider and animated main-titlebar sidebar toggle
- Library / Record / Import / Transcript Editor navigation
- transcription and AI workflows
- app-specific Settings pane contents
- product-specific onboarding content
- Pro feature policy and copy
- paywall presentation decisions

**MacAppFoundation owns/reuses:**

- `MacAppThemeStore` and semantic theme environment
- `MacAppSettingsView` / `MacAppSettingsRouter`
- `PurchaseManager` / StoreKit 2 entitlement lifecycle
- `ProPaywallView`
- `ProPlanButton`
- `ProBadge`
- `ProUpsellView`
- Pro gate/locked-feature primitives where useful
- `OnboardingState`, `OnboardingView`, and `OnboardingWindow`
- Debug StoreKit simulation / Developer Tools where useful for commerce testing

Do not replace the custom Inkribe main shell with a framework navigation/window abstraction.

---

## Shared root state

Create one app-scoped instance of each shared foundation object:

```text
InkribeApp
├── MacAppThemeStore
├── PurchaseManager
├── MacAppSettingsRouter
└── OnboardingState
```

The same `MacAppThemeStore` must be injected into every scene that uses framework visuals:

- main Inkribe window
- onboarding window
- Settings scene
- Pro paywall window/sheet
- upsell surfaces
- Developer Tools in Debug

The main app root attaches MacAppFoundation purchase lifecycle management so verified StoreKit state remains the source of truth for Pro authorization.

---

## Themes

Use `MacAppThemeStore` from the beginning, before custom shell styling is finalized.

Requirements:

- all custom Inkribe shell colors should derive from MacAppFoundation semantic theme roles rather than hard-coded light/dark values
- sidebar, main canvas, surfaces, separators, hover/selection states, titlebar controls, transcript editor, player/status bar, dialogs, paywall, onboarding, and Settings must react to one shared theme store
- expose Appearance through the framework-provided Settings pane
- choose a curated subset of built-in themes for v1 rather than exposing every theme automatically unless product design calls for it
- theme switching must update every open scene consistently
- shell snapshot/UI tests should cover at least System plus representative light and dark themes

The custom shell geometry remains Inkribe-owned; only the visual semantic palette comes from MacAppFoundation.

---

## Settings

Use `MacAppSettingsView` as the actual macOS Settings scene.

The Settings item in the Inkribe sidebar should **open the Settings scene**, not navigate the main content pane to a home-grown Settings screen.

Recommended v1 flat pane composition:

```text
General
Transcription
AI Cleanup
Storage
Appearance      ← MacAppFoundation built-in
Plan            ← MacAppFoundation built-in
About
```

Exact app-specific panes may change as features stabilize, but Appearance and Plan should use MacAppFoundation's built-ins rather than duplicate UI.

Use one `MacAppSettingsRouter` so other surfaces can route directly to a pane. In particular:

- Pro user clicking the main titlebar plan control → open Settings on **Plan**
- app menu Settings command → open the last/default pane
- upgrade-related Settings actions can route to Plan

Keep Settings as a separate native macOS scene with its own framework-provided themed shell.

---

## Onboarding

Use MacAppFoundation's onboarding infrastructure rather than building a second onboarding shell.

Use:

- `OnboardingState` for persistent progress/completion
- `OnboardingWindow` for launch behavior and dedicated transient onboarding window
- `OnboardingView` for the framework-owned footer/action layout
- Inkribe-owned content for every onboarding page

The main Inkribe window should be suppressed on first launch while onboarding is active, then become the normal launch destination after completion.

Shipping onboarding content:

1. **Welcome** — private local speech-to-text and durable transcript workspace.
2. **Create** — Record / Import / Review workflow.
3. **Privacy** — bundled local Whisper/Qwen processing with no account or API key for the core workflow.
4. **Ready** — enter the main Inkribe workspace.

Onboarding does not pre-request microphone permission; recording requests access only when the user actually starts recording.

Do not add a model-download step because production models are bundled.

Onboarding must use the same shared `MacAppThemeStore` as the rest of the app.

---

## Pro / commerce foundation

Use one app-scoped `PurchaseManager` configured with Inkribe's StoreKit product IDs and registered Pro feature descriptions.

The exact pricing/product mix and free-vs-Pro feature matrix should remain app-level product decisions, but the plumbing must exist in v1 from the beginning.

Requirements:

- verified StoreKit entitlement state is the only production source of truth
- support purchase + restore
- support trial/introductory-offer UI automatically when the configured App Store product is eligible
- use MacAppFoundation Debug simulation during development and UI testing
- never persist a separate app-owned `hasPro` boolean for authorization

---

## ProPlanButton placement

Use `ProPlanButton` in the **main titlebar region**, on the right side with page-level actions.

It must obey the Inkribe shell geometry:

```text
┌───────────────────┬──────────────────────────────────────────────────────────┐
│ ● ● ●          ◀  │ Library                   Search   [Unlock Pro]    +     │
├───────────────────┼──────────────────────────────────────────────────────────┤
```

Rules:

- it never appears above the sidebar column
- it moves naturally with main titlebar layout, not with the sidebar toggle
- Free user action opens the Inkribe Pro paywall
- Pro user action opens Settings directly on the Plan pane through `MacAppSettingsRouter`
- entitlement state/active plan text comes from `PurchaseManager`

---

## ProPaywallView

Use `ProPaywallView` rather than building a custom StoreKit purchase screen.

Inkribe owns:

- presentation style/window ID
- title/subtitle
- feature copy
- highlighted/default product choice
- Terms URL
- Privacy URL
- purchase/restore completion behavior

MacAppFoundation owns StoreKit-aware pricing, plans, trial/intro presentation, purchase/restore state, Redeem Code support, and entitlement updates.

The paywall must receive the same shared `MacAppThemeStore` as the main app.

---

## ProBadge

Use `ProBadge` consistently on premium-only actions or settings rather than inventing Inkribe-specific premium badges.

Appropriate placements may include:

- premium AI actions
- premium export/workflow actions if the final entitlement matrix gates them
- Settings controls that require Pro
- any future premium model/performance option

Do not badge everything. Only display it where the user needs to understand why an action is gated.

---

## ProUpsellView

Use `ProUpsellView` for contextual upgrade moments rather than immediately throwing every Free-user interaction into the full paywall.

Intended flow:

```text
User hits Pro limit / locked workflow
        ↓
contextual ProUpsellView
        ├── Unlock Pro → ProPaywallView
        └── Continue Free / Cancel → return to current workflow
```

The app supplies product-specific copy and benefits. The framework supplies the themed reusable surface.

This is especially useful for limits where the Free workflow remains usable after dismissing the upsell.

---

## Pro gating policy

The v1 Free/Pro entitlement matrix is centralized in `InkribeProCapability`; do not scatter additional `hasPro` policy through feature code.

The three v1 capability IDs are `local-ai`, `batch-import`, and `subtitle-export`. New premium capabilities must be added to that centralized policy rather than introduced as ad-hoc checks.

Prefer MacAppFoundation gating primitives (`ProGate`, `ProGateButton`, locked overlays/popovers) where they fit. Direct `purchaseManager.hasPro` checks are acceptable for domain decisions that do not map cleanly to a reusable view gate.

Existing user-created recordings/transcripts should never become inaccessible merely because entitlement changes. If creation/processing limits are gated, keep previously created local content readable/editable/exportable according to the final product policy.

---

## Phase integration into the existing v1 plan

### Phase 0 — Repository and build foundation

Add:

- resolve latest MacAppFoundation tag and pin it exactly in XcodeGen
- link the package product
- create shared `MacAppThemeStore`, `PurchaseManager`, `MacAppSettingsRouter`, and `OnboardingState`
- add StoreKit configuration for local testing
- confirm macOS 15 / Swift 6.2 compatibility

### Phase 1 — Custom macOS shell and navigation

Add:

- style the entire custom shell using MacAppFoundation semantic theme roles
- add `ProPlanButton` to the main titlebar region
- sidebar Settings row opens the separate `MacAppSettingsView` scene
- verify all shell states across representative themes

### Early foundation work before core STT feature phases

Add:

- MacAppFoundation onboarding window + Inkribe-owned onboarding pages
- themed Settings scene with app panes + built-in Appearance/Plan panes
- paywall window/surface
- Pro upsell routing
- shared entitlement routing/gating service or configuration

This infrastructure should exist before UI-heavy feature work so new controls naturally inherit themes and Pro behavior.

### Phase 6 — Offline AI cleanup and text tools

Add:

- use `ProBadge`, `ProUpsellView`, and/or gate primitives for any AI tools selected as Pro
- keep AI inference offline regardless of entitlement state
- entitlement checks only control access; they never change the local inference privacy model

### Phase 8 — Settings, performance, and compatibility

Replace the original assumption of a custom Settings screen with MacAppFoundation `MacAppSettingsView`.

Add app panes for the finalized recording/transcription/AI/storage options and reuse built-in Appearance + Plan panes.

### Phase 9 — Test suite / release hardening

Add tests for:

- Free vs Pro titlebar `ProPlanButton` behavior
- plan button routing: Free → paywall, Pro → Settings/Plan
- purchase success, cancellation, pending, failure, and restore using Debug simulation/StoreKit testing
- onboarding first launch, resume, completion, and replay behavior
- Settings pane routing
- Appearance theme persistence and synchronization across main window, onboarding, Settings, paywall, and upsell
- `ProBadge` visibility where configured
- `ProUpsellView` primary/secondary routing
- Release build uses live StoreKit rather than Debug simulator
- existing local transcript access does not regress when entitlement changes

---

## V1 acceptance criteria for MacAppFoundation integration

Inkribe v1 is not complete until:

1. The latest stable MacAppFoundation tag is pinned exactly in the generated project configuration.
2. The custom main window is fully themed through one shared `MacAppThemeStore` without surrendering Inkribe's custom shell geometry.
3. First launch uses MacAppFoundation onboarding infrastructure with Inkribe-owned content.
4. Settings uses `MacAppSettingsView` and includes framework Appearance + Plan panes.
5. The main titlebar uses `ProPlanButton` in the main-column region only.
6. Free users can reach the themed `ProPaywallView`; Pro users can route directly to Settings → Plan.
7. Premium surfaces use framework `ProBadge` / `ProUpsellView` / gate primitives where appropriate.
8. Purchases/restores and Pro state come from verified `PurchaseManager` StoreKit state.
9. Themes stay synchronized across every app/framework scene.
10. Debug commerce simulation is testable without leaking simulated entitlement logic into Release builds.
