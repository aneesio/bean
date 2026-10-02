# Bean Browser Extension

This experimental Manifest V3 extension adds inline proofreading to supported
web text fields. It is an unpacked developer beta, not a Chrome Web Store
release.

## Defaults

- Local writing help is enabled on ordinary websites after install.
- Add websites to the blocked list when you do not want Bean there.
- A single Bean badge beside the active writing field shows the suggestion
  count and opens suggestions, **Proofread**, and **Rewrite**. Underlines stay
  quiet until you hover or click. The native Mac badge yields while the extension
  owns a supported, focused page field; Mac keyboard shortcuts remain available.
- Correction cards offer **Disable on this field** and **Disable on this
  website**. Field blocking lasts for the current page session; website
  blocking is saved locally.
- Common typo, spacing, capitalization, and repeated-word checks work without a
  connection. Full macOS spelling and basic grammar require **Install Mac
  Connection**, with no API key, provider request, or token cost. An unavailable
  connection is labeled **Basic checks only**; an empty tiny dictionary result
  never claims the writing is free of spelling errors.
- Automatic AI suggestions require a configured provider and browser AI enabled
  in the Bean app. Explicit **Proofread** and rewrite styles use the configured
  provider when available, independently of the automatic AI switch. Proofread
  also works locally without an API key.
- No API key, page text, or correction history is stored by the extension.

Chrome displays a broad website-access warning because universal coverage is
the product default. Bean still skips passwords, search, email, URL, telephone,
and number fields, plus code editors, buttons, disabled controls, and read-only
content.

## Install from a GitHub Bean release

1. Keep Bean in `/Applications`, open it, and go to **Settings → Browser**.
2. Click **Show Extension Folder** and **Open Extensions Page**.
3. Turn on Developer mode, choose **Load unpacked**, and select the revealed
   `BrowserExtension` folder.
4. Back in Bean, click **Install Mac Connection**. No Terminal command is
   required.
5. Reload the extension once. Bean now works in supported fields on ordinary
   websites; use Options only to block websites or check app/AI readiness.

Blocked hostnames and their subdomains are excluded from future content-script
registration. If a site is blocked while already open, Bean stops there
immediately; reload once to unload the dormant script.

## Mac spelling connection and optional AI

The small deterministic detector requires no Mac app connection. For full
offline macOS spelling and basic grammar, use **Install Mac Connection** in Bean
Settings. Bean reads only Chromium extension ID/path metadata, validates that
the loaded extension is Bean, and restricts the native host to the detected ID.
The command-line installer remains available only as a developer/recovery tool.
The native bridge is installed only for vendor-signed Chrome, Brave, and
Edge. Generic/ad-hoc-signed Chromium has no stable Team ID Bean can strongly
authenticate, so basic deterministic checks remain available there while the
Mac bridge fails closed.

Enable **Allow deeper AI checks from the browser** in Bean Settings → Browser.
That app setting is the single ongoing browser-AI control; extension Options
only shows readiness and blocked websites. Users upgrading from an older
explicit opt-out may see one confirmation that preserves that privacy choice.
AI checks can incur provider API charges after typing pauses, are rate-limited
by the extension, contribute to Bean's content-free Web Inline usage total, and
stop at Bean's daily automatic-call limit. Explicit **Proofread** and rewrite
buttons require a real user activation in Bean's closed shadow controls and a
single-use authorization tied to the unchanged source document and field. They
are recorded as manual actions. Offline spelling and UI ownership messages do
not call a provider or consume either usage limit, and remain responsive while
an AI request is running.

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

Framework-based rich editors, including Slack web's ProseMirror composer, are
evaluated by their editing capabilities and remain unverified on this candidate.
Highlighting or replacement can be declined when DOM text cannot be mapped to
one exact safe live range. That refusal is intentional.

## Safety behavior

- Local suggestions carry exact, verified occurrence offsets, so repeated typos
  can be reviewed individually. Provider suggestions map only when the original
  substring occurs exactly once.
- Apply re-verifies the live substring immediately before editing.
- Mac spelling suggestions include alternatives where available. Accepting any
  alternative uses the same exact range and Undo. Bulk local Proofread applies
  only deterministic or high-confidence fixes; uncertain guesses need review.
- Value-field replacement preserves everything outside the target range exactly.
- Whole-paragraph replacement rechecks the paragraph and refuses rich blocks
  containing markup that cannot be preserved safely.
- Provider wrappers, wrapping quotes, and zero-width artifacts are sanitized.
- Explicit writing actions apply checked output directly to an unchanged source and
  offer **Undo** when safely restorable. Output failing bounded content or shape
  safeguards is refused; these checks do not guarantee meaning preservation. The card states
  its scope: selected text, draft, or current paragraph. Rich multi-block editors
  retain their structure by proofreading the current safely editable paragraph
  or selection; the native Mac shortcut remains available for whole-field work.
- Typing invalidates outstanding requests and stale overlays.

## Tests

```bash
node test/run-tests.js
open test/fixtures/editor.html
```

The automated tests cover migrations, exact Mac spelling ranges, alternatives,
offline/AI independence, stale results, live ownership leases, direct writing
actions and Undo, IME composition, range/sanitization helpers, universal
coverage/blocklist behavior, and permission rules. The fixture covers layout and
interaction without private text. Serve it locally and use `?beanqa=1` for a
local-only API mock, `&beanactions=1` for simulated explicit AI actions, or
`&beanlocal=0` for disconnected spelling coverage. Omit `beanqa` to test the real
installed extension and Mac host.

## Files

- `manifest.json`: MV3 declaration and website permissions.
- `background.js`: all-site registration, blocklist exclusions, and native messaging.
- `src/localDetector.js`: offline conservative detector.
- `src/issueMapping.js`: exact range mapping and safe replacement helpers.
- `src/overlay.js`: isolated visual highlights and correction cards.
- `src/contentScript.js`: field detection, orchestration, and stale guards.
- `options.html` / `options.js`: blocklist and app/AI readiness.

See the project [privacy policy](../PRIVACY.md) before changing data flows or
permissions.
