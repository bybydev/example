# ReadAloud 1.0 Screenshot Studio

Open **Library → Settings → Developer Tools → UI Previews → Screenshot Studio**
in a Debug build. Select a scene and iPhone preset, then use AppFoundation's
full-set preview and PNG export controls. Review the exported images before
App Store submission.

The five main screenshots follow Inkribe's Screenshot Studio campaign:
large left-aligned two-line headlines, an accent-colored second line, a short
subtitle, and feature panels without a device frame, app-name banner, icon,
or footer. ReadAloud keeps its own cream, teal, and orange Light palette.

| # | Scene ID | Headline | Content |
| --- | --- | --- | --- |
| 1 | `reader` | Your words, read aloud. | Reader, highlighted paragraph, listening controls |
| 2 | `import` | Bring your reading. | EPUB, PDF, document, web article, and text imports |
| 3 | `voices` | A voice for every story. | English narrator selection and preview text |
| 4 | `library` | Your library, ready to play. | Keep Listening, source filters, and library rows |
| 5 | `offline` | Take your stories anywhere. | Player, prepared chapters, and Pro offline preparation |
| 6 | `pro` | ReadAloud Pro | Existing AppFoundation paywall, Lifetime selected |

## Appearance and output

- Default campaign: ReadAloud Light, Spotlight, intensity 1.0.
- The existing theme picker, background styles, and intensity controls remain
  available for alternatives. They do not change the app's saved appearance.
- Each feature scene scales one 440-point artboard to the selected output size.
  The headline is 48 points, subtitle 16 points, horizontal content inset
  22 points, and matching top/bottom insets 33 points, following Inkribe.
- Body artwork expands into the remaining space; text and controls retain
  consistent proportions across both presets. Dynamic Type is fixed to Large.
- Existing scene IDs remain stable. Export filenames are numbered in the new
  order, with the reader as the default scene.

| Preset | PNG size |
| --- | --- |
| iPhone 6.9-inch | 1320 × 2868 |
| iPhone 6.5-inch | 1242 × 2688 |

## Rendering boundary

The five feature scenes use fixed text and synchronous SwiftUI artwork. They
never initialize a project, synthesis engine, player, queue, purchase controller,
file import, permission request, or network operation. They do not access the
user's library. Keep future compositions compatible with SwiftUI ImageRenderer;
avoid native view wrappers and asynchronous assets.

Voice fixtures use the current English catalog names: Clara is selected and
Free; Sophie, Lucas, Florence, and Oliver carry the existing Pro markers. The
offline headline's subtitle and Generate Remaining row identify advance audio
preparation as Pro. These are illustrations of the approved access boundaries;
no production gate, limit, or purchase behavior changes.

The sixth scene continues to use `ProPaywallScreenshotTemplate` with
`ReadAloudCommerce.paywallConfiguration` and an isolated, simulated
`PurchaseManager.screenshotPreview` created only when selected. It retains the
existing Monthly $6.99 and Lifetime $29.99 fixtures with Lifetime selected;
these fixtures are not verified App Store Connect prices.

All screenshot implementation stays in the existing Debug-only source file,
preserving Xcode source membership without project regeneration or dependency
changes. The developer navigation remains Debug-only.

Source and diff reviewed statically. Native compilation, Studio rendering, and
PNG appearance at both presets remain unverified. Before upload, inspect all
six scenes in Light and the selected campaign appearance, then review exported
PNGs at both presets. Screenshot Studio is a manual export tool; this change
adds no UI test or CI workflow.
