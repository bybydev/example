# App Store Screenshots

BYOKchat has two complementary, Debug-only screenshot workflows. Use **AppFoundation Screenshot Studio** for the curated five-image App Store campaign and the reviewer paywall reference; keep the separate UI-test captures for validating actual production screens.

## AppFoundation Screenshot Studio — five plus one

Open the iOS Debug app and navigate to **Settings → Developer Tools → Screenshot Studio**. Screenshot Studio is backed by AppFoundation and supports full-set carousel preview and batch PNG export. No API keys, network requests, live StoreKit products, or personal conversation data are required to render these scenes.

The registered order is intentional:

| # | ID | Story | AppFoundation composition |
|---|---|---|---|
| 01 | `chat` | Chat With Your Favorite Models — reasoning, files, streaming and tools | Hero |
| 02 | `providers` | Bring Your Own API Keys — direct connections | Hero |
| 03 | `mcp` | Connect Powerful Tools — remote MCP and approvals | Hero |
| 04 | `projects` | Organize Your Projects — chats, prompts and files | Hero |
| 05 | `analytics` | Track Usage & Costs — local usage and performance | Hero |
| 06 | `pro` | BYOK Pro reviewer paywall | Full-canvas production `ProPaywallView` template |

- The five feature scenes use the app's Midnight palette by default, the full-width AppFoundation Hero template, a consistent sculpted app icon, and deterministic screenshot-specific example content. The icon is shown without repeating the app name above every headline.
- **Static scene boundary:** Product screenshots must use only value-driven SwiftUI primitives or screenshot-only stateless components. Do not embed shipping chat/message/composer views that depend on `@Environment(AppModel.self)`, `@Environment(BYOKToastCenter.self)`, persistent stores, navigation, `@State`, asynchronous work, clipboard actions, or side effects. The studio's `@Observable` settings are allowed for its controls; the product scenes merely read their supplied theme and example data.
- **Lazy paywall exception:** The production AppFoundation paywall needs its own screenshot-preview `PurchaseManager`. It is isolated inside `BYOKScreenshotPaywallScene` and is not initialized on entry to Screenshot Studio. The manager is simulated and never uses live purchases.
- The sixth scene uses **`ProPaywallScreenshotTemplate`** with the app's actual `BYOKPurchaseStore.paywallConfiguration` and a separate simulated `PurchaseManager`. The preview uses the real paywall UI, not a marketing recreation. It selects the yearly plan and offers the built-in monthly (**$6.99**), yearly (**$29.99**), and lifetime (**$49.99**) fixture products; it does not use live App Store pricing or alter real entitlements. **Set the matching live prices separately in App Store Connect before publishing screenshots.**
- Theme, background style, and intensity can be changed in **App Config**; the scene list and filename order remain fixed. Both the content and paywall use the selected appearance.
- Select **iPhone 6.9-inch** for 1320 × 2868 PNGs (default), or **iPhone 6.5-inch** for 1242 × 2688 PNGs. Use the full-set preview to check all six compositions before batch export.
- A Debug-only catalog regression test verifies six unique scenes, their order, and both App Store sizes.

These five feature visuals are curated *fixture compositions*, not pixel-for-pixel captures of the live navigation stack. Check all exported text, layout, contrast, claims, and product prices against the shipping app before uploading. No screenshot data is loaded from the user's actual workspace.

## Real iOS UI-test captures (separate workflow)

The `BYOKchatUITests` target also captures real application screens. Its screenshot launch mode is deterministic and isolated:

- `UI_TEST_SCREENSHOTS` seeds local provider accounts, chats, projects, attachments, usage, and MCP discovery data.
- Onboarding is marked complete for the screenshot process.
- AppFoundation purchases use BYOKchat's built-in simulated catalog.
- Fixture provider credentials use screenshot-only account IDs in the simulator Keychain.
- No provider or MCP network request is required to render the seeded screens.

The eight UI-test attachments remain:

1. `01_Home`
2. `02_Sidebar`
3. `03_Chat`
4. `04_Projects`
5. `05_Providers`
6. `06_MCP`
7. `07_Themes`
8. `08_Paywall`

### Xcode Cloud

After regenerating the project with XcodeGen and committing the generated Xcode project/package resolution files, Xcode Cloud needs no custom setup scripts, environment variables, secrets, or fixture files.

Use the shared `BYOKchat` scheme. Its Test action includes both `BYOKchatTests` and `BYOKchatUITests`; Xcode Cloud can run both from this one scheme. The screenshot tests belong to `BYOKchatUITests`. The target launches the app with screenshot mode enabled, seeds the fixture state automatically, navigates the real UI, and keeps each capture as an XCTest screenshot attachment in the Xcode Cloud test results.

### Local UI-test capture

For local development, the optional helper script runs the same UI-test target and exports the XCTest attachments as named PNG files into this directory:

```sh
scripts/capture_app_store_screenshots.sh
```

The default destination is `iPhone 17 Pro Max`. Override it when needed:

```sh
SCREENSHOT_DESTINATION='platform=iOS Simulator,name=iPhone 17 Pro' \
  scripts/capture_app_store_screenshots.sh
```

`project.yml` is the source of truth for the UI-test target and main iOS scheme. Regenerate the Xcode project with XcodeGen rather than editing the generated project by hand.
