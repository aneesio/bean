# Bean Native Messaging Bridge (implemented)

This is the path for the browser extension to get high-quality suggestions:
instead of the extension holding an API key, it asks the **Bean Mac app** (which
already has the provider, key in Keychain, dictionary, and the safety validator)
to generate issue candidates.

Status: **implemented.** The host name is `com.bean.nativehost` and the host *is*
the Bean app binary run in a stdin/stdout native-messaging mode. The extension
falls back to its offline local detector when the bridge is unavailable.

## Architecture

```
Browser extension (background.js)
        │  chrome.runtime.sendNativeMessage("com.bean.nativehost", req)
        ▼
Bean.app/Contents/MacOS/Bean  (launched by Chrome with the extension origin →
        │                       routes to NativeMessagingHost.run(), no GUI)
        │  4-byte LE length-prefixed JSON over stdin/stdout
        ▼
IssueDetector + provider (shared Keychain/UserDefaults/dictionary by identity)
        →  JSON issue candidates
```

### Message contract

Request (extension → host):
```json
{ "type": "detectIssues", "fieldType": "textarea", "pageHost": "mail.google.com",
  "text": "i has a apple" }
```

Response (host → extension):
```json
{ "issues": [
  { "original": "i has", "suggestion": "I have", "type": "grammar",
    "explanation": "Subject-verb agreement.", "confidence": 0.9 }
] }
```

Rules: text is inert; the host never logs/stores it; candidates are mapped by
exact substring in the extension; ambiguous/missing are dropped.

## Files (to add when implementing)

- `com.bean.host.json` — Chrome Native Messaging manifest template (host name,
  path to the host binary, and `allowed_origins` with the extension ID).
- A host binary or a `--native-messaging` mode of the Bean executable that reads
  length-prefixed messages on stdin and writes responses on stdout.

## Install / uninstall (placeholders)

- `../scripts/install_native_messaging_host.sh` — writes `com.bean.host.json`
  into Chrome's `NativeMessagingHosts` directory pointing at the host binary.
- `../scripts/uninstall_native_messaging_host.sh` — removes it.

Both scripts currently **print guidance and explain that the host isn't built
yet** rather than installing a manifest that points at a missing binary.

## Privacy

Only the focused field's text is sent, only when the user enabled web inline
support, and only to the local Bean app over native messaging (never to a
server by this bridge). No text history, no logging.
