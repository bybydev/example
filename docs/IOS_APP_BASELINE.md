# ReadAloud iOS App Baseline

> Status: historical integration baseline used to establish ReadAloud 1.0.
> Use `CURRENT_ARCHITECTURE.md` and the current `project.yml` for the
> implemented app configuration.

## Purpose

ReadAloud should follow the established conventions used across Hoang's existing iOS apps instead of inventing a new app-shell/configuration pattern.

This baseline was derived from:

- Spokio iOS (`SpokioNano`, current `develop`)
- MiLove (`master`)
- Palette (`master`)

Use the common portfolio pattern where it applies, and prefer the **newer Spokio/AppFoundation conventions** when MiLove or Palette contain older infrastructure.

---

## Comparison

| Area | Spokio iOS | MiLove | Palette | ReadAloud baseline |
| --- | --- | --- | --- | --- |
| Minimum OS | iOS 26 | iOS 26 | iOS 26 | **iOS 26** |
| Device family | iPhone | iPhone | iPhone | **iPhone** |
| Mac Catalyst | No | No | No | **No** |
| Project generator | XcodeGen | XcodeGen | XcodeGen | **XcodeGen** |
| Generated Xcode project checked in | Yes | Yes | Yes | **Yes, owner-managed** |
| Package.resolved checked in | Yes | Yes | Yes | **Yes, owner-managed** |
| Swift | 6 | 5 legacy | 6 | **Swift 6** |
| Strict concurrency | complete | targeted legacy | complete | **complete** |
| AppFoundation | 1.6.4 | 0.1.14 legacy | 0.1.14 legacy | **current modern exact pin** |
| StoreKit config | Yes | Yes | Yes | **Yes** |
| Privacy manifest | Yes | Yes | Yes | **Yes** |
| Purchase simulation | Yes | Yes | Yes | **Yes** |
| Theme system | AppFoundation ThemeCatalog | app-specific legacy | AppFoundation ThemeCatalog | **AppFoundation ThemeCatalog** |
| Standard Plan settings | AppFoundation | AppFoundation | AppFoundation | **AppFoundation** |
| Debug developer tools | Yes | app-specific | Yes | **Yes** |
| App Store metadata in repo | release-specific | Yes | Yes | **Yes** |

---

## 1. Platform

ReadAloud 1.0 follows the portfolio default:

```
iOS 26+
iPhone
TARGETED_DEVICE_FAMILY = 1
SUPPORTS_MACCATALYST = NO
```

ReadAloud does **not support iPad**. The target remains iPhone-only; do not add iPad layouts, screenshots, device-family support, or iPad-specific navigation.

The old ReadAloud macOS prototype target is not part of 1.0.

---

## 2. XcodeGen and checked-in generated artifacts

Common repository shape:

```
project.yml                 source of truth
<App>.xcodeproj/            checked-in generated artifact
Package.resolved            checked-in resolved dependencies
```

Rules:

- edit `project.yml`, never hand-edit `project.pbxproj`
- generated Xcode project and `Package.resolved` are **owner-managed outputs**
- agents should not regenerate XcodeGen output or resolve packages unless explicitly asked
- commits may contain updated generated artifacts when the repository owner intentionally regenerates them
- Xcode Cloud/release infrastructure may rely on committed project/scheme/package-resolution state

ReadAloud's old statement that the generated project is intentionally not committed should be retired.

---

## 3. Modern project configuration

Use the modern parts of Spokio and Palette rather than legacy MiLove settings.

Baseline:

```
minimumXcodeGenVersion: 2.46.0
deploymentTarget:
  iOS: "26.0"

SWIFT_VERSION: 6.0
SWIFT_STRICT_CONCURRENCY: complete
DEVELOPMENT_TEAM: J458WW3452
CODE_SIGN_STYLE: Automatic
TARGETED_DEVICE_FAMILY: "1"
SUPPORTS_MACCATALYST: NO
ENABLE_PREVIEWS: YES
```

Use Debug and Release configurations.

Keep build/product identifiers in `Config/` xcconfig files when that improves reuse and release tooling, following MiLove/Palette.

---

## 4. Standard repository configuration

Prefer this shape:

```
Config/
├── Shared.xcconfig
├── Debug.xcconfig
├── Release.xcconfig
└── ReadAloud.storekit

ReadAloud/
├── App/
├── Core/
├── Features/
├── Services/
└── Resources/
    ├── Info.plist
    ├── PrivacyInfo.xcprivacy
    └── ReadAloud.entitlements   (when required)

AppStore/
├── config.yml
├── app/
└── versions/

ci_scripts/
└── ci_post_clone.sh

docs/
...
```

Not every folder must be populated on day one, but new infrastructure should fit this shape rather than creating another convention.


---

## Current shared package baseline

For ReadAloud implementation, prefer exact stable releases:

```yaml
AppFoundation:
  exactVersion: 1.6.4
EpubKit:
  exactVersion: 1.1.0
PDFKitAudio:
  exactVersion: 1.1.0
TextExtractor:
  exactVersion: 1.1.0
KokoroCoreML:
  exactVersion: 1.1.0
JobQueue:
  exactVersion: 1.0.0
```

`SwiftLame 1.0.0` is available but should remain absent until ReadAloud actually needs compressed audio export.

These versions were checked against each repository's latest tag, and `master` was identical to the stable tag when this baseline was recorded.

KokoroCoreML `1.1.0` already includes the executable fixture-model support needed by ReadAloud. Use the matching published fixture archive for fixture builds; do not regenerate it in ReadAloud.

---

## 5. AppFoundation

Use AppFoundation as the standard iOS app shell.

Do **not** copy MiLove/Palette's older AppFoundation version or compatibility wrappers merely because they exist.

Use AppFoundation `1.6.4` as the current baseline, or a newer explicitly reviewed exact stable release.

Pin it exactly.

### App root pattern

ReadAloud should follow the modern pattern:

```
@main
@MainActor
ReadAloudApp
├── PurchaseManager
├── ThemeManager
├── app-owned stores/runtime
│
└── RootView
    ├── .environment(purchaseManager)
    ├── .environment(themeManager)
    ├── .managesPurchases(purchaseManager)
    └── .appFoundationTheme(...)
```

App-specific state belongs in app-owned stores/services, not inside AppFoundation.

---

## 6. Purchase setup

Keep product configuration in one app-specific commerce namespace, similar to Spokio:

```
ReadAloudCommerce
├── product IDs
├── PurchaseConfiguration
├── simulated products
├── paywall configuration
├── celebration configuration
├── URLs
└── app-specific Pro limits/policies
```

Use:

- exact StoreKit product IDs
- local `.storekit` configuration for development
- AppFoundation `PurchaseManager`
- simulated products for deterministic debug/developer flows
- verified entitlement state for production access

Do not persist a separate production `hasPro` flag as entitlement truth.

Current release decision: lock only Kokoro voice selection (Heart is Free)
and extra themes. Projects, offline generation, speed overrides, prefetch and
regeneration are all available on Free. Future monetization changes require
explicit approval.

---

## 7. Themes

Use AppFoundation `ThemeCatalog` + `ThemeManager`, following modern Spokio/Palette.

Pattern:

- define a ReadAloud-specific catalog
- use Foundation themes as the base where appropriate
- select at least one free fallback theme
- mark premium themes through catalog access
- use `ThemePickerView`
- resolve theme against purchase entitlement
- preserve saved premium selection when entitlement becomes inactive; effective presentation falls back safely

Do not build a separate ReadAloud theme engine.

---

## 8. Standard Settings structure

ReadAloud Settings should follow the portfolio pattern:

```
Settings
├── Plan
│   └── ProPlanSettingsSection
├── Appearance
│   └── ThemePickerView
├── ReadAloud defaults
│   ├── Default Voice
│   ├── Default Speed
│   └── playback/generation preferences
├── App Data / Storage
├── Support
│   ├── Support
│   ├── Privacy
│   └── Terms
├── About
│   └── Version
└── Developer                 DEBUG only
    └── FoundationDeveloperView / app-specific tools
```

App-specific settings should be added around this shell rather than replacing it.

---

## 9. Privacy baseline

All three reference apps use a privacy manifest and declare no tracking.

ReadAloud should start from:

```
NSPrivacyTracking = false
NSPrivacyTrackingDomains = []
NSPrivacyCollectedDataTypes = []
```

Declare required accessed API reasons, including UserDefaults and any file-timestamp APIs actually used.

ReadAloud's local-first promise should remain compatible with an empty collected-data declaration unless a later explicitly enabled feature changes that.

### Analytics

Portfolio direction is privacy-first.

Analytics hooks may exist through AppFoundation, but ReadAloud analytics should be **disabled by default** unless explicitly enabled later.

Do not let analytics initialization create IDs, queues, or network traffic when disabled.

---

## 10. StoreKit and developer mode

Include a checked-in StoreKit configuration:

```
Config/ReadAloud.storekit
```

The shared scheme should select it for Debug run configuration.

DEBUG builds should provide useful developer tools, preferably through AppFoundation:

- simulated purchases
- reset simulated purchases
- replay onboarding if onboarding exists
- show paywall
- entitlement status
- ReadAloud-specific fixture/runtime diagnostics where useful

Developer-only controls must not leak into Release UI.

---

## 11. Info.plist and entitlements

Follow the modern Spokio iOS pattern: enable `GENERATE_INFOPLIST_FILE: YES` and retain `INFOPLIST_FILE: ReadAloud/Resources/Info.plist` as the app-specific input plist. Xcode generates standard bundle metadata from build settings and merges the explicit input plist.

Keep bundle identifier, executable, name, and versions in build settings rather than duplicating their standard `CFBundle*` keys in the input plist. Keep ReadAloud-specific shipping configuration in the explicit plist rather than accumulating every key in `project.yml`.

ReadAloud-specific requirements will include:

- display name
- launch/scene configuration
- background audio modes
- supported document/file declarations where needed
- any user-facing permission descriptions

Use an entitlements file only for capabilities ReadAloud actually needs.

Do not copy App Groups, widgets, share extensions, or notification capabilities from MiLove/Palette unless the product requires them.

---

## 12. App Store repository metadata

MiLove and Palette establish a useful shipping convention:

```
AppStore/config.yml
AppStore/app/
AppStore/versions/<version>/
```

ReadAloud should adopt the same structure before App Store submission.

Initial config:

```yaml
bundle_id: com.hoangbkit.readaloud
platform: IOS
```

Versioned descriptions, keywords, promotional text, release notes, screenshot configuration, and review notes belong here.

The final public app name can differ from the internal ReadAloud repo/target terminology.

---

## 13. Release and CI

### CI workflow contract

ReadAloud uses exactly three primary application workflows:

```
fast-ci.yml
full-ci.yml
release.yml
```

All are manual-only (`workflow_dispatch`) and branch/ref-aware. They must run against the selected dispatch ref and must never hardcode `master` or `develop`.

See `docs/CI_RELEASE.md` for the authoritative workflow contract.



Use the existing portfolio split:

### Development/CI

- deterministic fixture assets where large models are involved
- no production model downloads for ordinary fast checks
- checked-in generated project/schemes available to Xcode tooling
- XcodeGen remains the source of truth

### Manual build/release

Follow Spokio's modern resource choice pattern where useful:

```
resources:
  fixture
  real
```

Fixture builds are for fast development artifacts and may use Debug or Release optimization. Configuration is independent of resource mode; follow the explicit resource/distribution matrix in `docs/CI_RELEASE.md`.

App Store/TestFlight builds must use verified real Kokoro assets and reject fixture assets.

Use existing `mycli` / AppStore repository conventions rather than inventing a ReadAloud-only release system.

---

## 14. What is app-specific

Do not copy these merely because another app has them:

- MiLove widgets / App Group relationship storage
- Palette share extension / widgets / SwiftData choice
- Spokio custom voice recording
- Spokio Mac target
- app-specific backup formats
- app-specific Pro limits
- app-specific themes beyond reusable Foundation themes

ReadAloud-specific infrastructure includes:

- Kokoro model assets
- executable Kokoro fixture consumption
- document import
- `.readaloud` packages
- project queue/cache/audio
- background audio playback
- reader/player UI

---

## 15. ReadAloud implementation rule

When there are multiple ways to implement generic iOS app infrastructure:

1. inspect the current Spokio iOS implementation first
2. inspect AppFoundation current APIs
3. use MiLove/Palette to identify portfolio conventions
4. implement only ReadAloud-specific differences locally

This prevents ReadAloud from becoming a fourth independent app-shell architecture.
