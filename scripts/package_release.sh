#!/bin/bash
# Packages a Bean release: regenerates icons, builds the signed .app, and
# produces a versioned folder + ZIP (and a DMG when hdiutil is available).
#
#   ./scripts/package_release.sh
#
# Output (version read from Info.plist — no hardcoding):
#   release/Bean-<version>/Bean.app
#   release/Bean-<version>/README.md
#   release/Bean-<version>.zip
#   release/Bean-<version>.dmg            (if hdiutil is present)
#
# Signing follows scripts/build_app.sh: ad-hoc by default, or Developer ID when
# DEVELOPER_ID_APPLICATION is set.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$ROOT/Resources/Info.plist"

VERSION="$(defaults read "$PLIST" CFBundleShortVersionString)"
BUILD="$(defaults read "$PLIST" CFBundleVersion)"
RELEASE_DIR="$ROOT/release"
STAGE="$RELEASE_DIR/Bean-$VERSION"

echo "==> Packaging Bean $VERSION (build $BUILD)"

echo "==> Cleaning previous release output…"
rm -rf "$RELEASE_DIR"
mkdir -p "$STAGE"

echo "==> Regenerating icons…"
"$ROOT/scripts/generate_icons.sh" >/dev/null

echo "==> Building app…"
"$ROOT/scripts/build_app.sh" release >/dev/null
echo "    built."

echo "==> Staging…"
cp -R "$ROOT/build/Bean.app" "$STAGE/Bean.app"
[[ -f "$ROOT/README.md" ]] && cp "$ROOT/README.md" "$STAGE/README.md"

echo "==> Creating ZIP…"
# ditto preserves the code signature and resource forks (better than `zip`).
ditto -c -k --sequesterRsrc --keepParent "$STAGE/Bean.app" "$RELEASE_DIR/Bean-$VERSION.zip"
echo "    release/Bean-$VERSION.zip"

if command -v hdiutil >/dev/null 2>&1; then
    echo "==> Creating DMG…"
    # Drop a Drag-to-Applications alias next to the app for a simple installer.
    ln -sf /Applications "$STAGE/Applications"
    hdiutil create \
        -volname "Bean $VERSION" \
        -srcfolder "$STAGE" \
        -ov -format UDZO \
        "$RELEASE_DIR/Bean-$VERSION.dmg" >/dev/null
    echo "    release/Bean-$VERSION.dmg"
else
    echo "==> hdiutil not available — skipping DMG."
fi

echo ""
echo "Release ready in: $RELEASE_DIR"
ls -1 "$RELEASE_DIR"
