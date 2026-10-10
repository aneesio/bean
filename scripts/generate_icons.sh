#!/bin/bash
# Regenerates Bean's icons deterministically from Resources/Icons/AppIcon.svg
# and the monochrome menu bar renderer in scripts/IconGenerator.swift.
#
#   ./scripts/generate_icons.sh
#
# Produces:
#   Resources/Icons/AppIcon.png         (1024px preview rendered from the SVG)
#   Resources/Icons/AppIcon.icns        (app icon, all macOS sizes)
#   Resources/Icons/MenuBarTemplate.png (monochrome menu bar template)
#   Resources/Icons/AppIcon.iconset/    (intermediate PNGs, kept for inspection)
#   BrowserExtension/icon{16,32,48,128}.png (browser toolbar/settings artwork)
#
# Uses only macOS built-ins: `swift` (offscreen WebKit + CoreGraphics) and `iconutil`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICONS_DIR="$ROOT/Resources/Icons"
SOURCE_SVG="$ICONS_DIR/AppIcon.svg"

if [ ! -f "$SOURCE_SVG" ]; then
    echo "error: app icon source is missing: $SOURCE_SVG" >&2
    exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
    echo "error: 'swift' not found — install the Command Line Tools." >&2
    exit 1
fi
if ! command -v iconutil >/dev/null 2>&1; then
    echo "error: 'iconutil' not found (expected on macOS)." >&2
    exit 1
fi

echo "==> Rendering PNGs…"
swift "$ROOT/scripts/IconGenerator.swift" "$ICONS_DIR" "$SOURCE_SVG"

echo "==> Building AppIcon.icns…"
iconutil -c icns "$ICONS_DIR/AppIcon.iconset" -o "$ICONS_DIR/AppIcon.icns"

echo "==> Updating browser-extension icons…"
cp "$ICONS_DIR/AppIcon.iconset/icon_16x16.png" "$ROOT/BrowserExtension/icon16.png"
cp "$ICONS_DIR/AppIcon.iconset/icon_32x32.png" "$ROOT/BrowserExtension/icon32.png"
sips -z 48 48 "$ICONS_DIR/AppIcon.png" --out "$ROOT/BrowserExtension/icon48.png" >/dev/null
cp "$ICONS_DIR/AppIcon.iconset/icon_128x128.png" "$ROOT/BrowserExtension/icon128.png"

echo ""
echo "Done:"
echo "  $ICONS_DIR/AppIcon.png"
echo "  $ICONS_DIR/AppIcon.icns"
echo "  $ICONS_DIR/MenuBarTemplate.png"
echo "  $ROOT/BrowserExtension/icon{16,32,48,128}.png"
echo ""
echo "Rebuild the app to bundle them:  ./scripts/build_app.sh release"
