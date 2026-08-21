#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ -z "${DEVELOPER_DIR:-}" && -d "/Applications/Xcode.app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

SWIFT_TEST_ARGS=()
if [[ "${BEAN_DISABLE_SWIFTPM_SANDBOX:-0}" == "1" ]]; then
    SWIFT_TEST_ARGS+=(--disable-sandbox)
fi

echo "==> XCTest suite…"
if [[ "${#SWIFT_TEST_ARGS[@]}" -gt 0 ]]; then
    swift test "${SWIFT_TEST_ARGS[@]}"
else
    swift test
fi

echo "==> Standalone logic suite…"
"$ROOT/scripts/run_logic_tests.sh"

echo "==> Browser extension suite…"
node "$ROOT/BrowserExtension/test/run-tests.js"

echo "==> Shell syntax…"
for script in "$ROOT"/scripts/*.sh; do
    bash -n "$script"
done

echo "==> Repository audit…"
"$ROOT/scripts/audit_repository.sh"

echo "All automated checks passed."
