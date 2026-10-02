#!/usr/bin/env bash
# Test artifact publication/failure recovery on a private repository fixture.
# The build is a verified bundle copy, not a second Swift compile or app launch.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="${1:-$ROOT/build/Bean.app}"
[[ -d "$SOURCE" ]] || { echo 'Build Bean first or pass a verified app bundle.' >&2; exit 2; }
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/bean-package-test.XXXXXX")"
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/scripts" "$TEST_ROOT/Resources/Icons" "$TEST_ROOT/tools"
cp "$ROOT/scripts/package_release.sh" "$TEST_ROOT/scripts/"
cp "$ROOT/Resources/Info.plist" "$TEST_ROOT/Resources/"
cp "$ROOT/Resources/Icons/AppIcon.icns" "$TEST_ROOT/Resources/Icons/"
for doc in README TESTING QA_TEST_PLAN SUPPORT SUPPORTED_APPS LICENSE PRIVACY CHANGELOG; do cp "$ROOT/$doc.md" "$TEST_ROOT/"; done
cat > "$TEST_ROOT/scripts/build_app.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "${BEAN_TEST_FAILURE:-}" != build ]] || exit 42
fixture_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$fixture_root/build"
ditto "$BEAN_TEST_SOURCE" "$fixture_root/build/Bean.app"
cp "$fixture_root/Resources/Info.plist" "$fixture_root/build/Bean.app/Contents/Info.plist"
codesign --force --deep --sign - "$fixture_root/build/Bean.app" >/dev/null 2>&1
SH
cat > "$TEST_ROOT/tools/hdiutil" <<'SH'
#!/usr/bin/env bash
[[ "${BEAN_TEST_FAILURE:-}" != dmg ]] || exit 42
exec /usr/bin/hdiutil "$@"
SH
chmod +x "$TEST_ROOT/scripts/build_app.sh" "$TEST_ROOT/tools/hdiutil"
export BEAN_TEST_SOURCE="$SOURCE"
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$TEST_ROOT/Resources/Info.plist")"
BUILD="$(plutil -extract CFBundleVersion raw -o - "$TEST_ROOT/Resources/Info.plist")"
NAME="Bean-$VERSION-build$BUILD-unnotarized"
package_fixture() { BEAN_ALLOW_ADHOC_RELEASE=1 "$TEST_ROOT/scripts/package_release.sh" > "$TEST_ROOT/package.log" 2>&1; }
for failure in build dmg; do
    if PATH="$TEST_ROOT/tools:$PATH" BEAN_TEST_FAILURE="$failure" package_fixture; then
        echo "Injected $failure packaging failure was accepted" >&2; exit 1
    fi
    [[ ! -e "$TEST_ROOT/release/$NAME" && ! -e "$TEST_ROOT/release/$NAME.zip" && ! -e "$TEST_ROOT/release/$NAME.dmg" && ! -e "$TEST_ROOT/release/$NAME.sha256" ]]
    [[ ! -e "$TEST_ROOT/release/.$NAME.lock" ]]
done
package_fixture
(cd "$TEST_ROOT/release" && shasum -a 256 -c "$NAME.sha256")
codesign --verify --deep --strict "$TEST_ROOT/release/$NAME/Bean.app"
ditto -x -k "$TEST_ROOT/release/$NAME.zip" "$TEST_ROOT/extracted"
codesign --verify --deep --strict "$TEST_ROOT/extracted/Bean.app"
before_hash="$(shasum -a 256 "$TEST_ROOT/release/$NAME.zip")"
if package_fixture; then echo 'Existing artifacts were overwritten' >&2; exit 1; fi
[[ "$before_hash" == "$(shasum -a 256 "$TEST_ROOT/release/$NAME.zip")" ]]
echo 'Private build/DMG failure cleanup, identical-build retry, real ZIP/DMG/checksums/signatures and completed-artifact preservation passed.'
