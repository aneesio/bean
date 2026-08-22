# Bean Privacy Policy

Effective: August 21, 2026

Bean is an open-source macOS application. It has no Bean-operated account,
analytics, advertising, telemetry, or text-processing server. This policy
describes the behavior of the official source and release artifacts from this
repository. Modified builds may behave differently.

## Data Bean handles

When you request a provider-backed writing action, Bean handles:

- the selected text or focused editable field text;
- the action you selected;
- limited context such as source app name, field role, and input mode;
- relevant enabled style instructions, context cards, examples, and personal
  dictionary terms.

Manual shortcuts and Bean Bubble actions send data only after you invoke an
action. Passive Suggestions, provider-backed inline highlights, and Web Inline
Support can send focused-field text after a typing pause when you explicitly
enable those features. Those automatic provider paths are off by default.

## Where provider requests go

Bean sends provider-backed requests directly from your Mac to the provider you
select:

- OpenAI: `https://api.openai.com/`
- Anthropic: `https://api.anthropic.com/`

Your API key and request data are then governed by your agreement and privacy
settings with that provider. Bean's maintainers do not receive the requests,
responses, API keys, or provider billing information.

Do not process confidential, regulated, or third-party data unless you are
authorized to send it to your selected provider.

## Information stored on your Mac

- Provider API keys are stored as generic passwords in macOS Keychain under the
  service `com.bean.apikeys`.
- Preferences and feature flags are stored in macOS UserDefaults for the bundle
  identifier `com.bean.app`.
- Bean keeps a bounded local history of up to 50 content-free operation records
  in UserDefaults. A record may contain timestamp, app name/bundle/category,
  action, input mode and length, provider/model, timing, safety/replacement
  result codes, and token counts or estimates. It never contains source text,
  transformed text, prompts, responses, clipboard contents, window titles,
  field labels, or field values. You can inspect and erase it in Settings →
  Privacy & Support → Advanced diagnostics.
- Bean also keeps up to 120 days of daily usage aggregates in UserDefaults so
  the Usage & Cost dashboard remains accurate after the 50-record detail history
  rolls over. Each aggregate contains only date, provider/model, manual or
  automatic source, token totals, call count, and whether counts were estimated.
  It contains no text or field metadata and can be erased from AI & Usage.
- Style profiles, context cards, dictionary terms, and app rules are stored in
  `~/Library/Application Support/Bean/userContent.json`.
- Bean temporarily uses the system clipboard for text acquisition and
  replacement. It restores the prior clipboard when the workflow succeeds. If
  replacement cannot be completed safely, Bean may intentionally leave the
  corrected result on the clipboard so you can paste it manually.

Bean does not intentionally persist selected text, focused-field text, prompts,
or provider responses.

## Diagnostics

Bean writes a small number of content-free operational events to Apple's unified
log. Optional diagnostic logging is off by default. When enabled, logs may add
app/provider names, lengths, feature states, result codes, and timing-related
state. They do not include text, prompts, responses, API keys, or clipboard
contents.

The local operation history described above is separate from diagnostic logging
and exists so users can understand recent failures and create useful support
reports. Bean never uploads either source automatically.

Logs remain subject to macOS log retention and controls on your device. Bean
does not upload them.

## Manual update check

Bean makes no background update requests. When you click **Check for Updates**,
Bean requests public release metadata from GitHub's API using an ephemeral
network session. The request identifies the installed Bean version in its user
agent; it contains no writing, prompt, API key, settings, operation history, or
stable Bean identifier. The result is not persisted. Bean accepts release-page
links only under `https://github.com/aneesio/bean/releases/` and never downloads
or installs an update.

## Browser extension

The extension's default detector runs locally in the web page and does not store
or transmit editable-field text. After installation it is available across
ordinary HTTP and HTTPS websites, except hostnames the user adds to the blocked
list. It stores only extension settings and blocked hostnames in
`chrome.storage.local`. **Disable on this field** lasts only for that page
session and is not persisted. Password, search, email-address, URL, telephone,
number, code, disabled, read-only, hidden, and tiny fields are excluded.

If you separately enable the native bridge, focused editable-field text and the
site hostname are sent through Chrome Native Messaging to the local Bean app.
The Bean app then sends the provider request described above. The bridge does
not create a separate text history. It contributes only content-free token and
call totals to the same local usage ledger.

## Deleting your data

You can remove an individual API key by clearing it in Bean Settings. You can
reset style and context data from Settings → Privacy → Data.

For a complete manual removal after quitting Bean:

1. Delete Bean's OpenAI and Anthropic entries from Keychain Access.
2. Delete `~/Library/Application Support/Bean/`.
3. Run `defaults delete com.bean.app` in Terminal.
4. Remove the Bean native-messaging manifest using
   `scripts/uninstall_native_messaging_host.sh`, if installed.
5. Remove Bean from System Settings → Privacy & Security → Accessibility.

## Contributions and support

GitHub issues, discussions, pull requests, and other public contributions are
stored and displayed by GitHub under GitHub's policies. Never include API keys,
private writing, clipboard contents, or sensitive diagnostics in an issue.

Privacy questions can be sent to `hello@anees.io`.

Material behavior changes must update this policy in the same release.
