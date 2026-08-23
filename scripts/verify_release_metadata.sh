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
node BrowserExtension/test/versionContract.test.js >/dev/null
grep -Eq "^## $APP_VERSION .*public beta" CHANGELOG.md || {
    echo "error: CHANGELOG has no public-beta heading for $APP_VERSION" >&2
    exit 1
}

[[ "$APP_VERSION" == "1.6.0" && "$APP_BUILD" == "11" && "$EXTENSION_VERSION" == "0.7.2" ]] || {
    echo "error: current public-beta contract must be app 1.6.0 (11), extension 0.7.2" >&2
    exit 1
}

grep -Fq "shasum -a 256 Bean-$APP_VERSION-unnotarized.dmg" README.md || {
    echo "error: README checksum example does not match the app version" >&2
    exit 1
}

for doc in README.md ROADMAP.md TESTING.md QA_TEST_PLAN.md SUPPORTED_APPS.md SUPPORT.md PRIVACY.md \
    CONTRIBUTING.md RELEASING.md RELEASE_NOTES.md SECURITY.md LICENSE.md CHANGELOG.md; do
    [[ -s "$doc" ]] || {
        echo "error: required public document is missing or empty: $doc" >&2
        exit 1
    }
done

for phrase in "unnotarized prerelease" "Open Anyway" "provider charges" \
    "ordinary websites" "by default"; do
    grep -Fqi "$phrase" RELEASE_NOTES.md || {
        echo "error: RELEASE_NOTES.md omits required public-beta wording: $phrase" >&2
        exit 1
    }
done

for doc in README.md TESTING.md SUPPORT.md PRIVACY.md; do
    grep -Fq "Full Reset" "$doc" || {
        echo "error: $doc does not describe Full Reset" >&2
        exit 1
    }
done

grep -Fq "Preview Support Report" SUPPORT.md || {
    echo "error: SUPPORT.md does not describe report preview" >&2
    exit 1
}
grep -Fq "Accessibility" PRIVACY.md || {
    echo "error: PRIVACY.md omits the manual Accessibility boundary" >&2
    exit 1
}
grep -Fq "blocked-sites" PRIVACY.md || {
    echo "error: PRIVACY.md omits the extension-local reset boundary" >&2
    exit 1
}

for script in scripts/install_native_messaging_host.sh scripts/uninstall_native_messaging_host.sh; do
    grep -Fq "browserBridgeApprovedManualExtensionIDs" "$script" || {
        echo "error: $script does not keep the hardened manual extension approval in sync" >&2
        exit 1
    }
done
if grep -Fq "Web Inline Support" scripts/install_native_messaging_host.sh; then
    echo "error: advanced native-host installer uses retired browser-AI copy" >&2
    exit 1
fi

STALE_SUPPORT_COPY="$(grep -R -n -E 'Privacy & Support|Copy diagnostics and report a problem|Passive Suggestions|Passive Preview|[Cc]ontext cards?' \
    README.md ROADMAP.md TESTING.md SUPPORTED_APPS.md SUPPORT.md PRIVACY.md \
    CONTRIBUTING.md RELEASING.md \
    .github/ISSUE_TEMPLATE 2>/dev/null || true)"
[[ -z "$STALE_SUPPORT_COPY" ]] || {
    echo "error: stale support navigation/copy remains:" >&2
    echo "$STALE_SUPPORT_COPY" >&2
    exit 1
}

EXPECTED_CATEGORIES="general=General
writing=Writing
provider=AI & Usage
browser=Browser
privacy=Privacy & Help"
ACTUAL_CATEGORIES="$(sed -n '/enum Category:/,/var id:/p' Sources/Bean/UI/SettingsView.swift \
    | sed -n 's/^[[:space:]]*case \([a-zA-Z]*\) = "\([^"]*\)"/\1=\2/p')"
[[ "$ACTUAL_CATEGORIES" == "$EXPECTED_CATEGORIES" ]] || {
    echo "error: primary Settings navigation differs from the five-category release contract" >&2
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
