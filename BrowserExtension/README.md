# Bean Browser Extension

This experimental Manifest V3 extension adds inline proofreading to supported
web text fields. It is an unpacked developer beta, not a Chrome Web Store
release.

## Privacy-first defaults

- Disabled on install and upgrade.
- No site access until you approve exact hostnames in Options.
- Local deterministic checks by default; no provider or token cost.
- Provider-backed checks require a second opt-in and the local Bean bridge.
- No API key, page text, or correction history is stored by the extension.

Version 0.2 and later reset older blanket-site settings and bridge opt-ins once
because the extension migrated to Chrome optional host permissions.

## Install from a GitHub Bean release

1. Keep Bean in `/Applications`, open it, and go to **Settings → Labs → Browser
   Extension**.
2. Click **Reveal Bean Extension** and **Open Browser Extensions**.
3. Turn on Developer mode, choose **Load unpacked**, and select the revealed
   `BrowserExtension` folder.
4. Back in Bean, click **Detect and Install**. No Terminal command is required.
5. Reload the extension once and open its Options.
6. Add exact sites such as `mail.google.com` or `app.slack.com`, enable the
   extension, and approve Chrome's site-access prompt.
7. Reload already-open pages on those sites.

The extension registers its content script only for approved hostnames. Removing
a hostname in Options revokes that permission.

## Optional native bridge

The local detector requires no Mac app connection. For deeper provider-backed
issues and whole-paragraph proofreading, use **Detect and Install** in Bean
Settings. Bean reads only Chromium extension ID/path metadata, validates that
the loaded extension is Bean, and restricts the native host to the detected ID.
The command-line installer remains available only as a developer/recovery tool.

Enable **Web Inline Support** in Bean Settings → Labs and **Use the Bean
app/provider** in extension Options. These checks can incur provider API charges
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
helpers, and least-permission manifest rules. The fixture covers browser layout
and interaction behavior manually.

## Files

- `manifest.json`: MV3 declaration and optional host permissions.
- `background.js`: per-site content-script registration and native messaging.
- `src/localDetector.js`: offline conservative detector.
- `src/issueMapping.js`: exact range mapping and safe replacement helpers.
- `src/overlay.js`: isolated visual highlights and correction cards.
- `src/contentScript.js`: field detection, orchestration, and stale guards.
- `options.html` / `options.js`: permissions, cost controls, and bridge status.

See the project [privacy policy](../PRIVACY.md) before changing data flows or
permissions.
