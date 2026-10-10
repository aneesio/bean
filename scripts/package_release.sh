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

# Branch/PR CI also exercises packaging. Only a release tag (or an explicitly
# supplied ref without a type) must match the app version.
if [[ "${GITHUB_REF_TYPE:-}" != "branch" && -n "${GITHUB_REF_NAME:-}" && "$GITHUB_REF_NAME" != "v$VERSION" ]]; then
    echo "error: tag $GITHUB_REF_NAME does not match Info.plist version v$VERSION." >&2
    exit 1
fi

if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
    ARTIFACT_NAME="Bean-$VERSION-build$BUILD"
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
    ARTIFACT_NAME="Bean-$VERSION-build$BUILD-unnotarized"
fi

FINAL_STAGE="$RELEASE_DIR/$ARTIFACT_NAME"
FINAL_ZIP="$RELEASE_DIR/$ARTIFACT_NAME.zip"
FINAL_DMG="$RELEASE_DIR/$ARTIFACT_NAME.dmg"
FINAL_CHECKSUMS="$RELEASE_DIR/$ARTIFACT_NAME.sha256"

echo "==> Packaging Bean $VERSION (build $BUILD)"

echo "==> Preparing release output…"
if [[ -e "$FINAL_STAGE" || -e "$FINAL_ZIP" || -e "$FINAL_DMG" || -e "$FINAL_CHECKSUMS" ]]; then
    echo "error: artifacts for build $BUILD already exist; increment CFBundleVersion to preserve prior releases." >&2
    exit 1
fi
mkdir -p "$RELEASE_DIR"
PACKAGE_LOCK="$RELEASE_DIR/.$ARTIFACT_NAME.lock"
if ! mkdir "$PACKAGE_LOCK" 2>/dev/null; then
    echo "error: another package operation is active for this build." >&2; exit 1
fi
WORK_ROOT=""
PACKAGE_COMMITTED=false
PUBLISHED_STAGE=false
PUBLISHED_ZIP=false
PUBLISHED_DMG=false
PUBLISHED_CHECKSUMS=false
cleanup_package() {
    local status=$?
    if [[ "$PACKAGE_COMMITTED" != true && -n "$WORK_ROOT" ]]; then
        # These paths were absent while we acquired the lock. Move only our
        # newly published artifacts back into scratch before cleanup.
        if [[ "$PUBLISHED_STAGE" == true && -e "$FINAL_STAGE" ]]; then mv "$FINAL_STAGE" "$WORK_ROOT/$ARTIFACT_NAME"; fi
        if [[ "$PUBLISHED_ZIP" == true && -e "$FINAL_ZIP" ]]; then mv "$FINAL_ZIP" "$WORK_ROOT/$ARTIFACT_NAME.zip"; fi
        if [[ "$PUBLISHED_DMG" == true && -e "$FINAL_DMG" ]]; then mv "$FINAL_DMG" "$WORK_ROOT/$ARTIFACT_NAME.dmg"; fi
        if [[ "$PUBLISHED_CHECKSUMS" == true && -e "$FINAL_CHECKSUMS" ]]; then mv "$FINAL_CHECKSUMS" "$WORK_ROOT/$ARTIFACT_NAME.sha256"; fi
    fi
    [[ -z "$WORK_ROOT" ]] || rm -rf "$WORK_ROOT"
    rmdir "$PACKAGE_LOCK"
    return "$status"
}
trap cleanup_package EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [[ -e "$FINAL_STAGE" || -e "$FINAL_ZIP" || -e "$FINAL_DMG" || -e "$FINAL_CHECKSUMS" ]]; then
    echo "error: artifacts for this build already exist." >&2; exit 1
fi
WORK_ROOT="$(mktemp -d "$RELEASE_DIR/.Bean-package.XXXXXX")"
STAGE="$WORK_ROOT/$ARTIFACT_NAME"
ZIP="$WORK_ROOT/$ARTIFACT_NAME.zip"
DMG="$WORK_ROOT/$ARTIFACT_NAME.dmg"
CHECKSUMS="$WORK_ROOT/$ARTIFACT_NAME.sha256"
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
    NOTARY_DIR="$WORK_ROOT/notary"
    mkdir -p "$NOTARY_DIR"
    ditto -c -k --sequesterRsrc --keepParent "$STAGE/Bean.app" "$NOTARY_DIR/Bean.zip"
    xcrun notarytool submit "$NOTARY_DIR/Bean.zip" --keychain-profile "$APPLE_NOTARY_PROFILE" --wait
    xcrun stapler staple "$STAGE/Bean.app"
    xcrun stapler validate "$STAGE/Bean.app"
fi
codesign --verify --deep --strict --verbose=2 "$STAGE/Bean.app"

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
    cd "$WORK_ROOT"
    files=("$(basename "$ZIP")")
    [[ -f "$(basename "$DMG")" ]] && files+=("$(basename "$DMG")")
    shasum -a 256 "${files[@]}" > "$(basename "$CHECKSUMS")"
)

PUBLISHED_STAGE=true; mv "$STAGE" "$FINAL_STAGE"
PUBLISHED_ZIP=true; mv "$ZIP" "$FINAL_ZIP"
if [[ -f "$DMG" ]]; then PUBLISHED_DMG=true; mv "$DMG" "$FINAL_DMG"; fi
PUBLISHED_CHECKSUMS=true; mv "$CHECKSUMS" "$FINAL_CHECKSUMS"
PACKAGE_COMMITTED=true

echo ""
echo "Release ready in: $RELEASE_DIR"
ls -1 "$RELEASE_DIR"
