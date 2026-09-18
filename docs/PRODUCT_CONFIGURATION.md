# Inkribe v1 — Product Configuration

This document is the authoritative v1 identity and StoreKit catalog configuration for Inkribe.

## App identity

- Product name: `Inkribe`
- Bundle identifier: `com.hoangbkit.inkribe`

Use the bundle identifier consistently in XcodeGen, signing, StoreKit testing, App Store Connect, entitlements, and any app-specific identifiers derived from the bundle ID.

## Pro catalog

Inkribe v1 has exactly three Pro products:

| Plan | Product ID | Target price |
| --- | --- | ---: |
| Monthly | `com.hoangbkit.inkribe.pro.monthly` | $4.99 |
| Yearly | `com.hoangbkit.inkribe.pro.yearly` | $24.99 |
| Lifetime | `com.hoangbkit.inkribe.pro.lifetime` | $49.99 |

The listed prices are the intended base price points for the initial App Store configuration. StoreKit-provided localized prices are always authoritative in user-facing UI; do not hard-code price strings into the app.

## StoreKit product types

- `com.hoangbkit.inkribe.pro.monthly` — auto-renewable subscription, monthly period
- `com.hoangbkit.inkribe.pro.yearly` — auto-renewable subscription, yearly period
- `com.hoangbkit.inkribe.pro.lifetime` — non-consumable lifetime Pro unlock

Monthly and yearly should belong to the same subscription group in App Store Connect. Lifetime is a separate non-consumable product that grants the same Pro entitlement permanently.

## MacAppFoundation configuration

Use the product IDs in this order so the shared commerce surfaces have a deterministic catalog order:

```swift
let purchaseConfiguration = PurchaseConfiguration(
    productIDs: [
        "com.hoangbkit.inkribe.pro.monthly",
        "com.hoangbkit.inkribe.pro.yearly",
        "com.hoangbkit.inkribe.pro.lifetime"
    ],
    preferredProductID: "com.hoangbkit.inkribe.pro.yearly",
    features: [
        // Local AI Tools
        // Batch Transcription
        // Subtitle Export
    ]
)
```

Use **Yearly** as the initial preferred/highlighted recurring plan in the paywall unless product strategy changes before release. `PurchaseManager` remains the only production source of truth for entitlement state.

## V1 Free / Pro policy

The shipping policy is centralized in `InkribeProCapability`.

| Capability | Free | Pro |
| --- | --- | --- |
| Local AI Tools | — | Clean, Polish, Summarize, Notes, Action Items |
| Import | Single file | Multi-file batch import |
| Text export | Copy, TXT, Markdown | Copy, TXT, Markdown, SRT, WebVTT |
| Existing transcripts | Read/edit/play/export Free formats | Same + Pro actions |

Entitlement changes never make existing local transcript documents unreadable. Previously saved AI-derived documents remain accessible; the entitlement controls creation of new Pro outputs/actions.

## Paywall behavior

`ProPaywallView` should present all three products using StoreKit values:

```text
Monthly     $4.99 / month
Yearly      $24.99 / year
Lifetime    $49.99 once
```

User-visible pricing must come from the loaded `StoreProduct.displayPrice` / StoreKit metadata so currency and localization remain correct. The strings above are planning targets and StoreKit-test defaults, not UI constants.

Lifetime ownership takes precedence when resolving the active plan if a user somehow also has an active recurring subscription, following MacAppFoundation's entitlement behavior.

## Local StoreKit testing

Phase 0 should add an Inkribe `.storekit` configuration containing the exact three product identifiers and initial price targets above so MacAppFoundation's live StoreKit-testing path and Debug simulator can represent the same catalog.

The Debug simulator defaults should mirror:

```text
Monthly   4.99
Yearly   24.99
Lifetime 49.99
Preferred plan: Yearly
```

Tests must cover monthly, yearly, lifetime, and mixed recurring+lifetime entitlement resolution.

## XcodeGen

The application target must use:

```yaml
PRODUCT_BUNDLE_IDENTIFIER: com.hoangbkit.inkribe
```

Debug builds may use a distinct debug bundle identifier only if needed for side-by-side installation, but Release/App Store builds must use exactly `com.hoangbkit.inkribe`.

## V1 acceptance criteria

- Release bundle ID is exactly `com.hoangbkit.inkribe`.
- StoreKit catalog contains exactly the monthly, yearly, and lifetime Pro IDs defined above.
- Initial intended price points are $4.99 monthly, $24.99 yearly, and $49.99 lifetime.
- User-facing prices are rendered from StoreKit rather than hard-coded strings.
- Yearly is the initial preferred plan.
- Lifetime grants permanent Pro and wins active-plan resolution over an overlapping recurring entitlement.
- Local StoreKit configuration and MacAppFoundation Debug simulation use the same IDs and initial catalog values.
