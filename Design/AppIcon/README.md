# Crow app icon

`Original.png` is the user-supplied artwork. `Master.png` is the full-bleed opaque
square edited with the built-in image generation/editing tool, not CLI.
The silver crow on black is enlarged; the inset rounded tile and transparent
padding are removed to avoid a second pale frame in the macOS Dock. This is an
AI-assisted edit, not a pixel-identical crop. The platform supplies icon masking.

Export the checked-in master without generating new artwork:

```sh
swift Tools/export-app-icon.swift
```

Outputs go to `App/Assets.xcassets/AppIcon.appiconset/`:

- `AppIcon-mac-*.png`: opaque macOS sizes, 16 through 1024 pixels.
- `AppIcon.png`: opaque 1024-pixel iOS/iPadOS asset, framed to fill the icon canvas.

## Editing prompt

Use case: precise-object-edit. Asset type: full-bleed square app icon source. Image 1 is the edit target. Keep the exact silver glass crow symbol, silhouette, separated wing, tail and beak shapes, orientation, shading and monochrome palette. Change ONLY the framing and background: remove ALL transparent exterior padding and remove the inset rounded-square tile border. Enlarge the whole composition so the bird occupies about 80% of the square width and height, fully visible, balanced centered. The glossy near-black background must fill the ENTIRE square image edge to edge including all four corners, fully opaque. No rounded corners, no outer frame, no silver rim around the background, no white border, no inset tile, no mockup, no shadows outside a tile, no text. Output a single square production asset. The operating system will apply its own rounded-square mask; do not bake a rounded-square mask into the image.
