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

Test the current release candidate in:

- TextEdit: selection, focused field, bubble, and experimental native inline;
- Notes and Mail: selection, replacement, formatting preservation;
- Slack desktop: composer focus, Bean Bubble, manual replacement, typing pause;
- one additional Electron app: safe fallback behavior;
- Chrome: normal page field through the Mac app;
- one code editor: selected prose only, no bubble/inline in code by default;
- search, password, disabled, and read-only fields: no bubble or operation.

Record macOS version, app version, acquisition path, replacement result, and any
content-free diagnostics. Update [SUPPORTED_APPS.md](SUPPORTED_APPS.md) when a
repeatable compatibility boundary changes.

## Cost and privacy gate

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

Use `BrowserExtension/test/fixtures/editor.html` for deterministic manual cases.

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

Developer ID releases must additionally pass notarization, stapling, and
Gatekeeper assessment. The packaging script fails closed when those credentials
are incomplete.
