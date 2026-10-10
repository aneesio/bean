#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
MODE="${1:---dry-run}"
case "$MODE" in
    --dry-run) export BEAN_PROVIDER_EVALUATION_MODE=dry-run ;;
    --paid) export BEAN_PROVIDER_EVALUATION_MODE=paid ;;
    *) echo "Usage: $0 [--dry-run|--paid] [new-output-directory]" >&2; exit 2 ;;
esac
if [[ "$#" -gt 0 ]]; then shift; fi
if [[ "$#" -gt 1 ]]; then echo "Supply one new output directory." >&2; exit 2; fi
export BEAN_EVAL_OUTPUT_DIRECTORY="${1:-$ROOT/build/provider-evaluation/$(date +%Y%m%d-%H%M%S)-$BEAN_PROVIDER_EVALUATION_MODE}"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
SWIFT_ARGS=(--filter 'ProviderQualityEvaluationTests|ProviderEvaluationPolicyTests')
if [[ "${BEAN_DISABLE_SWIFTPM_SANDBOX:-0}" == "1" ]]; then SWIFT_ARGS+=(--disable-sandbox); fi
swift test "${SWIFT_ARGS[@]}"
echo "Evaluation artifacts: $BEAN_EVAL_OUTPUT_DIRECTORY"
echo "Blind human ratings remain required; keep run-metadata.json separate from reviewers."
