# App Store Screenshot Studio

In a Debug build, open Settings → Developer Tools → App Store → Screenshot Studio.
Choose a scene and device size, then use AppFoundation's PNG export controls.
The catalog is English and ordered as follows:

1. Your words, captioned.
2. Find your caption style.
3. Get every word right.
4. Set the mood with music.
5. Ready to share.
6. Inkribe Pro — AppFoundation's real paywall, with Yearly selected.

The approved campaign uses Light, Spotlight, intensity 1.0. Graphite and the
AppFoundation background style/intensity controls are available for alternatives.
The five feature compositions omit the app icon, app-name banner and footer.
They scale one 440-point artboard to the selected preset. All five feature scenes
use matching 33-point top/bottom layout insets. The main video artwork (or the
Styles hero) expands into the remaining height; text, timeline and controls keep
their existing sizes. This avoids collecting unused space below the composition.
The paywall keeps AppFoundation's layout.

Export presets:

| Preset | PNG size |
| --- | --- |
| iPhone 6.9-inch | 1320 × 2868 |
| iPhone 6.5-inch | 1242 × 2688 |

## Rendering boundary

Feature scenes contain fixed text, SwiftUI shapes and synchronous Canvas artwork.
They create no project model, player, processing queue, storage, permission request,
network task or purchase controller. Keep future screenshot components independent
of app state and compatible with SwiftUI ImageRenderer; avoid native view wrappers.

The paywall intentionally uses `ProPaywallScreenshotTemplate` and a lazy scene-owned
`PurchaseManager.screenshotPreview`, following BYOKchat. Its catalog is populated
synchronously from Commerce's three simulated products: $2.99 monthly, $9.99 yearly
and $24.99 lifetime. It has no persistence key and never uses the app's manager.

All screenshot code and the developer destination are Debug-only. `project.yml`
already includes the Inkribe directory recursively; the committed Xcode project's
iOS source phase also includes these three files. No package update is required.

Source/API, project-membership and whitespace review completed. Native compilation,
Studio rendering and exported PNG appearance remain unverified under the current
source-only workflow. Review all six scenes at both presets before App Store upload.
