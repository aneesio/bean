#!/usr/bin/env bash
# Runs Bean's deterministic logic tests (no API calls, no AppKit, no user text).
# Compiles the REAL WritingAction + OutputSafetyValidator together with a small
# test harness and runs it.
#
#   ./scripts/run_logic_tests.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -z "${DEVELOPER_DIR:-}" && -d "/Applications/Xcode.app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
OUT="$TMP_DIR/bean_logic_tests"

echo "==> Compiling logic tests…"
swiftc -parse-as-library -o "$OUT" \
    "$ROOT/Sources/Bean/Core/WritingAction.swift" \
    "$ROOT/Sources/Bean/Core/TextNormalizer.swift" \
    "$ROOT/Sources/Bean/LLM/OutputSafetyValidator.swift" \
    "$ROOT/Sources/Bean/LLM/ParagraphSanitizer.swift" \
    "$ROOT/scripts/LogicTests.swift"

echo "==> Running…"
"$OUT"
