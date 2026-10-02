# Supported Apps and Surfaces

Policy revision: **unreleased system-wide pass, October 2, 2026**. Capability
routing is covered by `FieldCapabilityPolicyTests`; implementation checks are
covered by focused-field, native-editing, issue-mapping, and geometry tests.
These do not substitute for live compatibility checks in each application.

Bean evaluates the focused control rather than excluding entire application
categories. It resolves editable text descendants and ancestors, enables an
application's Accessibility tree where supported, and reads range text when
AXValue is unavailable. Editable WebKit surfaces are identified by editing
capabilities and use their text-marker APIs when ordinary text attributes are
missing. This routing does not require a list of supported app names.
Normal Paste/Delete events drive replacements, with
exact source and outcome checks; confirmed changes register Bean Undo when a
safe restoration path is available.

## Expected native paths

| Reference surface | Text acquisition / replacement | Live issues | Outstanding live check |
| --- | --- | --- | --- |
| TextEdit | Native text and selection; verified normal paste | Native underlines and issue tray | Cross-app pass after Accessibility restoration. |
| Apple Notes | AX value/range text and verified paste where exposed | Underlines when exact range bounds exist; floating cards otherwise | Rich-note editor and native undo. |
| Apple Mail | Generic editable WebKit/native composer path; excludes message display | Underlines where exact geometry exists; field-side cards otherwise | User confirmed the manual writing action works after the shared WebKit fix. Live corrections, rich formatting, attachments, and other composer variants remain unverified. |
| Electron apps | Application-provided Accessibility tree, editable ancestors, guarded paste | Native positions where available; floating cards otherwise | Per-app composer behavior, including Slack and VS Code. |
| Browser fields | Native editable control capabilities; guarded paste | Native positions or floating cards; optional DOM extension | Plain input, textarea, and contenteditable compatibility. |
| Search/address and code-app fields | Eligible when the specific control is editable | Local checking; field-button visibility can be customized | Technical-token preservation and control boundaries. |

An editor that exposes no readable text or usable editing control may need
an integration with its editor framework or application. Recent typing evidence can support the existing
Slack manual acquisition fallback; Bean does not silently scrape text from
unreadable controls or report those as clean.

## Control exclusions

- Secure/password and disabled controls are excluded.
- Explicitly read-only controls do not permit focused-field replacement.
- Non-text controls do not qualify merely because their app contains an editor.
- Delayed results never overwrite a changed source or a different focused field.
- Range geometry may be unavailable without preventing floating suggestions.
- In a document-style WebKit editor without a usable numeric selection API,
  individual cards do not replace the entire rich document. Select the desired
  passage and use a writing action instead; exact marker identity protects that
  selected destination. Bean Undo is offered only when it has a safe undo path;
  normal paste edits also participate in the source app's native Undo.
- A failed shortcut read leaves the source editor focused and shows a brief
  warning instead of requiring dismissal of a Bean window.
- Native local checking is bounded to 50,000 characters and manual provider
  actions to 8,000; a larger field is not treated as a successful clean review.

Optional AXEditable/AXReadOnly attributes are not implemented by every app.
Readable text with a settable selection can be paste-editable despite having no
AXValue setter, so Bean verifies the actual result of a single normal paste.
It does not repeat a failed paste blindly.

Whole-field actions currently replace plain text. They do not guarantee
preservation of rich formatting or attachments; explicit selection keeps
unrelated content outside that selection intact.

## Browser extension

The user confirmed Command-Option-G directly replaces text in ChatGPT, Claude,
Slack, and Chrome's Gmail composer on October 2, 2026, and subsequently confirmed
that Mail works after the shared rich-editor fix. These reports verify the
manual workflow on those tested fields; live underlines and every editor variant
still require separate verification.

For a supported, focused web field, the extension's single control handles
review, Proofread, and Rewrite while a short lease suppresses overlapping native
controls. Local checking combines page rules with offline macOS spelling when
the native bridge is available. Browser toolbar/address controls retain native
assistance, and an expired or released lease restores the native path.

The unpacked Chromium extension works best in plain text inputs, textareas, and
simple contenteditable editors such as basic Gmail composition. Complex rich
editors vary. Slack web's ProseMirror composer, Google Docs canvas editing,
Slack desktop, Safari, password/search/email-address fields, and code editors
are excluded from the Chromium extension path for 1.6.

When an unsupported or ambiguous target is detected, the correct behavior is to
show no highlight or decline replacement—not to guess.

Compatibility reports should include app/version, macOS version, field type,
and synthetic reproduction text. Focus the problem field and run Bean → Help →
Check Current Field, then use Settings → Privacy & Help → Preview Support Report.
Review the preview before copying it; Bean never uploads the report. See
[SUPPORT.md](SUPPORT.md).
