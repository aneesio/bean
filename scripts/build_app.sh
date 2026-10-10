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
APP_DESTINATION="$APP"
ASSEMBLY_ROOT=""
PREVIOUS_APP=""
BUILD_PUBLISHED=0
BUILD_LOCK=""

cleanup_build() {
    if [[ "$BUILD_PUBLISHED" != 1 && -n "$PREVIOUS_APP" && -e "$PREVIOUS_APP" ]]; then
        # The exclusive build lock covers both moves. A signal after publication
        # but before its success flag restores the last verified bundle too.
        [[ ! -e "$APP_DESTINATION" ]] || rm -rf "$APP_DESTINATION"
        mv "$PREVIOUS_APP" "$APP_DESTINATION" || {
            echo "error: automatic restoration failed; previous bundle: $PREVIOUS_APP" >&2
        }
    fi
    [[ -z "$ASSEMBLY_ROOT" ]] || rm -rf "$ASSEMBLY_ROOT"
    [[ -z "$BUILD_LOCK" ]] || rmdir "$BUILD_LOCK"
}
trap cleanup_build EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

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

mkdir -p "$BUILD_DIR"
if ! mkdir "$BUILD_DIR/.Bean-build.lock" 2>/dev/null; then
    echo "error: another build owns build/.Bean-build.lock; inspect it before retrying." >&2
    exit 1
fi
BUILD_LOCK="$BUILD_DIR/.Bean-build.lock"

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
mkdir -p "$BUILD_DIR"
ASSEMBLY_ROOT="$(mktemp -d "$BUILD_DIR/.bean-assembly.XXXXXX")"
APP="$ASSEMBLY_ROOT/Bean.app"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$EXE" "$APP/Contents/MacOS/Bean"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Ship the complete public-release documentation contract inside every app
# bundle. The ZIP contains only Bean.app, so silently skipping one of these
# files would make the ZIP less complete than the DMG staging directory.
for doc in README TESTING QA_TEST_PLAN SUPPORT SUPPORTED_APPS PRIVACY LICENSE CHANGELOG; do
    [[ -s "$ROOT/$doc.md" ]] || {
        echo "error: required bundled document is missing or empty: $doc.md" >&2
        exit 1
    }
    cp "$ROOT/$doc.md" "$APP/Contents/Resources/$doc.md"
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

# Never discard the last working bundle while assembling or signing a new one.
# Publication happens only after verification; a failed move restores it.
if [[ -L "$APP_DESTINATION" ]]; then
    echo "error: build destination must not be a symbolic link." >&2
    exit 1
fi
if [[ -e "$APP_DESTINATION" ]]; then
    PREVIOUS_ROOT="$(mktemp -d "$BUILD_DIR/previous-build.XXXXXX")"
    PREVIOUS_APP="$PREVIOUS_ROOT/Bean.app"
    mv "$APP_DESTINATION" "$PREVIOUS_APP"
fi
if ! mv "$APP" "$APP_DESTINATION"; then
    echo "error: could not publish the verified app; the previous build was restored." >&2
    exit 1
fi
BUILD_PUBLISHED=1
APP="$APP_DESTINATION"

echo ""
echo "Built: $APP"
[[ -z "$PREVIOUS_APP" ]] || echo "Previous build preserved: $PREVIOUS_APP"
echo "$SIGNING_NOTE"
echo "Run with:  open \"$APP\""
echo ""
echo "First launch: grant Accessibility access in"
echo "System Settings > Privacy & Security > Accessibility, then relaunch."
