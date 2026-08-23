#!/usr/bin/env bash
# Packages a Bean release and produces a versioned ZIP, DMG, and SHA-256 file.
# Existing versions are preserved. Public Developer ID releases fail closed if
# notarization is not configured; unnotarized beta packaging requires an
# explicit BEAN_ALLOW_ADHOC_RELEASE=1 acknowledgement.
#
#   ./scripts/package_release.sh
#
# Output (version read from Info.plist — no hardcoding):
#   release/Bean-<version>/Bean.app
#   release/Bean-<version>/README.md and public support/privacy/QA/release docs
#   release/Bean-<version>.zip
#   release/Bean-<version>.dmg            (if hdiutil is present)
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$ROOT/Resources/Info.plist"

VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$PLIST")"
BUILD="$(plutil -extract CFBundleVersion raw -o - "$PLIST")"
RELEASE_DIR="$ROOT/release"

if [[ ! "$VERSION" =~ ^[0-9]+([.][0-9]+){1,3}([-][0-9A-Za-z.-]+)?$ ]]; then
    echo "error: unsafe or invalid CFBundleShortVersionString '$VERSION'." >&2
    exit 1
fi
if [[ ! "$BUILD" =~ ^[0-9]+$ ]]; then
    echo "error: CFBundleVersion must be numeric; found '$BUILD'." >&2
    exit 1
fi

if [[ -n "${GITHUB_REF_NAME:-}" && "$GITHUB_REF_NAME" != "v$VERSION" ]]; then
    echo "error: tag $GITHUB_REF_NAME does not match Info.plist version v$VERSION." >&2
    exit 1
fi

if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
    ARTIFACT_NAME="Bean-$VERSION"
    if [[ -z "${APPLE_NOTARY_PROFILE:-}" ]]; then
        echo "error: APPLE_NOTARY_PROFILE is required for a Developer ID release." >&2
        exit 1
    fi
else
    if [[ "${BEAN_ALLOW_ADHOC_RELEASE:-0}" != "1" ]]; then
        echo "error: no Developer ID identity configured." >&2
        echo "       For a clearly labelled GitHub beta, set BEAN_ALLOW_ADHOC_RELEASE=1." >&2
        exit 1
    fi
    ARTIFACT_NAME="Bean-$VERSION-unnotarized"
fi

STAGE="$RELEASE_DIR/$ARTIFACT_NAME"
ZIP="$RELEASE_DIR/$ARTIFACT_NAME.zip"
DMG="$RELEASE_DIR/$ARTIFACT_NAME.dmg"
CHECKSUMS="$RELEASE_DIR/$ARTIFACT_NAME.sha256"

echo "==> Packaging Bean $VERSION (build $BUILD)"

echo "==> Preparing release output…"
mkdir -p "$STAGE"
rm -rf "$STAGE"
rm -f "$ZIP" "$DMG" "$CHECKSUMS"
mkdir -p "$STAGE"

if [[ "${BEAN_REGENERATE_ICONS:-0}" == "1" ]]; then
    echo "==> Regenerating icons…"
    "$ROOT/scripts/generate_icons.sh" >/dev/null
fi
[[ -f "$ROOT/Resources/Icons/AppIcon.icns" ]] || {
    echo "error: Resources/Icons/AppIcon.icns is missing; run scripts/generate_icons.sh." >&2
    exit 1
}

echo "==> Building app…"
BEAN_ARCHS="${BEAN_ARCHS:-arm64 x86_64}" "$ROOT/scripts/build_app.sh" release >/dev/null
echo "    built."

echo "==> Staging…"
cp -R "$ROOT/build/Bean.app" "$STAGE/Bean.app"
for doc in README TESTING QA_TEST_PLAN SUPPORT SUPPORTED_APPS LICENSE PRIVACY CHANGELOG; do
    [[ -s "$ROOT/$doc.md" ]] || {
        echo "error: required staged document is missing or empty: $doc.md" >&2
        exit 1
    }
    cp "$ROOT/$doc.md" "$STAGE/$doc.md"
done

if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
    echo "==> Notarizing app…"
    NOTARY_DIR="$(mktemp -d)"
    trap 'rm -rf "$NOTARY_DIR"' EXIT
    ditto -c -k --sequesterRsrc --keepParent "$STAGE/Bean.app" "$NOTARY_DIR/Bean.zip"
    xcrun notarytool submit "$NOTARY_DIR/Bean.zip" --keychain-profile "$APPLE_NOTARY_PROFILE" --wait
    xcrun stapler staple "$STAGE/Bean.app"
    xcrun stapler validate "$STAGE/Bean.app"
fi

echo "==> Creating ZIP…"
# ditto preserves the code signature and resource forks (better than `zip`).
ditto -c -k --sequesterRsrc --keepParent "$STAGE/Bean.app" "$ZIP"
echo "    release/$(basename "$ZIP")"

if command -v hdiutil >/dev/null 2>&1; then
    echo "==> Creating DMG…"
    # Drop a Drag-to-Applications alias next to the app for a simple installer.
    ln -sf /Applications "$STAGE/Applications"
    hdiutil create \
        -volname "Bean $VERSION" \
        -srcfolder "$STAGE" \
        -ov -format UDZO \
        "$DMG" >/dev/null
    echo "    release/$(basename "$DMG")"
else
    echo "==> hdiutil not available — skipping DMG."
fi

if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
    spctl --assess --type execute --verbose=2 "$STAGE/Bean.app"
fi

echo "==> Writing checksums…"
(
    cd "$RELEASE_DIR"
    files=("$(basename "$ZIP")")
    [[ -f "$(basename "$DMG")" ]] && files+=("$(basename "$DMG")")
    shasum -a 256 "${files[@]}" > "$(basename "$CHECKSUMS")"
)

echo ""
echo "Release ready in: $RELEASE_DIR"
ls -1 "$RELEASE_DIR"
