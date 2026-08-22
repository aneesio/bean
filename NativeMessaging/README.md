# Bean Native Messaging Bridge

The Chromium extension can ask the local Bean app for provider-backed issue
candidates and whole-paragraph proofreading. The host is the Bean app binary
running in `--native-messaging` mode; it does not launch the GUI.

```text
supported, unblocked page → extension content script → extension service worker
              → Chrome Native Messaging → local Bean binary
              → the user's selected OpenAI or Anthropic provider
```

## Install (normal users)

Use **Bean Settings → Browser → Connect Bean to Browser**. Bean
discovers the loaded extension from Chromium's extension metadata and writes
the per-user host manifest itself. No Terminal command is required.

## Command-line fallback (development/recovery)

Build or install Bean first, load the extension unpacked, and then run:

```bash
./scripts/install_native_messaging_host.sh <extension-id> /Applications/Bean.app
```

The script writes `com.bean.nativehost.json` only for browsers already installed
for the current macOS user. Its `allowed_origins` contains exactly the supplied
extension ID and its `path` points to the absolute Bean executable.

Uninstall with:

```bash
./scripts/uninstall_native_messaging_host.sh
```

Normal users can use **Repair Browser Connection** after moving Bean.app or if
the unpacked extension ID changes.

## Protocol

Messages use Chrome's four-byte little-endian length prefix followed by JSON.
The host accepts only `ping`, `getStatus`, `detectIssues`, and
`proofreadParagraph`. Frames are capped at 1 MB, field text at 8,000 characters,
paragraphs at 2,000 characters, and returned issues at eight.

The host performs no command execution and exposes no generic file access. It
shares provider settings, Keychain keys, and dictionary data with the GUI app.
Request and response text is neither logged nor persisted.

## Security review checklist

- Keep the host name synchronized as `com.bean.nativehost` in the app,
  extension, installer, uninstaller, and template.
- Never broaden `allowed_origins` beyond the intended extension ID.
- Keep input/output caps and the known-message allowlist.
- Treat site hostname and text as untrusted prompt data.
- Preserve exact-range mapping and output validation before page replacement.
- Update [PRIVACY.md](../PRIVACY.md) for any new message or data flow.
