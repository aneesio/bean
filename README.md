# Bean

Bean is an open-source macOS writing assistant that proofreads and rewrites text
in the app you are already using. It lives in the menu bar, can optionally use
your own OpenAI or Anthropic API key, and does not operate a Bean-hosted text
service.

> **Public beta.** Replacement and UI behavior depend on what each macOS app
> exposes through Accessibility. Review important text before sending it.
>
> Current release contract: Bean **1.6.0 (build 11)** with Bean for the Web
> **0.7.2**.

## What works today

- Proofread selected text or, when enabled, the focused editable field.
- Rewrite for clarity, concision, professional tone, or casual tone.
- Draft replies and compose messages through a preview-first workflow.
- Use global shortcuts or the optional Bean Bubble near supported fields.
- Keep style profiles, Writing Context, and a personal dictionary locally.
- Run conservative local inline checks without using provider tokens.
- Use Local Quick Check for obvious typos and spacing without an API request.
- Add experimental web inline checks through the unpacked Chrome extension.

Automatic provider-backed suggestions, native inline highlights, and the Bean
Bubble are beta features and are off by default. The browser extension's free
local checker is on across ordinary websites once installed; browser AI remains
off until enabled separately. See the
[support matrix](SUPPORTED_APPS.md) before reporting an app-specific problem.

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

For stable Accessibility and launch-at-login permissions, move the finished app
to `/Applications` before granting permission:

```bash
ditto build/Bean.app /Applications/Bean.app
open /Applications/Bean.app
```

### GitHub beta DMG

Early GitHub beta builds are ad-hoc signed and explicitly named
`Bean-<version>-unnotarized`. macOS will not treat them as identified-developer
builds.

1. Download the `.dmg` from the official Bean GitHub prerelease.
2. Open the DMG and drag **Bean** onto the **Applications** shortcut beside it.
3. Eject the DMG, then open Bean from Applications.
4. After the first blocked launch, open **System Settings → Privacy & Security**
   and choose **Open Anyway** only if the DMG came from this project's official
   GitHub release page.

Checksum verification is an optional advanced safety check, not part of the
normal Finder-only install. Download the release's `.sha256` file beside the DMG,
then, for example, run the following for version 1.6.0 and compare the printed
value with the `.dmg` line in that file:

```bash
cd ~/Downloads
shasum -a 256 Bean-1.6.0-unnotarized.dmg
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

1. Keep Bean in `/Applications`, then grant Accessibility permission when macOS
   asks.
2. Optionally connect OpenAI or Anthropic. Bean stores your key in Keychain; the
   free local checker works without one.
3. Try Quick Fix directly on the final onboarding screen.
4. In another app, select text and press **⌘⇧G**. It runs Quick Fix by default,
   free and on-device. In Settings → General, you can instead make it run AI
   Proofread with your connected provider.
5. Press **⌃⌥B** to open the writing-action menu. Provider-backed actions are
   labelled and require optional AI setup.
6. Keep automatic AI checks off for manual-only API usage.

If no text is selected, Bean can optionally operate on the focused editable
field. Search fields, secure fields, code editors, and unusually large fields
are restricted or excluded.

If something behaves unexpectedly, Settings → Privacy & Help shows focused
repair cards. **Copy Diagnostics Summary** is a separate, content-free clipboard
action. **Preview Support Report** shows the complete report before you decide
whether to copy it or open GitHub; Bean never submits it automatically.

## Cost controls

Bean ships with paid background paths disabled:

- Deeper AI suggestions: off
- Provider-backed inline checking: off
- Browser AI checks: off (the offline browser checker uses no tokens)
- Native inline checking: local-only when enabled

Settings → AI & Usage shows whether any automatic provider checks are active
and provides **Disable automatic AI checks**. It also shows today/30-day usage,
provider-reported or conservatively estimated token counts, an estimated USD
cost, a daily automatic-call cap, and a configurable 30-day warning. Explicit
AI actions in the Bean Mac app remain available regardless of the automatic
cap. All browser AI—including Fix Paragraph—uses the browser/automatic cap
because a web page cannot prove a trusted native click. Local Quick Check never
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
complex rich editors are not supported in 1.6; Bean stays hidden when it cannot
verify a safe text range.

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
