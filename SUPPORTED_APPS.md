# Supported Apps and Surfaces

Bean uses several text-access paths because macOS applications expose editors
differently. “Supported” means Bean refuses uncertain operations safely; it does
not mean every editor implementation can be replaced or highlighted.

| Surface | Manual action | Bean Bubble | Native inline highlights | Notes |
| --- | --- | --- | --- | --- |
| Standard AppKit text fields and editors | Best support | Best support | Experimental | TextEdit is the reference surface. |
| Apple Notes and Mail | Generally supported | Best effort | Varies | Rich text and composed layouts may limit range geometry. |
| Slack desktop | Replacement supported | Supported | Not supported | Slack's Electron editor does not expose reliable native highlight geometry. |
| Other Electron apps | Best effort | Best effort | Usually unavailable | Accessibility exposure varies by app and release. |
| Browser page editors from the Mac app | Manual selection/focused-field best effort | Best effort | Not supported natively | Use the experimental extension for web inline highlights. |
| Code editors | Selected prose only | Off by default | Excluded | Bean attempts to preserve code, paths, identifiers, and markup. |
| Search/address fields | Conservative or excluded | Off by default | Excluded | Search-like fields avoid sentence-style rewriting. |
| Password, secure, disabled, or read-only fields | Excluded | Excluded | Excluded | Bean should not appear or operate here. |

## Browser extension

The unpacked Chromium extension works best in plain text inputs, textareas, and
simple contenteditable editors such as basic Gmail or Slack web composition.
Complex rich editors vary. Google Docs canvas editing, Slack desktop, Safari,
password/search/email fields, and code editors are excluded.

When an unsupported or ambiguous target is detected, the correct behavior is to
show no highlight or decline replacement—not to guess.

Compatibility reports should include app/version, macOS version, field type,
and synthetic reproduction text. See [SUPPORT.md](SUPPORT.md).
