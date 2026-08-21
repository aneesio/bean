#!/usr/bin/env bash
# Content-free repository audit. Reports only paths/rules, never matched values.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

failures=0

echo "==> Checking forbidden tracked paths…"
FORBIDDEN="$(git ls-files | grep -E '(^release/|^build/|^\.build/|^\.swiftpm/|(^|/)xcuserdata/|\.xcuserstate$|(^|/)\.env($|\.)|\.(p8|p12|pem|mobileprovision)$)' || true)"
if [[ -n "$FORBIDDEN" ]]; then
    echo "error: generated, personal, or sensitive-looking paths are tracked:" >&2
    printf '%s\n' "$FORBIDDEN" >&2
    failures=1
else
    echo "    ok"
fi

echo "==> Checking tracked blob sizes…"
LARGE_BLOBS="$(git ls-files -s | awk '{print $2}' | sort -u | git cat-file --batch-check='%(objectname) %(objectsize)' | awk '$2 > 5242880 {print $1}')"
if [[ -n "$LARGE_BLOBS" ]]; then
    echo "error: tracked blobs larger than 5 MiB were found:" >&2
    while read -r object; do
        git ls-files -s | awk -v object="$object" '$2 == object {print $4}' >&2
    done <<< "$LARGE_BLOBS"
    failures=1
else
    echo "    ok"
fi

echo "==> Scanning current tree and Git history for credential signatures…"
OPENAI_PREFIX="s""k-"
ANTHROPIC_PREFIX="s""k-ant-"
PRIVATE_KEY_MARKER="BEGIN ""PRIVATE KEY"
PATTERN="${ANTHROPIC_PREFIX}[A-Za-z0-9_-]{20,}|${OPENAI_PREFIX}[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|${PRIVATE_KEY_MARKER}"
REPORT="$(mktemp)"
trap 'rm -f "$REPORT"' EXIT

while IFS= read -r -d '' file; do
    [[ "$file" == "scripts/audit_repository.sh" ]] && continue
    if grep -Iq . "$file" 2>/dev/null && grep -Eq "$PATTERN" "$file" 2>/dev/null; then
        printf 'working-tree:%s\n' "$file" >> "$REPORT"
    fi
done < <(git ls-files --cached --others --exclude-standard -z)

while read -r revision; do
    if git grep -I -l -E "$PATTERN" "$revision" -- . ':!scripts/audit_repository.sh' > "$REPORT.current" 2>/dev/null; then
        sed -E 's/^[0-9a-f]{40}://' "$REPORT.current" >> "$REPORT"
    fi
done < <(git rev-list --all)
rm -f "$REPORT.current"

if [[ -s "$REPORT" ]]; then
    echo "error: possible credentials detected; matched values are intentionally hidden:" >&2
    sort -u "$REPORT" >&2
    failures=1
else
    echo "    ok"
fi

if [[ "$failures" -ne 0 ]]; then
    exit 1
fi

echo "Repository audit passed."
