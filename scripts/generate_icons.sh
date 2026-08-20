#!/bin/bash
# Regenerates Bean's icons deterministically from scripts/IconGenerator.swift.
#
#   ./scripts/generate_icons.sh
#
# Produces:
#   Resources/Icons/AppIcon.icns        (app icon, all macOS sizes)
#   Resources/Icons/MenuBarTemplate.png (monochrome menu bar template)
#   Resources/Icons/AppIcon.iconset/    (intermediate PNGs, kept for inspection)
#
# Uses only macOS built-ins: `swift` (CoreGraphics drawing) and `iconutil`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICONS_DIR="$ROOT/Resources/Icons"

if ! command -v swift >/dev/null 2>&1; then
    echo "error: 'swift' not found — install the Command Line Tools." >&2
    exit 1
fi
if ! command -v iconutil >/dev/null 2>&1; then
    echo "error: 'iconutil' not found (expected on macOS)." >&2
    exit 1
fi

echo "==> Rendering PNGs…"
swift "$ROOT/scripts/IconGenerator.swift" "$ICONS_DIR"

echo "==> Building AppIcon.icns…"
iconutil -c icns "$ICONS_DIR/AppIcon.iconset" -o "$ICONS_DIR/AppIcon.icns"

echo ""
echo "Done:"
echo "  $ICONS_DIR/AppIcon.icns"
echo "  $ICONS_DIR/MenuBarTemplate.png"
echo ""
echo "Rebuild the app to bundle them:  ./scripts/build_app.sh release"
