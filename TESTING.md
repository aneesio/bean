# Bean Testing Guide

Automated checks are necessary but cannot fully exercise macOS Accessibility,
clipboard replacement, or third-party editor geometry. Every public beta should
pass both the automated suite and the focused manual matrix below.

Use synthetic text only. Never place real API keys or private writing in test
logs, screenshots, fixtures, or issues.

## Automated checks

Run the complete local suite:

```bash
./scripts/run_all_tests.sh
```

It runs:

- XCTest regression tests against the app module;
- the standalone safety/normalization harness;
- browser detector, mapping, settings-migration, and manifest tests;
- shell syntax checks;
- repository and Git-history secret/path audits.

Then assemble a fresh app:

```bash
./scripts/build_app.sh release
codesign --verify --deep --strict --verbose=2 build/Bean.app
```

## Clean-install gate

- Quit every running copy of Bean.
- Put the candidate in a stable path, normally `/Applications/Bean.app`.
- Remove the prior Accessibility entry when testing an identity change.
- Launch Bean and complete onboarding without developer assistance.
- Confirm provider selection, Keychain persistence, Accessibility re-check, both
  shortcuts, menu bar icon, Settings, About, and launch at login.
- Quit and relaunch; settings and shortcuts must remain stable.

## Core action gate

Exercise selected text and focused-field mode with short synthetic samples:

| Scenario | Expected result |
| --- | --- |
| `i has a apple` → Proofread | Small grammatical correction; no commentary footer. |
| Already-correct sentence | No replacement or a clear no-changes result. |
| Make Clearer/Concise/Professional/Casual | Preview appears before replacement. |
| Reply actions | Draft is copy-first and never replaces the source message. |
| Provider returns a label/fence/footer | Wrapper is removed or unsafe output is rejected. |
| Field changes while request is running | Bean refuses stale replacement and preserves the correction safely. |
| Paste cannot be verified | UI says the correction is on the clipboard; it never falsely says “fixed.” |

After every replacement test, verify text before and after the intended range is
unchanged and the prior clipboard is restored unless the UI explicitly reports a
clipboard fallback.

## App compatibility gate

The five reference experiences are release-blocking. Record pass/fail and a
reason code for every non-pass; do not silently mark an unavailable app as
tested.

| Surface | Selected text | Focused field | Bubble | Inline/fallback | Boundary check |
| --- | --- | --- | --- | --- | --- |
| TextEdit | Correct + verify | Correct + verify | Anchors only to editor | Native highlight or documented range fallback | Read-only view excluded |
| Apple Notes | Correct selection | Preserve note structure | No button/control anchors | Native or passive fallback | Formatting outside target unchanged |
| Apple Mail | Correct in composer | Preserve greeting/sign-off | Composer only | Native or passive fallback | Displayed mail excluded |
| Slack desktop | Correct selection | Composer replacement or honest fallback | Composer/evidence only | Passive/manual; no fake native inline | Channel buttons excluded |
| Chromium (Gmail + Slack web) | Manual path best effort | Honest AX fallback | Editable DOM field only | Extension on exact approved host | Search/email-address/buttons excluded |

Also test one code editor, a search field, password field, disabled field,
read-only field, and ordinary button. Focused-field replacement, Bubble, and
inline UI must fail closed according to [SUPPORTED_APPS.md](SUPPORTED_APPS.md).

Record macOS version, app version, acquisition path, replacement result, and any
content-free diagnostics. Update [SUPPORTED_APPS.md](SUPPORTED_APPS.md) when a
repeatable compatibility boundary changes.

## Cost and privacy gate

- Fresh preferences show every Labs feature and diagnostics: Off.
- Fresh preferences show Automatic provider checks: Off.
- Pausing after typing makes no provider request with defaults.
- “Disable automatic AI checks” turns off passive, provider inline, fallback,
  and web inline paths while preserving explicit actions.
- Diagnostics are off by default and contain no source or output text when on.
- API keys never appear in UserDefaults, Application Support, logs, diagnostics,
  browser storage, packaged resources, or Git history.
- Context cards and dictionary terms are sent only when relevant to the selected
  action as documented in [PRIVACY.md](PRIVACY.md).

## Browser extension gate

- A fresh install is disabled, has no approved sites, and has provider bridge
  use disabled.
- Saving an exact hostname produces a Chrome permission prompt only for that
  hostname; removing it revokes permission.
- Reloading an approved site activates plain text inputs, textareas, and simple
  contenteditable editors.
- Unapproved sites receive no Bean content script.
- Password/search/email/read-only/code fields and Google Docs canvas are skipped.
- Local checks work with no native host and make no network request.
- Provider checks require both extension bridge opt-in and Web Inline Support in
  the Bean app.
- Applying an issue verifies the exact live substring and preserves line breaks.
- Gmail and Slack web status rows reflect exact-host approval.
- A review-required paragraph shows the before/after approval card and is not
  applied until approved.
- Test Connection reports the automatic daily-call count and limit.

Use `BrowserExtension/test/fixtures/editor.html` for deterministic manual cases.

## Update and navigation gate

- Settings has exactly eight primary destinations: Setup, Provider & Usage,
  Shortcuts, Actions & Style, Context, Privacy, Labs, and Troubleshooting.
- Bean Bubble, Passive Suggestions, Inline Highlights, and Browser Extension
  appear only in Labs; each starts off with clean preferences.
- Launching and leaving Bean idle makes no GitHub update request.
- Clicking **Check for Updates** shows the installed version and newest
  non-draft GitHub release, including its prerelease status.
- Offline, rate-limited, malformed, and empty responses produce an actionable
  error and leave the rest of Settings usable.
- The release button is offered only for an HTTPS URL below
  `github.com/aneesio/bean/releases/` and opens the browser without downloading
  or installing an asset.

## Release artifact gate

Create an explicitly unnotarized public-beta artifact with:

```bash
BEAN_ALLOW_ADHOC_RELEASE=1 ./scripts/package_release.sh
```

Verify:

- the app is universal (`arm64` and `x86_64`);
- the ZIP and DMG names include `-unnotarized`;
- the SHA-256 file matches both artifacts;
- the app contains current README, PRIVACY, LICENSE, and extension resources;
- the repository remains clean except for intended source changes;
- installation from the DMG preserves shortcuts, Keychain access, and settings.
- app/build/changelog/tag versions match, and the extension version was
  incremented when extension code changed;
- README, Privacy, DMG, and release notes consistently identify the artifact as
  an unnotarized prerelease and describe Labs/provider-cost behavior.

Developer ID releases must additionally pass notarization, stapling, and
Gatekeeper assessment. The packaging script fails closed when those credentials
are incomplete.
