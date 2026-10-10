#!/usr/bin/env bash
# Exercises the real installer with signed, private app copies. Never installs
# into /Applications and never launches Bean or alters preferences/permissions.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="${1:-$ROOT/build/Bean.app}"
[[ -d "$SOURCE" ]] || { echo "Build Bean first, or pass a verified app bundle." >&2; exit 2; }
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/bean-install-test.XXXXXX")"
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/apps" "$TEST_ROOT/tools"
export BEAN_INSTALL_DESTINATION="$TEST_ROOT/apps/Bean.app"
export BEAN_INSTALL_BACKUP_ROOT="$TEST_ROOT/backups"
export BEAN_TEST_DEST="$BEAN_INSTALL_DESTINATION"
make_candidate() {
    local target="$1" marker="$2"
    ditto "$SOURCE" "$target"
    printf '%s' "$marker" > "$target/Contents/install-test-marker"
    codesign --force --deep --sign - "$target" >/dev/null 2>&1
    codesign --verify --deep --strict "$target"
}
assert_marker() {
    [[ "$(cat "$BEAN_INSTALL_DESTINATION/Contents/install-test-marker")" == "$1" ]] || {
        echo "Wrong installed candidate after $2" >&2; exit 1;
    }
    codesign --verify --deep --strict "$BEAN_INSTALL_DESTINATION"
}
install_candidate() { "$ROOT/scripts/install_local_build.sh" "$1" > "$TEST_ROOT/install.log" 2>&1; }
make_candidate "$TEST_ROOT/first.app" "first"
make_candidate "$TEST_ROOT/second.app" "second"
install_candidate "$TEST_ROOT/first.app"
assert_marker first fresh-install
install_candidate "$TEST_ROOT/second.app"
assert_marker second upgrade
ROLLBACK="$(sed -n 's/^Verified rollback source: //p' "$TEST_ROOT/install.log")"
[[ -n "$ROLLBACK" && "$(cat "$ROLLBACK/Contents/install-test-marker")" == first ]]
install_candidate "$ROLLBACK"
assert_marker first rollback

ditto "$TEST_ROOT/second.app" "$TEST_ROOT/corrupt.app"
printf 'tampered' >> "$TEST_ROOT/corrupt.app/Contents/install-test-marker"
if install_candidate "$TEST_ROOT/corrupt.app"; then echo 'Corrupt app was accepted' >&2; exit 1; fi
assert_marker first rejected-signature

mv "$BEAN_INSTALL_DESTINATION" "$TEST_ROOT/symlink-target.app"
ln -s "$TEST_ROOT/symlink-target.app" "$BEAN_INSTALL_DESTINATION"
if install_candidate "$TEST_ROOT/second.app"; then echo 'Symlink destination was accepted' >&2; exit 1; fi
rm "$BEAN_INSTALL_DESTINATION"
mv "$TEST_ROOT/symlink-target.app" "$BEAN_INSTALL_DESTINATION"
assert_marker first rejected-symlink

cat > "$TEST_ROOT/tools/mv" <<'SH'
#!/usr/bin/env bash
if [[ "${BEAN_TEST_FAILURE:-}" == publish && "$1" == */.Bean-install.*/Bean.app && "$2" == "$BEAN_TEST_DEST" ]]; then exit 1; fi
if [[ "${BEAN_TEST_FAILURE:-}" == interrupt && "$1" == "$BEAN_TEST_DEST" && "$2" == */previous.app ]]; then
    /bin/mv "$@"
    kill -TERM "$PPID"
    exit 0
fi
exec /bin/mv "$@"
SH
cat > "$TEST_ROOT/tools/codesign" <<'SH'
#!/usr/bin/env bash
if [[ "${BEAN_TEST_FAILURE:-}" == verify && "${!#}" == "$BEAN_TEST_DEST" ]]; then exit 1; fi
exec /usr/bin/codesign "$@"
SH
chmod +x "$TEST_ROOT/tools/mv" "$TEST_ROOT/tools/codesign"
for failure in publish verify interrupt; do
    if PATH="$TEST_ROOT/tools:$PATH" BEAN_TEST_FAILURE="$failure" install_candidate "$TEST_ROOT/second.app"; then
        echo "Injected $failure failure was accepted" >&2; exit 1
    fi
assert_marker first "$failure-recovery"
done
cat > "$TEST_ROOT/tools/ditto" <<'SH'
#!/usr/bin/env bash
if [[ "${BEAN_TEST_HOLD_STAGE:-}" == true && "${!#}" == */.Bean-install.*/Bean.app ]]; then
    touch "$BEAN_TEST_STARTED"
    for ((attempt=0; attempt<500; attempt++)); do
        [[ ! -f "$BEAN_TEST_RELEASE" ]] || break
        sleep .01
    done
fi
exec /usr/bin/ditto "$@"
SH
chmod +x "$TEST_ROOT/tools/ditto"
export BEAN_TEST_STARTED="$TEST_ROOT/concurrent-started"
export BEAN_TEST_RELEASE="$TEST_ROOT/concurrent-release"
PATH="$TEST_ROOT/tools:$PATH" BEAN_TEST_HOLD_STAGE=true install_candidate "$TEST_ROOT/second.app" &
concurrent_installer=$!
for ((attempt=0; attempt<300; attempt++)); do
    [[ ! -f "$BEAN_TEST_STARTED" ]] || break
    sleep .01
done
[[ -f "$BEAN_TEST_STARTED" ]] || { echo 'Concurrent install fixture did not start' >&2; exit 1; }
if install_candidate "$TEST_ROOT/first.app"; then
    echo 'A second installer acquired an active destination' >&2; exit 1
fi
touch "$BEAN_TEST_RELEASE"
wait "$concurrent_installer"
assert_marker second concurrent-install
[[ ! -e "$BEAN_INSTALL_DESTINATION/Bean.app" ]] || { echo 'Concurrent install nested an app' >&2; exit 1; }
if find "$TEST_ROOT/apps" -maxdepth 1 -name '.Bean-install.*' | read -r _; then
    echo 'Installer left staging behind' >&2; exit 1
fi
echo 'Local install, upgrade, rollback, invalid signature, symlink, publish failure, final verification failure, interruption and concurrent-install checks passed.'
