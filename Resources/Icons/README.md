# Bean icons

Bean's icons are **generated deterministically from source in this repo** — no
external SVG rasterizer or design tool required.

## Files

- `AppIcon.svg` — documented vector source of truth (for humans).
- `../../scripts/IconGenerator.swift` — CoreGraphics drawing that renders the
  actual pixels; mirrors `AppIcon.svg`.
- `AppIcon.icns` — generated app icon (all macOS sizes 16→1024px).
- `AppIcon.iconset/` — generated intermediate PNGs.
- `MenuBarTemplate.png` — generated monochrome menu bar template (36px @2x).

## Regenerate

```bash
./scripts/generate_icons.sh      # uses built-in `swift` + `iconutil`
./scripts/build_app.sh release   # bundles AppIcon.icns + MenuBarTemplate.png
```

## Restyle

Edit the drawing functions in `scripts/IconGenerator.swift` (`drawAppIcon` /
`drawMenuBarTemplate`), keep `AppIcon.svg` in sync for documentation, then
re-run `generate_icons.sh`.

## Design

Minimal, premium, productivity-utility feel: warm-neutral rounded square, a
single centered abstract coffee bean (charcoal, tilted) with an S-groove and a
soft shadow. No text, face, cup, or steam; deliberately muted (not a food app).
