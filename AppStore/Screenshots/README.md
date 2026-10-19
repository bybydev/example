# ReadAloud 1.0 Screenshot Studio

Open **Library → Settings → Developer Tools → UI Previews → Screenshot Studio** in a Debug build. Choose the 6.9-inch or 6.5-inch iPhone preset, inspect each preview, then use Screenshot Studio's full-set preview and export to save the PNG files. Review the exported images before App Store submission.

| # | Scene ID | Content |
| --- | --- | --- |
| 1 | `library` | Your stories. All in one place. — Library / Keep Listening |
| 2 | `reader` | Listen and read in perfect harmony. — reader, highlighted paragraph, player |
| 3 | `import` | Turn almost anything into listening. — Add Files, Web Article, Text |
| 4 | `voices` | A voice for every story. — built-in voices |
| 5 | `offline` | Take your stories anywhere. — Pro offline generation queue |
| 6 | `pro` | ReadAloud Pro — real AppFoundation paywall |

## Rendering and safety

- The first five scenes use a simple headline and an AppFoundation clay device frame on a themed background. They have **no app icon, eyebrow, or footer**.
- Their SwiftUI fixtures are **stateless and deterministic**. They never read real user data, request permissions, import documents, access the network, or initialize playback.
- The sixth scene uses `ProPaywallScreenshotTemplate` with the existing `ReadAloudCommerce.paywallConfiguration` and an isolated, **simulated** `PurchaseManager.screenshotPreview` created only when the paywall is selected.
- The paywall preview selects Lifetime and includes the app's two simulated plans: Monthly **$6.99** and Lifetime **$29.99**. These amounts are developer fixtures, not verified production App Store Connect prices.
- Developer navigation is guarded by `#if DEBUG`; no production feature gating or purchase configuration is changed.

Screenshot Studio performs manual export, not a new UI test or CI workflow. The fixtures are illustrated representations of current product functionality, so inspect actual UI separately before publishing.
