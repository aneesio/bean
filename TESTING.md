# Bean Testing Guide

Automated checks are necessary but cannot fully exercise macOS Accessibility,
clipboard replacement, or third-party editor geometry. Every public beta should
pass both the automated suite and the focused manual matrix below.

The complete phase-by-phase release-candidate protocol and sign-off record live
in [QA_TEST_PLAN.md](QA_TEST_PLAN.md).

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
| Chromium (Gmail + Slack web) | Manual path best effort | Honest AX fallback | Editable DOM field only | Extension on by default unless blocked | Search/email-address/buttons excluded |

Also test one code editor, a search field, password field, disabled field,
read-only field, and ordinary button. Focused-field replacement, Bubble, and
inline UI must fail closed according to [SUPPORTED_APPS.md](SUPPORTED_APPS.md).

Record macOS version, app version, acquisition path, replacement result, and any
content-free diagnostics. Update [SUPPORTED_APPS.md](SUPPORTED_APPS.md) when a
repeatable compatibility boundary changes.

## Cost and privacy gate

- Fresh preferences show native automatic writing features and diagnostics: Off.
- Fresh preferences show Automatic provider checks: Off.
- Pausing after typing makes no provider request with defaults.
- “Disable automatic AI checks” turns off passive, provider inline, fallback,
  and web inline paths while preserving explicit actions.
- Reach the daily automatic-call limit, clear usage/history, and confirm the
  visible ledgers clear while today's private limit remains reached.
- If private accounting is unavailable or corrupt, AI & Usage shows a warning
  instead of reporting a misleading zero; automatic provider checks fail closed.
- Clear usage/history with a request in flight, then let it finish; neither
  visible ledger may be recreated by the late result.
- A native Live-suggestion preview's explicit **Try Again** remains available
  after the automatic cap and is recorded as a manual call. Browser **Fix Paragraph**
  remains capped because a webpage cannot prove a trusted native user gesture.
- Diagnostics are off by default and contain no source or output text when on.
- API keys never appear in UserDefaults, Application Support, logs, diagnostics,
  browser storage, packaged resources, or Git history.
- Writing Context items and dictionary terms are sent only when relevant to the selected
  action as documented in [PRIVACY.md](PRIVACY.md).

## Browser extension gate

- A fresh install enables local checks across ordinary websites and has no
  blocked sites. Deeper AI remains governed by the Bean app's provider and
  browser-AI settings; the extension has no redundant global switch.
- Saving an exact blocked hostname stops Bean there immediately and excludes
  that hostname and its subdomains from future registration.
- Reloading an ordinary, unblocked site activates plain text inputs, textareas,
  and simple contenteditable editors.
- **Disable on this field** stops Bean on that DOM field for the page session;
  **Disable on this website** persists the current hostname in the blocklist.
- Disable two fields, return to each one, and verify its own **Re-enable**
  control restores that field only. A failed blocklist write must leave Bean
  active and announce that the website could not be blocked.
- Hovering a paragraph Bean icon opens its actions, including both disable
  controls.
- Activate issue underlines and paragraph icons with VoiceOver/AXPress as well
  as pointer, Enter, and Space. Next, Ignore, Apply, and Review one by one must
  keep a sensible focus target or return focus to the source field.
- Password, search/ARIA-search, email, one-time-code, card-number,
  numeric-secret, read-only, and code fields plus Google Docs canvas are skipped.
- Local checks work with no native host and make no network request.
- Provider checks require a compatible local bridge, a configured provider,
  and **Allow deeper AI checks from the browser** in the Bean app.
- Sender hostname and field type are validated inside the extension, then
  omitted from the native payload. Provider prompts use only Bean's fixed
  `Browser` / `web editor` labels.
- Applying an issue verifies the exact live substring and preserves line breaks.
- Options reports all-site coverage, lists blocked websites, and saves changes
  automatically.
- A review-required paragraph shows the before/after approval card and is not
  applied until approved.
- **Check again** reports the automatic daily-call count and limit.
- All provider-backed browser requests, including **Fix Paragraph**, stop at the
  reported automatic limit; local issue application remains available.
- **Check again** reaches a final Connected/Error state within seven seconds;
  it never remains on Checking indefinitely.
- Settings discovers a loaded Bean extension and Connect/Repair writes an exact
  per-user host manifest without Terminal.
- In Slack desktop, click the composer and type at least two characters before
  choosing Bean → Help → Check Current Field. The report should identify the
  guarded Slack typing fallback; clicking Bean's menu must not erase that evidence.

Use `BrowserExtension/test/fixtures/editor.html` for deterministic manual cases.

## Update and navigation gate

- Settings has exactly five primary destinations: General, Writing, AI & Usage,
  Browser, and Privacy & Help. Personalization lives within Writing.
- Troubleshooting details, field metadata, and operation history appear only
  inside Advanced diagnostics; the menu bar keeps only everyday actions.
- First launch shows the guided onboarding flow. Closing it early does not mark
  onboarding complete, and **Start using Bean** is the explicit finish action.
- Launching and leaving Bean idle makes no GitHub update request.
- Clicking **Check for Updates** shows the installed version and newest
  non-draft GitHub release, including its prerelease status.
- Offline, rate-limited, malformed, and empty responses produce an actionable
  error and leave the rest of Settings usable.
- The release button is offered only for an HTTPS URL below
  `github.com/aneesio/bean/releases/` and opens the browser without downloading
  or installing an asset.

## Support and full-reset gate

Use a disposable macOS account or a purpose-built test profile. Never run the
manual reset gate against personal API keys, personalization, or browser data.

- Privacy & Help shows repair cards only for actionable setup findings. An
  optional, absent browser extension must not be presented as a broken setup.
- **Copy Diagnostics Summary** copies only the diagnostics block and does not
  open GitHub. **Preview Support Report** shows the complete report before any
  clipboard or browser action.
- Simulate failed pasteboard and GitHub-open results. Neither action may show
  success, and each error must remain visible in the surface where it occurred.
- After a successful copy, the preview says the report was copied but not saved
  or sent; it must no longer claim that Bean never copied it.
- Opening the GitHub bug form does not copy, save, or upload the report. Copying
  the report does not open a browser. Review both clipboard payloads for source
  text, transformed text, prompts, API keys, clipboard content, and field labels.
- Diagnostics use current Writing Context/Live suggestions names, classify the
  active style as a canonical built-in or `custom`, and omit custom profile
  names, personalization text, full app/native-host paths, hostnames, and field
  labels.
- About shows Bean 1.6.0 (8), identifies the community-supported public beta,
  and opens only the canonical `aneesio/bean` GitHub, Support, Privacy, License,
  Changelog, and manual update-check destinations. At the minimum width and
  larger Accessibility text sizes, links reflow and **Open Update Check…** lands
  on the visible Updates section in General.
- Cancel **Full Reset Bean…** and verify nothing changes.
- Both visible **Clear usage and operation history** controls require a
  destructive confirmation and preserve today's private automatic-call count.
- On a disposable profile, confirm Full Reset removes both provider Keychain
  entries, all Bean user-content artifacts/generated backups, visible usage and
  operation history, private automatic-call state, onboarding/preferences,
  launch-at-login registration, exact `com.bean.nativehost.json` manifests, and
  Bean's manual extension approval. Unrelated Keychain items, preference
  domains, files, browser profiles, extensions, and neighboring native hosts
  must remain untouched.
- A successful reset quits Bean. Reopen it and verify Welcome appears with safe
  defaults. A failed cleanup must keep Bean open, name the failed area, list any
  protected steps not attempted, and never say the reset completed.
- Accessibility authorization remains until the tester removes or disables Bean
  in System Settings → Privacy & Security → Accessibility. The Chrome extension
  and its local settings/blocked-sites list also remain until cleared or removed
  in the browser. Reset copy must state both boundaries.

## Release artifact gate

Create an explicitly unnotarized public-beta artifact with:

```bash
BEAN_ALLOW_ADHOC_RELEASE=1 ./scripts/package_release.sh
```

Verify:

- the app is universal (`arm64` and `x86_64`);
- the ZIP and DMG names include `-unnotarized`;
- the SHA-256 file matches both artifacts;
- the app contains current README, TESTING, QA_TEST_PLAN, SUPPORT, PRIVACY, LICENSE, CHANGELOG,
  and extension resources;
- the repository remains clean except for intended source changes;
- installation from the DMG preserves shortcuts, Keychain access, and settings.
- app/build/changelog/tag versions match, and the extension version was
  incremented when extension code changed;
- README, Privacy, DMG, and release notes consistently identify the artifact as
  an unnotarized prerelease and describe browser/provider-cost behavior.

Developer ID releases must additionally pass notarization, stapling, and
Gatekeeper assessment. The packaging script fails closed when those credentials
are incomplete.
