# Bean Privacy Policy

Effective: August 22, 2026

Bean is an open-source macOS application. It has no Bean-operated account,
analytics, advertising, telemetry, or text-processing server. This policy
describes the behavior of the official source and release artifacts from this
repository. Modified builds may behave differently.

Public beta artifacts whose names end in `-unnotarized` are prerelease builds
that are ad-hoc signed, not Apple-notarized. This distribution status affects
macOS launch warnings; it does not change the data handling described here.

## Data Bean handles

When you request a provider-backed writing action, Bean handles:

- the selected text or focused editable field text;
- the action you selected;
- fixed, coarse context such as app category, input mode, and a recognized field
  type; Bean does not send the app's display name, bundle identifier, process ID,
  or raw Accessibility metadata;
- the active style instructions and examples, every Writing Context item you
  enabled for writing actions, and matching personal dictionary terms.

For provider requests, Bean includes only bounded excerpts of that active or
enabled personalization and matching dictionary material. Those prompt limits
do not truncate or rewrite the complete data stored on your Mac.

Browser provider requests use Bean-authored generic `Browser` and `web editor`
labels. Bean does not pass a website hostname or extension-supplied field label
to the provider or include either value in Mac-side accounting/support data. A
hostname is used only inside the extension for sender/page validation and local
per-site controls/blocklist enforcement.

Manual shortcuts and Bean Bubble actions send data only after you invoke an
action. Deeper AI suggestions and browser AI can send focused-field text after a
typing pause when you explicitly enable them. Those automatic provider paths are
off by default; ordinary Live suggestions run locally.

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
  field labels, or field values. You can inspect it and erase it together with
  visible usage in Settings → Privacy & Help → Advanced diagnostics.
- Bean also keeps up to 120 days of daily usage aggregates in UserDefaults so
  the Usage & Cost dashboard remains accurate after the 50-record detail history
  rolls over. Each aggregate contains only date, provider/model, manual or
  automatic source, token totals, call count, and whether counts were estimated.
  It contains no text or field metadata and can be erased from AI & Usage.
- Bean keeps a minimal crash-recovery and cost-safety file at
  `~/Library/Application Support/Bean/NativeMessaging/automatic-call-reservations.json`.
  It contains only opaque request IDs, timestamps, automatic-call counts, and
  content-free provider metadata (source, action, input length, provider, and
  model). It never contains app names, bundle identifiers, website hostnames,
  field roles/types, text, prompts, or responses. Expired entries are reconciled
  when Bean launches and whenever the browser asks for connection status.
- Style profiles, Writing Context items, dictionary terms, and app rules are
  stored in `~/Library/Application Support/Bean/userContent.json`. If that file
  is unreadable, Bean may create a narrowly named recovery copy. A transactional
  import may create a narrowly named automatic pre-import backup inside Bean's
  `Backups` directory. Bean's Full Reset targets those generated artifacts but
  does not recursively erase unrelated files.
- Bean temporarily uses the system clipboard for text acquisition and
  replacement. It restores the prior clipboard when the workflow succeeds. If
  replacement cannot be completed safely, Bean may intentionally leave the
  corrected result on the clipboard so you can paste it manually.

Bean does not intentionally persist text being proofread, rewritten, or drafted,
provider prompts, or provider responses. This is distinct from personalization
you explicitly save—styles, Writing Context, examples, and dictionary terms are
stored locally until you remove or reset them.

## Diagnostics

Bean writes a small number of always-on, content-free operational events to
Apple's unified log. Those events use fixed operation names, coarse app
categories, and outcome or reason codes rather than app display names or bundle
identifiers. Optional diagnostic logging is off by default; when enabled, it
adds structured provider/model, length, feature-state, and timing metrics. Logs
do not include processed text, prompts, responses, API keys, or clipboard
contents.

The local operation history described above is separate from diagnostic logging
and exists so users can understand recent failures and create useful support
reports. Bean never uploads either source automatically.

**Copy Diagnostics Summary** copies only the diagnostics block. **Preview
Support Report** constructs an in-memory template containing that block so you
can review every line first. Previewing does not save, copy, upload, attach, or
open a report. Copying and opening the public GitHub bug form are separate user
actions, and opening GitHub does not attach the preview.

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

If you separately enable the native bridge, focused editable-field text is sent
through Chrome Native Messaging to the local Bean app. The extension does not
include the site hostname or page-supplied field label in that native request;
it uses the hostname only inside the extension for sender/page validation and
blocked-site controls. The Bean app then sends the provider request described
above using fixed, Bean-authored `Browser` and `web editor` labels. Recent
operation history may contain only the generic Browser category, action,
lengths, provider/model, result codes, and token counts. All browser AI—including
Fix Paragraph—counts toward the daily browser/automatic limit because a webpage
cannot prove a trusted native user gesture.

## Deleting your data

You can remove an individual API key by clearing it in Bean Settings. You can
reset personalization from Settings → Privacy & Help → Your data.

Clearing usage and operation history erases the two visible accounting ledgers
and prevents an in-flight call from recreating them. The private current-day
automatic-call count remains until the local calendar day changes, so deleting
history cannot silently reset the user's spending limit.

**Full Reset Bean** provides the Mac-side removal path without Terminal. After
explicit confirmation it attempts, in order, to remove Bean's OpenAI and
Anthropic Keychain entries; exact user-content/recovery/automatic-backup
artifacts; launch-at-login registration; exact
`NativeMessagingHosts/com.bean.nativehost.json` files and Bean's manual
extension approvals; visible usage/operation history and private automatic-call
state; and Bean's `com.bean.app` preferences/onboarding state. Unrelated
Keychain accounts, preference domains, files, browser profiles, and neighboring
native-host manifests are outside its scope. Bean verifies each step, names any
failure and any area already removed, and quits only after every removable area
succeeds. Completed cleanup is not rolled back; if personalization cleanup
fails, some Bean-owned artifacts may already have been removed. Reopening Bean
after a successful reset starts the first-run flow with safe defaults.

Two operating-system/browser boundaries require manual action:

- macOS does not allow Bean to revoke its own Accessibility authorization. To
  remove it, open System Settings → Privacy & Security → Accessibility and
  remove or turn off Bean.
- The Mac app cannot uninstall the Chromium extension or erase its
  `chrome.storage.local` settings and blocked-sites list. Clear or remove the
  extension in the browser if desired. Full Reset removes only the Mac-side
  native-host manifests and manual extension approvals.

Apple's unified logs remain subject to macOS retention and controls; an app
cannot selectively erase prior unified-log entries.

## Contributions and support

GitHub issues, discussions, pull requests, and other public contributions are
stored and displayed by GitHub under GitHub's policies. Never include API keys,
private writing, clipboard contents, or sensitive diagnostics in an issue.

Privacy questions can be sent to `hello@anees.io`.

Material behavior changes must update this policy in the same release.
