# App icon

Riidr uses two closed books and a small stack of ivory document sheets, with copper-orange headphones laid diagonally across the top. The headphone band lies across the paper and the earcups rest together near the front-right edge, giving the composition a natural placement. Deep petrol teal, warm ivory, and burnt orange preserve the app's existing theme palette. Sculpted volume, soft highlights, and contact shadows give the icon depth.

## Assets and configuration

- Artwork: `ReadAloud/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png` — 1024 × 1024 opaque RGB PNG, square with no baked-in corner mask.
- The iOS universal 1024 icon entry lets the asset compiler produce the required device sizes.
- `project.yml` sets `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` on the ReadAloud target. The existing ReadAloud source directory includes the asset catalog. Keep XcodeGen as the project source of truth.
- Replace the PNG at the same path when updating the artwork; keep its dimensions and opaque background. Inspect the icon on a device before release.
- The icon does not require theme, asset-catalog configuration, or generated project changes.

## Artwork source

The owner selected the revised books/documents/headphones design for PR #40. Created with the built-in image-generation tool, then resized from the selected square artwork to 1024 × 1024 using Lanczos resampling and exported as an opaque RGB PNG.

Design brief:

> Keep the deep teal background, warm ivory paper, and copper-orange accent palette. Arrange two closed books and document sheets in a compact horizontal stack. Lay the headphones diagonally across the top as a person would set them down after listening: a sideways headband arc across the sheets, with both earcups resting together near the front-right edge. Use an elevated three-quarter view, convincing contact shadows, tactile sculpted depth, and generous safe margins. No floating headphones, upright arch, printed text, border, watermark, or baked-in outer corner rounding.

## Validation

The exported artwork is 1024 × 1024 RGB PNG with no alpha channel. The existing AppIcon asset-catalog filename and universal iOS entry are preserved. No builds, tests, CI, package resolution, or XcodeGen regeneration were performed.
