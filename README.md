# Bean

Bean is an open-source macOS writing assistant that proofreads and rewrites text
in the app you are already using. It lives in the menu bar, can optionally use
your own OpenAI or Anthropic API key, and does not operate a Bean-hosted text
service.

> **Public beta.** Replacement and UI behavior depend on what each macOS app
> exposes through Accessibility. Review important text before sending it.
>
> Current release contract: Bean **1.7.0 (build 16)** with Bean for the Web
> **0.8.2**.

## What works today

- Checks spelling, basic grammar, and spacing while you type in editable macOS fields.
  Local live assistance and the Bean dot are on by default. The dot is neutral
  when there are no current suggestions and amber when suggestions are found.
  Hover for status or click for details; it hides when no clear placement exists.
- Draws underlines when an app supplies exact text positions, with a compact
  issue button and correction cards when that geometry is unavailable.
- Accepts individual corrections without moving you away from your app.
- Proofreads or rewrites selected text, or the active field when nothing is
  selected, and replaces it directly. Bean offers Undo when it can safely
  restore the captured text.
- Uses global shortcuts and field-side actions for Quick Fix, AI Proofread,
  clarity, concision, and tone adjustments.
- Keeps personal dictionary terms and style preferences locally.
- Offers current-paragraph actions, local-only Fix All, inline Learn word,
  English dialect preferences, and app/site pause controls. Provider actions
  can be cancelled before editing starts.
- Offers an optional browser extension for DOM-based web editing support.
  Its field control includes review, Proofread, and Rewrite. When connected to
  Bean, offline macOS spelling supplements its built-in rules; only one Bean
  control appears for a field owned by the extension.
- Provides an optional Bean Writer for standalone drafts; it is not required
  for assistance in other apps and no longer opens on every launch.

Paid background AI checks stay off until explicitly enabled. Local help has no
API cost. Password fields remain excluded, and custom editors that hide both
text and editing controls cannot be handled by generic Accessibility access.
The [support matrix](SUPPORTED_APPS.md) distinguishes tested behavior from
app-specific limits.

## Requirements

- macOS 13 or newer
- Accessibility permission
- An OpenAI or Anthropic API key only for provider-backed actions (optional)
- Xcode or Apple Command Line Tools when building from source

Bean itself is free. Your selected AI provider may charge for API usage. OpenAI
`gpt-5-nano` and Anthropic `claude-haiku-4-5` are the current defaults; model
availability and provider pricing can change independently of Bean.

## Install

### Build from source

```bash
git clone https://github.com/aneesio/bean.git
cd bean
./scripts/build_app.sh release
open build/Bean.app
```

For stable Accessibility and launch-at-login permissions, quit Bean and install
the verified build in `/Applications` before granting permission. The installer
prints a verified rollback copy when replacing an existing app:

```bash
./scripts/install_local_build.sh
open /Applications/Bean.app
```

### GitHub beta DMG

Early GitHub beta builds are ad-hoc signed and explicitly named
`Bean-<version>-build<build>-unnotarized`. macOS will not treat them as identified-developer
builds.

1. Download the `.dmg` from the official Bean GitHub prerelease.
2. Open the DMG and drag **Bean** onto the **Applications** shortcut beside it.
3. Eject the DMG, then open Bean from Applications.
4. After the first blocked launch, open **System Settings → Privacy & Security**
   and choose **Open Anyway** only if the DMG came from this project's official
   GitHub release page.

Checksum verification is an optional advanced safety check, not part of the
normal Finder-only install. Download the release's `.sha256` file beside the DMG,
then, for example, run the following for version 1.7.0, build 16 and compare the printed
value with the `.dmg` line in that file:

```bash
cd ~/Downloads
shasum -a 256 Bean-1.7.0-build16-unnotarized.dmg
```

Developer ID-signed and notarized artifacts, if introduced later, will omit the
`-unnotarized` suffix.

### Keep a rollback copy

Before replacing an existing beta, quit Bean from its menu-bar menu. In Finder,
open **Applications**, rename the existing app to **Bean Previous.app**, then
drag the new **Bean.app** into Applications. Your API key, preferences, and
Writing data live outside the app bundle and are not removed by this rename.

To roll back, quit the new Bean, move it aside, rename **Bean Previous.app** back
to **Bean.app**, and open it. An older build may ignore settings introduced by a
newer build, and macOS may ask you to confirm Accessibility again. If browser AI
stops connecting after a rollback, load the extension bundled with that app and
use **Settings → Browser → Install Mac Connection** or **Repair Mac Connection**,
whichever Bean shows. Do not use **Full Reset Bean…** for a normal rollback
because it intentionally removes Bean data.

## First run

1. Keep Bean in `/Applications` and allow its Accessibility access during setup.
   macOS requires this permission to check and change writing in other apps.
2. Continue typing in your normal app. Local live suggestions are enabled by
   default. Click an underline or the issue button beside the field, then choose
   **Accept** or **Dismiss**. No comparison window is needed for a correction.
3. Press **⌘⇧G** to fix selected text, or the active editable field when nothing
   is selected. This shortcut runs free local Quick Fix by default. Choose
   **AI Proofread** in Settings → General for provider-backed proofreading.
4. Press **⌃⌥B**, or use the Bean dot beside your field, to choose a rewrite.
   Proofread and rewrite apply directly to the unchanged source, with Bean Undo
   when a safe restoration path is available.
   Reply and compose actions create new content and retain their draft review.
5. Connect an optional AI provider in Settings → AI & Usage. The API key stays
   in Keychain. Background AI suggestions require a separate opt-in.

Bean checks the capabilities of each focused editable control, including those
in browsers, Electron apps, code editors, and search fields. It excludes secure
and read-only controls and bounds unusually large input. Apps that do not expose
text or usable editing controls still need their own integration. A changed
source is never overwritten by a delayed result; unsafe provider output is
rejected without an original-versus-replacement window.

The optional Writer is available from **Open Bean Writer** in the menu bar. Its
local draft limit is 50,000 characters and AI actions are bounded to 8,000.
Manual launches after setup stay in the menu bar; reopening Bean shows Writing
settings rather than taking you into a different editor.

If something behaves unexpectedly, Settings → Privacy & Help shows focused
repair cards. **Copy Diagnostics Summary** is a separate, content-free clipboard
action. **Preview Support Report** shows the complete report before you decide
whether to copy it or open GitHub; Bean never submits it automatically.

## Cost controls

Bean ships with paid background paths disabled:

- Deeper AI suggestions: off
- Provider-backed inline checking: off
- Automatic browser AI checks: off (the offline browser checker uses no tokens)
- Native inline checking: local-only when enabled

Settings → AI & Usage shows whether any automatic provider checks are active
and provides **Disable automatic AI checks**. It also shows today/30-day usage,
provider-reported or conservatively estimated token counts, an estimated USD
cost, a daily automatic-call cap, and a configurable 30-day warning. Explicit
AI actions in the Bean Mac app and the browser field control's **Proofread** and
**Rewrite** are recorded as manual calls and remain available regardless of the
automatic cap. Automatic browser issue checks and the paragraph **Fix Paragraph**
path use that cap and require the browser-AI opt-in. Local Quick Check never
calls a provider.

The built-in estimate uses public standard list prices captured August 21,
2026: [OpenAI gpt-5-nano](https://openai.com/index/introducing-gpt-5-for-developers/)
and [Anthropic Claude Haiku 4.5](https://platform.claude.com/docs/en/about-claude/pricing).
It is not a bill: caching, tiers, taxes, custom models, and later price changes
can differ.

## Browser extension

`BrowserExtension/` is an experimental Manifest V3 extension for Chromium-based
browsers. Its local detector has no token cost; deeper provider checks use the
local native-messaging bridge and remain separately opt-in. It is not yet a
Chrome Web Store release. Bean Settings → Browser guides the unpacked-extension
steps, detects its ID, and installs or repairs the local bridge without Terminal.
Local checks work across ordinary websites by default; users can disable Bean
for the current field or block a website from the correction UI. See
[BrowserExtension/README.md](BrowserExtension/README.md). Slack web and other
framework-based rich editors remain unverified on this candidate. Bean evaluates
their editing capabilities and declines changes when it cannot verify a safe
text range.

## Updates

Settings → General includes a manual **Check for Updates** button. It contacts the
public GitHub Releases API only after you click it, shows the installed/latest
versions and prerelease status, and can open a verified `aneesio/bean` release
page. Bean does not poll in the background or download or install updates.

## Privacy and security

- API keys are stored in macOS Keychain.
- Text is sent directly from your Mac to the provider you configure.
- Bean has no analytics, advertising, account system, or hosted text backend.
- Diagnostics exclude text, prompts, API keys, and clipboard contents.
- Browser AI uses generic source labels; website hostnames and extension-supplied
  field labels are not sent to the provider or Mac-side support/accounting data.
- Model output is sanitized and checked before automatic replacement.
- Provider requests include only bounded excerpts of relevant personalization
  and dictionary material; Bean does not truncate the full data saved on your Mac.
- **Full Reset Bean** removes Mac-side Bean data, provider keys, accounting,
  login registration, and browser native-host connections, then quits. macOS
  Accessibility authorization and the Chrome extension's own settings/blocklist
  must be removed separately by the user.

Read the complete [privacy policy](PRIVACY.md) and [security policy](SECURITY.md).
Do not use Bean for secrets or regulated data unless sending that content to your
selected provider is acceptable under your own policies.

## Development

```bash
swift test
node BrowserExtension/test/run-tests.js
./scripts/build_app.sh debug
```

The package has no third-party Swift dependencies. The app bundle is assembled
by `scripts/build_app.sh`; release artifacts are produced by
`scripts/package_release.sh`.

Repository layout:

```text
Sources/Bean/          macOS app, text engine, providers, and UI
Tests/BeanTests/       XCTest regression tests
BrowserExtension/     optional Chromium extension
NativeMessaging/      native bridge documentation and manifest template
Resources/            Info.plist and artwork
scripts/              build, test, audit, packaging, and host utilities
```

See [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request,
[SUPPORT.md](SUPPORT.md) before filing an issue, and [TESTING.md](TESTING.md) for
the manual release matrix. The reusable release plan is
[QA_TEST_PLAN.md](QA_TEST_PLAN.md); release-specific evidence lives under
[`docs/qa/`](docs/qa/).

## Project status

Bean is maintained as a public beta. Compatibility reports and focused fixes are
welcome; broad new providers or writing modes should start with a proposal.

## License

Bean is available under the [MIT License](LICENSE.md).
