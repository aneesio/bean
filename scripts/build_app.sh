#!/bin/bash
# Builds Bean and assembles a proper Bean.app bundle from the SwiftPM
# executable. Works with the Command Line Tools alone (no full Xcode needed).
#
# Usage:
#   ./scripts/build_app.sh            # release build -> ./build/Bean.app
#   ./scripts/build_app.sh debug      # debug build
#
# After building, the script ad-hoc code-signs the bundle. Ad-hoc signing is
# enough for Accessibility permission to attach to the app on your own machine.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/Bean.app"

echo "==> Building Bean ($CONFIG) with SwiftPM…"
cd "$ROOT"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"
EXE="$BIN_PATH/Bean"

if [[ ! -f "$EXE" ]]; then
    echo "error: built executable not found at $EXE" >&2
    exit 1
fi

echo "==> Assembling Bean.app…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$EXE" "$APP/Contents/MacOS/Bean"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Ship docs inside the bundle so Settings ▸ Troubleshooting can open them.
for doc in README TESTING; do
    if [[ -f "$ROOT/$doc.md" ]]; then
        cp "$ROOT/$doc.md" "$APP/Contents/Resources/$doc.md"
    fi
done

# Copy the app icon if present (regenerate via scripts/generate_icons.sh).
if [[ -f "$ROOT/Resources/Icons/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/Icons/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
    echo "==> Bundled AppIcon.icns"
else
    echo "==> No AppIcon.icns — run scripts/generate_icons.sh"
fi

# Copy the menu bar template image if present.
if [[ -f "$ROOT/Resources/Icons/MenuBarTemplate.png" ]]; then
    cp "$ROOT/Resources/Icons/MenuBarTemplate.png" "$APP/Contents/Resources/MenuBarTemplate.png"
    echo "==> Bundled MenuBarTemplate.png"
fi

# Bundle the browser extension so Settings can reveal it for "Load unpacked".
if [[ -d "$ROOT/BrowserExtension" ]]; then
    rm -rf "$APP/Contents/Resources/BrowserExtension"
    cp -R "$ROOT/BrowserExtension" "$APP/Contents/Resources/BrowserExtension"
    echo "==> Bundled BrowserExtension"
fi

# Code-signing. Default is ad-hoc (fine for local use, no Apple account needed).
# If DEVELOPER_ID_APPLICATION is set to a valid identity, sign with it using the
# hardened runtime + secure timestamp (suitable for later notarization).
echo "==> Code-signing…"
if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
    codesign --force --deep --options runtime --timestamp \
        --sign "$DEVELOPER_ID_APPLICATION" "$APP"
    echo "    Signed with Developer ID identity: $DEVELOPER_ID_APPLICATION"
    SIGNING_NOTE="Signed with Developer ID: $DEVELOPER_ID_APPLICATION"
else
    codesign --force --deep --sign - "$APP"
    echo "    Signed ad-hoc — local testing only."
    SIGNING_NOTE="Signed ad-hoc (local testing only)"
fi

echo ""
echo "Built: $APP"
echo "$SIGNING_NOTE"
echo "Run with:  open \"$APP\""
echo ""
echo "First launch: grant Accessibility access in"
echo "System Settings > Privacy & Security > Accessibility, then relaunch."
