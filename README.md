# Bean

Bean is an open-source macOS writing assistant that proofreads and rewrites text
in the app you are already using. It lives in the menu bar, uses your own OpenAI
or Anthropic API key, and does not operate a Bean-hosted text service.

> **Public beta.** Replacement and UI behavior depend on what each macOS app
> exposes through Accessibility. Review important text before sending it.

## What works today

- Proofread selected text or, when enabled, the focused editable field.
- Rewrite for clarity, concision, professional tone, or casual tone.
- Draft replies and compose messages through a preview-first workflow.
- Use global shortcuts or the optional Bean Bubble near supported fields.
- Keep style profiles, context cards, and a personal dictionary locally.
- Run conservative local inline checks without using provider tokens.
- Add experimental web inline checks through the unpacked Chrome extension.

Automatic provider-backed suggestions, native inline highlights, the Bean
Bubble, and browser support are beta features and are off by default. See the
[support matrix](SUPPORTED_APPS.md) before reporting an app-specific problem.

## Requirements

- macOS 13 or newer
- Accessibility permission
- An OpenAI or Anthropic API key for provider-backed actions
- Xcode or Apple Command Line Tools when building from source

Bean itself is free. Your selected AI provider may charge for API usage. OpenAI
`gpt-4.1-nano` and Anthropic `claude-haiku-4-5` are the current defaults; model
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
builds. After your first launch attempt, use **System Settings → Privacy &
Security → Open Anyway** only if you downloaded the artifact from this project
and its SHA-256 checksum matches the release.

Developer ID-signed and notarized artifacts, if introduced later, will omit the
`-unnotarized` suffix.

## First run

1. Choose OpenAI or Anthropic and add your API key. Bean stores it in Keychain.
2. Grant Bean Accessibility permission when macOS asks.
3. In another app, select text and press **⌘⇧G** to proofread it.
4. Press **⌃⌥B** to open the full writing-action menu.
5. Use Setup & Status → **Open TextEdit verification** to confirm the complete
   cross-app path.
6. Keep automatic AI checks off for manual-only API usage.

If no text is selected, Bean can optionally operate on the focused editable
field. Search fields, secure fields, code editors, and unusually large fields
are restricted or excluded.

If a field behaves unexpectedly, focus it and choose **Bean → Check Current
Field**. The resulting capability report uses metadata only and is included in
the content-free support summary.

## Cost controls

Bean ships with paid background paths disabled:

- Passive Suggestions: off
- Provider-backed inline checking: off
- Web Inline Support: off
- Native inline checking: local-only when enabled

Settings → AI Provider shows whether any automatic provider checks are active
and provides **Disable automatic AI checks**. Explicit shortcuts and Bean Bubble
actions still call the configured provider when you choose them.

## Browser extension

`BrowserExtension/` is an experimental Manifest V3 extension for Chromium-based
browsers. Its local detector has no token cost; deeper provider checks use the
local native-messaging bridge and remain separately opt-in. It is not yet a
Chrome Web Store release. See [BrowserExtension/README.md](BrowserExtension/README.md).

## Privacy and security

- API keys are stored in macOS Keychain.
- Text is sent directly from your Mac to the provider you configure.
- Bean has no analytics, advertising, account system, or hosted text backend.
- Diagnostics exclude text, prompts, API keys, and clipboard contents.
- Model output is sanitized and checked before automatic replacement.

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

See [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request and
[TESTING.md](TESTING.md) for the manual release matrix.

## Project status

Bean is maintained as a public beta. Compatibility reports and focused fixes are
welcome; broad new providers or writing modes should start with a proposal.

## License

Bean is available under the [MIT License](LICENSE.md).
