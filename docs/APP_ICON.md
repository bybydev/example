# App icon

ReadAloud uses a sculpted ivory open book with thick layered pages, a petrol-teal cover, and raised burnt-orange sound arcs on a deep teal background. Soft highlights and shadows give the emblem depth. Its reading-first silhouette and teal–ivory–orange palette distinguish it from Spokio’s violet waveform identity.

## Assets and configuration

- Artwork: `ReadAloud/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png` — 1024 × 1024 opaque RGB PNG, square with no baked-in corner mask.
- The iOS universal 1024 icon entry lets the asset compiler produce the required device sizes.
- `project.yml` sets `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` on the ReadAloud target. The existing `ReadAloud` source directory includes the asset catalog. Keep XcodeGen as the project source of truth.
- Replace the PNG at the same path when updating the artwork; keep its dimensions and opaque background. Inspect the icon on a device before release.

## Artwork source

Created with the built-in image-generation tool using the earlier teal book design as the edit target, then exported to the required 1024 × 1024 RGB PNG for the asset catalog.

Prompt:

> Use case: style-transfer.
> Asset type: production iOS app icon for ReadAloud.
> Input image: edit target, the supplied ReadAloud book icon.
> Primary request: transform this flat icon into a premium sculpted 3D app icon with unmistakable physical depth.
> Preserve the deep petrol-teal, warm ivory, and burnt-orange color identity; preserve the open book as the dominant emblem, two orange sound arcs at its upper right, square opaque full-bleed composition, and clear small-size readability.
> Make the book a beautiful dimensional object: thick layered ivory pages, gently curved top surfaces, smoothly rounded bevels, a deep central spine, a visible dark-teal book cover below the pages, and a softly curled lower-right page corner. Use satin ceramic-like page surfaces with realistic controlled highlights, soft ambient occlusion between layers, and convincing cast shadows on the background. The two orange sound arcs should be thick rounded raised objects, subtly reflective, with their own gentle shadows. Light from the upper left. Keep front-facing composition with only slight perspective.
> Background: full-bleed rich deep petrol teal with a restrained subtle luminous gradient and soft lighting falloff, all four square edges filled. Keep the emblem around 68% of the square and optically centered with room for iOS corner masking.
> Constraints: do not keep the flat vector appearance; add real sculptural volume. No purple or lavender, no waveform bars, no extra objects, no letters, no printed page text, no watermark, no frame, no baked-in rounded outside corners, no mockup. Output one finished opaque square 1024x1024 artwork.
