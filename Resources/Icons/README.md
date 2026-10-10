# Bean icons

`AppIcon.svg` is the authoritative 1024×1024 artwork: a detailed, dimensional
green bean on a neutral off-white rounded-square background. Its editable paths, gradients,
and texture curves contain no embedded bitmap. PNGs and the macOS ICNS are
derived from this SVG with built-in macOS tools.

The current design uses Bean Green (#237A48), a gentle kidney-shaped bend, a
larger buttery-yellow seed scar with reflected green shading, polished emerald
sides, and restrained highlights from above. It is
static vector artwork inspired by Apple's current material and lighting
direction; the SVG and ICNS do not contain dynamic Icon Composer effects.

## Files

- `AppIcon.svg` — editable vector source of truth.
- `AppIcon.png` — generated 1024px raster preview; not a source file.
- `../../scripts/IconGenerator.swift` — renders the SVG with native WebKit,
  scales the app artwork, and draws the monochrome kidney-shaped menu bar
  template.
- `AppIcon.icns` — generated app icon (all macOS sizes 16→1024px).
- `AppIcon.iconset/` — generated intermediate PNGs.
- `MenuBarTemplate.png` — generated monochrome menu bar template (36px @2x).
- `../../BrowserExtension/icon{16,32,48,128}.png` — generated browser toolbar and settings icons from the same SVG.
- `Concepts/` — design explorations and their prompts; not build inputs.

## Regenerate

```bash
./scripts/generate_icons.sh      # uses Swift, native WebKit, and iconutil
./scripts/build_app.sh release   # bundles AppIcon.icns + MenuBarTemplate.png
```

## Restyle

Edit the paths, gradients, and textures in `AppIcon.svg`, preserving its 1024×1024
viewBox and intended padding, then re-run `generate_icons.sh`. Edit
`drawMenuBarTemplate` in `scripts/IconGenerator.swift` to change the menu bar
silhouette. Do not replace the SVG with an embedded or linked raster image.

The generator updates the browser extension's 16, 32, 48 and 128px artwork on
every run, so the app, browser toolbar, popup and options share one icon source.

Review the generated PNGs at native sizes from 16 to 1024 pixels, especially the
bean silhouette and contrast at 16 and 32 pixels. The build bundles the generated
`AppIcon.icns` and `MenuBarTemplate.png`; regenerate before rebuilding.
