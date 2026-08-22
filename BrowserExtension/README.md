# Bean Browser Extension

This experimental Manifest V3 extension adds inline proofreading to supported
web text fields. It is an unpacked developer beta, not a Chrome Web Store
release.

## Defaults

- Local writing help is enabled on ordinary websites after install.
- Add websites to the blocked list when you do not want Bean there.
- Correction cards offer **Disable on this field** and **Disable on this
  website**. Field blocking lasts for the current page session; website
  blocking is saved locally.
- Local deterministic checks by default; no provider or token cost.
- Provider-backed checks require a second opt-in and the local Bean bridge.
- No API key, page text, or correction history is stored by the extension.

Chrome displays a broad website-access warning because universal coverage is
the product default. Bean still skips passwords, search and address fields,
code editors, buttons, disabled controls, and read-only content.

## Install from a GitHub Bean release

1. Keep Bean in `/Applications`, open it, and go to **Settings → Browser**.
2. Click **Show Extension Folder** and **Open Extensions Page**.
3. Turn on Developer mode, choose **Load unpacked**, and select the revealed
   `BrowserExtension` folder.
4. Back in Bean, click **Connect Bean to Browser**. No Terminal command is
   required.
5. Reload the extension once. Bean now works in supported fields on ordinary
   websites; use Options only to pause it or block websites.

Blocked hostnames and their subdomains are excluded from future content-script
registration. If a site is blocked while already open, Bean stops there
immediately; reload once to unload the dormant script.

## Optional native bridge

The local detector requires no Mac app connection. For deeper provider-backed
issues and whole-paragraph proofreading, use **Connect Bean to Browser** in Bean
Settings. Bean reads only Chromium extension ID/path metadata, validates that
the loaded extension is Bean, and restricts the native host to the detected ID.
The command-line installer remains available only as a developer/recovery tool.

Enable **Allow deeper AI checks from the browser** in Bean Settings → Browser
and **Use my Bean app for deeper AI checks** in extension Options. These checks can incur provider API charges
after typing pauses, are rate-limited by the extension, contribute to Bean's
content-free Web Inline usage total, and stop at Bean's daily automatic-call
limit.

The install manifest accepts only validated Bean extension IDs. See
[`NativeMessaging/README.md`](../NativeMessaging/README.md).

## Supported fields

Best support:

- plain text inputs;
- textareas;
- simple contenteditable editors.

Always excluded:

- password, search, email, URL, telephone, and number inputs;
- disabled, read-only, hidden, or tiny controls;
- code editors and `pre`/`code` regions;
- Google Docs canvas editing;
- interactive buttons and links nested inside editable regions.

Complex rich editors may decline highlighting when DOM text cannot be mapped to
one exact live range. That refusal is intentional.

## Safety behavior

- Suggestions map only when the original substring occurs exactly once.
- Apply re-verifies the live substring immediately before editing.
- Value-field replacement preserves everything outside the target range exactly.
- Whole-paragraph replacement rechecks the paragraph and refuses rich blocks
  containing markup that cannot be preserved safely.
- Provider wrappers, wrapping quotes, and zero-width artifacts are sanitized.
- Unusual-but-plausible whole-paragraph results show a before/after approval
  card and are never applied automatically.
- Typing invalidates outstanding requests and stale overlays.

## Tests

```bash
node test/run-tests.js
open test/fixtures/editor.html
```

The automated tests cover migrations, local detection, range/sanitization
helpers, universal coverage/blocklist behavior, and permission rules. The fixture covers browser layout
and interaction behavior manually.

## Files

- `manifest.json`: MV3 declaration and website permissions.
- `background.js`: all-site registration, blocklist exclusions, and native messaging.
- `src/localDetector.js`: offline conservative detector.
- `src/issueMapping.js`: exact range mapping and safe replacement helpers.
- `src/overlay.js`: isolated visual highlights and correction cards.
- `src/contentScript.js`: field detection, orchestration, and stale guards.
- `options.html` / `options.js`: blocklist, cost controls, and bridge status.

See the project [privacy policy](../PRIVACY.md) before changing data flows or
permissions.
