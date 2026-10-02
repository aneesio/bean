#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ENFORCE=0
if [[ "${1:-}" == "--enforce" ]]; then
    ENFORCE=1
    shift
fi
REPORT_DIRECTORY="${1:-$ROOT/build/quality-reports/latest}"
if [[ "$#" -gt 1 ]]; then
    echo "Usage: $0 [--enforce] [report-directory]" >&2
    exit 2
fi
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
export BEAN_RUN_SYSTEM_QUALITY_BENCHMARK=1
export BEAN_ENFORCE_QUALITY_GATES="$ENFORCE"
export BEAN_QUALITY_REPORT_DIRECTORY="$REPORT_DIRECTORY"

SWIFT_ARGS=(--filter WritingQualityCorpusTests)
if [[ "${BEAN_DISABLE_SWIFTPM_SANDBOX:-0}" == "1" ]]; then
    SWIFT_ARGS+=(--disable-sandbox)
fi
swift test "${SWIFT_ARGS[@]}"
echo "Synthetic corpus reports: $REPORT_DIRECTORY"
echo "Real-provider quality and independent human review remain separate release requirements."
