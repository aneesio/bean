#!/usr/bin/env bash
# Fast, content-free checks for version, navigation, and update metadata that is
# easy to let drift before a public tag.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - Resources/Info.plist)"
APP_BUILD="$(plutil -extract CFBundleVersion raw -o - Resources/Info.plist)"
EXTENSION_VERSION="$(node -p "require('./BrowserExtension/manifest.json').version")"

[[ "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || {
    echo "error: invalid app version: $APP_VERSION" >&2
    exit 1
}
[[ "$APP_BUILD" =~ ^[1-9][0-9]*$ ]] || {
    echo "error: invalid app build: $APP_BUILD" >&2
    exit 1
}
[[ "$EXTENSION_VERSION" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]] || {
    echo "error: invalid browser extension version: $EXTENSION_VERSION" >&2
    exit 1
}

grep -Fq "?? \"$APP_VERSION\"" Sources/Bean/Core/AppInfo.swift || {
    echo "error: AppInfo version fallback does not match Info.plist" >&2
    exit 1
}
grep -Fq "?? \"$APP_BUILD\"" Sources/Bean/Core/AppInfo.swift || {
    echo "error: AppInfo build fallback does not match Info.plist" >&2
    exit 1
}
grep -Eq "^## $APP_VERSION .*public beta" CHANGELOG.md || {
    echo "error: CHANGELOG has no public-beta heading for $APP_VERSION" >&2
    exit 1
}

EXPECTED_CATEGORIES="general=General
writing=Writing
provider=AI & Usage
personalization=Personalization
browser=Browser
privacy=Privacy & Support"
ACTUAL_CATEGORIES="$(sed -n '/enum Category:/,/var id:/p' Sources/Bean/UI/SettingsView.swift \
    | sed -n 's/^[[:space:]]*case \([a-zA-Z]*\) = "\([^"]*\)"/\1=\2/p')"
[[ "$ACTUAL_CATEGORIES" == "$EXPECTED_CATEGORIES" ]] || {
    echo "error: primary Settings navigation differs from the six-category release contract" >&2
    exit 1
}

UPDATE_CONSUMERS="$(grep -R -l --include='*.swift' 'UpdateChecker()' Sources/Bean || true)"
[[ "$UPDATE_CONSUMERS" == "Sources/Bean/UI/SettingsView.swift" ]] || {
    echo "error: UpdateChecker must remain user-triggered from Settings only" >&2
    exit 1
}

EXPECTED_TAG="${1:-}"
if [[ -z "$EXPECTED_TAG" && "${GITHUB_REF_TYPE:-}" == "tag" ]]; then
    EXPECTED_TAG="${GITHUB_REF_NAME:-}"
fi
if [[ -n "$EXPECTED_TAG" && "$EXPECTED_TAG" != "v$APP_VERSION" ]]; then
    echo "error: tag $EXPECTED_TAG does not match app version $APP_VERSION" >&2
    exit 1
fi

echo "Release metadata verified: app $APP_VERSION ($APP_BUILD), extension $EXTENSION_VERSION"
