#!/usr/bin/env bash
# Exercise bundle assembly/publication with a real executable and codesign,
# while replacing the costly compiler with a private deterministic fixture.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="${1:-$ROOT/build/Bean.app}"
[[ -x "$SOURCE/Contents/MacOS/Bean" ]] || { echo 'Build Bean first or pass a verified bundle.' >&2; exit 2; }
codesign --verify --deep --strict "$SOURCE"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/bean-build-test.XXXXXX")"
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/scripts" "$TEST_ROOT/tools" "$TEST_ROOT/bin" "$TEST_ROOT/Resources/Icons"
cp "$ROOT/scripts/build_app.sh" "$TEST_ROOT/scripts/"
cp "$ROOT/Resources/Info.plist" "$TEST_ROOT/Resources/"
cp "$SOURCE/Contents/MacOS/Bean" "$TEST_ROOT/bin/Bean"
cp "$ROOT/Resources/Icons/AppIcon.icns" "$TEST_ROOT/Resources/Icons/"
for doc in README TESTING QA_TEST_PLAN SUPPORT SUPPORTED_APPS LICENSE PRIVACY CHANGELOG; do cp "$ROOT/$doc.md" "$TEST_ROOT/"; done
cp "$ROOT/scripts/"{install,uninstall}_native_messaging_host.sh "$TEST_ROOT/scripts/"
cat > "$TEST_ROOT/tools/swift" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "${BEAN_TEST_FAILURE:-}" != build ]] || exit 42
if [[ " $* " == *' --show-bin-path '* ]]; then printf '%s\n' "$BEAN_TEST_ROOT/bin"; exit; fi
if [[ "${BEAN_TEST_HOLD:-}" == true ]]; then
    touch "$BEAN_TEST_ROOT/started"
    for ((attempt=0; attempt<500; attempt++)); do
        [[ ! -f "$BEAN_TEST_ROOT/release" ]] || break
        sleep .01
    done
fi
SH
cat > "$TEST_ROOT/tools/codesign" <<'SH'
#!/usr/bin/env bash
if [[ "${BEAN_TEST_FAILURE:-}" == sign && "$1" == --force ]]; then exit 42; fi
exec /usr/bin/codesign "$@"
SH
cat > "$TEST_ROOT/tools/mv" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == */.bean-assembly.*/Bean.app && "$2" == "$BEAN_TEST_ROOT/build/Bean.app" ]]; then
    [[ "${BEAN_TEST_FAILURE:-}" != publish ]] || exit 42
    if [[ "${BEAN_TEST_FAILURE:-}" == interrupt ]]; then
        /bin/mv "$@"
        kill -TERM "$PPID"
        exit 0
    fi
fi
exec /bin/mv "$@"
SH
chmod +x "$TEST_ROOT/tools/"* "$TEST_ROOT/scripts/build_app.sh"
export BEAN_TEST_ROOT="$TEST_ROOT"
export PATH="$TEST_ROOT/tools:$PATH"
unset DEVELOPER_ID_APPLICATION
build_fixture() { "$TEST_ROOT/scripts/build_app.sh" release > "$TEST_ROOT/build.log" 2>&1; }
build_fixture
printf 'previous verified fixture' > "$TEST_ROOT/build/Bean.app/Contents/Resources/previous-marker"
/usr/bin/codesign --force --sign - "$TEST_ROOT/build/Bean.app"
previous_hash="$(shasum -a 256 "$TEST_ROOT/build/Bean.app/Contents/_CodeSignature/CodeResources")"
for failure in build sign publish interrupt; do
    if BEAN_TEST_FAILURE="$failure" build_fixture; then echo "Injected $failure failure was accepted" >&2; exit 1; fi
    [[ "$previous_hash" == "$(shasum -a 256 "$TEST_ROOT/build/Bean.app/Contents/_CodeSignature/CodeResources")" ]]
    [[ -f "$TEST_ROOT/build/Bean.app/Contents/Resources/previous-marker" && ! -e "$TEST_ROOT/build/.Bean-build.lock" ]]
    /usr/bin/codesign --verify --deep --strict "$TEST_ROOT/build/Bean.app"
done
BEAN_TEST_HOLD=true build_fixture &
active_build=$!
for ((attempt=0; attempt<300; attempt++)); do [[ ! -f "$TEST_ROOT/started" ]] || break; sleep .01; done
[[ -f "$TEST_ROOT/started" ]] || { echo 'Concurrent fixture did not start' >&2; exit 1; }
if build_fixture; then echo 'A second build acquired the active publication lock' >&2; exit 1; fi
touch "$TEST_ROOT/release"
wait "$active_build"
[[ ! -e "$TEST_ROOT/build/.Bean-build.lock" && ! -e "$TEST_ROOT/build/Bean.app/Bean.app" ]]
/usr/bin/codesign --verify --deep --strict "$TEST_ROOT/build/Bean.app"
echo 'Real bundle assembly/signature, compile/sign/publish failures, interruption recovery and concurrent publication passed.'
