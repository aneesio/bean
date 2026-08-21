# Supported Apps and Surfaces

Policy matrix version: **1.3** (August 21, 2026). These expectations are backed
by `FieldCapabilityPolicyTests`; the release checklist still requires live-app
smoke testing because app and macOS Accessibility implementations can change.

Bean uses several text-access paths because macOS applications expose editors
differently. “Supported” means Bean refuses uncertain operations safely; it does
not mean every editor implementation can be replaced or highlighted.

## Five reference experiences

| Reference surface | Selected-text action | Focused-field replacement | Bean Bubble | Inline mode | Expected limitation |
| --- | --- | --- | --- | --- | --- |
| TextEdit | Supported | Direct verified AX write | Supported with valid bounds | Native, when range geometry verifies | Canonical end-to-end setup check. |
| Apple Notes | Supported | Direct write or verified paste | Supported/best effort | Native or passive fallback | Rich-note geometry can vary. |
| Apple Mail | Supported | Direct write or verified paste | Supported/best effort | Native or passive fallback | Test the message composer, not message display. |
| Slack desktop | Supported | Best-effort Electron paste with stale guards | Bounds or recent click+typing evidence | No native highlight; passive/manual path | Slack may expose no focused AX editor. |
| Chromium web editor | Supported/best effort | Verified paste when AX exposes the editor | Best effort | Browser extension on an approved exact hostname | Gmail and Slack web are the extension references. |

## Deterministic exclusions

| Surface trait | Selected text | Focused field | Bubble | Inline |
| --- | --- | --- | --- | --- |
| Password or secure | Excluded | Excluded | Excluded | Excluded |
| Disabled | Excluded | Excluded | Excluded | Excluded |
| Read-only text | May be selected manually | Excluded | Excluded | Excluded |
| Search/address | Manual selection only | Excluded | Off/excluded | Excluded |
| Code editor | Selected prose only | Excluded | Off unless explicitly enabled | Excluded |
| Non-text button/control | Excluded | Excluded | Excluded | Excluded |

Unknown apps use the same trait policy; Bean does not grant support merely from
an app name. Bubble bounds and native inline range geometry are rechecked live.

## Browser extension

The unpacked Chromium extension works best in plain text inputs, textareas, and
simple contenteditable editors such as basic Gmail or Slack web composition.
Complex rich editors vary. Google Docs canvas editing, Slack desktop, Safari,
password/search/email-address fields, and code editors are excluded from the
Chromium extension path.

When an unsupported or ambiguous target is detected, the correct behavior is to
show no highlight or decline replacement—not to guess.

Compatibility reports should include app/version, macOS version, field type,
and synthetic reproduction text. See [SUPPORT.md](SUPPORT.md).
