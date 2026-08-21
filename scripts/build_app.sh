#!/usr/bin/env bash
# Builds Bean and assembles a proper Bean.app bundle from the SwiftPM
# executable. Works with the Command Line Tools alone (no full Xcode needed).
#
# Usage:
#   ./scripts/build_app.sh            # release build -> ./build/Bean.app
#   ./scripts/build_app.sh debug      # debug build
#
# After building, the script ad-hoc code-signs the bundle for local use. Set
# DEVELOPER_ID_APPLICATION to produce a hardened Developer ID-signed app.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/Bean.app"

case "$CONFIG" in
    debug|release) ;;
    *) echo "error: configuration must be 'debug' or 'release'." >&2; exit 2 ;;
esac

# A full Xcode installation carries a matched compiler and SDK. Respect an
# explicitly selected DEVELOPER_DIR; otherwise prefer the standard Xcode path
# over a potentially stale standalone Command Line Tools installation.
if [[ -z "${DEVELOPER_DIR:-}" && -d "/Applications/Xcode.app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

command -v swift >/dev/null 2>&1 || {
    echo "error: Swift is unavailable. Install Xcode or the Command Line Tools." >&2
    exit 1
}
command -v codesign >/dev/null 2>&1 || {
    echo "error: codesign is unavailable." >&2
    exit 1
}

# Keep the array non-empty. Empty-array expansion with `set -u` fails under the
# Bash 3.2 shipped by macOS.
SWIFTPM_ARGS=(-c "$CONFIG")
if [[ "${BEAN_DISABLE_SWIFTPM_SANDBOX:-0}" == "1" ]]; then
    SWIFTPM_ARGS+=(--disable-sandbox)
fi
for arch in ${BEAN_ARCHS:-}; do
    case "$arch" in
        arm64|x86_64) SWIFTPM_ARGS+=(--arch "$arch") ;;
        *) echo "error: unsupported architecture '$arch' in BEAN_ARCHS." >&2; exit 2 ;;
    esac
done

echo "==> Building Bean ($CONFIG) with SwiftPM…"
cd "$ROOT"
swift build "${SWIFTPM_ARGS[@]}"

BIN_PATH="$(swift build "${SWIFTPM_ARGS[@]}" --show-bin-path)"
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
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Ship useful docs inside the bundle so Settings and Finder users can open them.
for doc in README TESTING PRIVACY LICENSE; do
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

# Bundle native-host utilities so a GitHub DMG user does not need a source
# checkout just to connect the optional browser extension.
mkdir -p "$APP/Contents/Resources/NativeMessaging"
cp "$ROOT/scripts/install_native_messaging_host.sh" \
   "$ROOT/scripts/uninstall_native_messaging_host.sh" \
   "$APP/Contents/Resources/NativeMessaging/"
chmod 755 "$APP/Contents/Resources/NativeMessaging/"*.sh
echo "==> Bundled native messaging utilities"

# Code-signing. Default is ad-hoc (local testing and unnotarized betas only).
# If DEVELOPER_ID_APPLICATION is set to a valid identity, sign with it using the
# hardened runtime + secure timestamp (suitable for later notarization).
echo "==> Code-signing…"
if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
    codesign --force --options runtime --timestamp \
        --sign "$DEVELOPER_ID_APPLICATION" "$APP"
    echo "    Signed with Developer ID identity: $DEVELOPER_ID_APPLICATION"
    SIGNING_NOTE="Signed with Developer ID: $DEVELOPER_ID_APPLICATION"
else
    codesign --force --sign - "$APP"
    echo "    Signed ad-hoc — local testing only."
    SIGNING_NOTE="Signed ad-hoc (local testing only)"
fi

codesign --verify --deep --strict --verbose=2 "$APP"

echo ""
echo "Built: $APP"
echo "$SIGNING_NOTE"
echo "Run with:  open \"$APP\""
echo ""
echo "First launch: grant Accessibility access in"
echo "System Settings > Privacy & Security > Accessibility, then relaunch."
