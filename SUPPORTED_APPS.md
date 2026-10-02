# Supported Apps and Surfaces

Policy revision: **1.7.0 candidate, build 14 / extension 0.8.0, October 2, 2026**. Capability
routing is covered by `FieldCapabilityPolicyTests`; implementation checks are
covered by focused-field, native-editing, issue-mapping, and geometry tests.
These do not substitute for live compatibility checks in each application.

Bean evaluates the focused control rather than excluding entire application
categories. It resolves editable text descendants and ancestors, enables an
application's Accessibility tree where supported, and reads range text when
AXValue is unavailable. Editable WebKit surfaces are identified by editing
capabilities and use their text-marker APIs when ordinary text attributes are
missing. This routing does not require a list of supported app names.
Native span replacement prefers a writable selected-text capability after
checking the settled range, actual selected text and complete source. Where that
setter is unavailable, normal Paste/Delete events target the captured app. Both
paths require an exact output check; an uncertain delivered edit is not retried. Readable rich drafts use bounded, verified span edits for
Proofread and whole-field Rewrite instead of replacing the entire document as
plain text. Bean Undo is available only for an exact output in the same field
and a safe restoration path.

## Expected native paths

| Reference surface | Text acquisition / replacement | Live issues | Outstanding live check |
| --- | --- | --- | --- |
| TextEdit | Native text and selection; verified span edits where ranges are writable | Native underlines and one field-side assistant | Candidate manual journey, clipboard/caret and native Undo. |
| Apple Notes | AX value/range text; surgical edits where exact ranges are supported | Underlines when exact range bounds exist; field-side cards otherwise | Candidate rich-note formatting, attachments and native Undo. |
| Apple Mail | Generic editable WebKit/native composer path; explicit marker-selected passage may use guarded paste | Underlines where exact geometry exists; field-side cards otherwise | Pre-candidate user confirmation of the manual action only. Candidate live corrections, rich formatting, attachments, and other composer variants remain unverified. |
| Electron apps | Application-provided Accessibility tree, editable ancestors and guarded edits | Native positions where available; field-side cards otherwise | Candidate per-app composer behavior, including Slack and VS Code. |
| Browser fields | Native capabilities or optional DOM extension; exact range edits | One native or extension assistant for the focused field | Candidate input, textarea, rich contenteditable and framework-controlled field journeys. |
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
  normal edit events aim to retain the source app's native Undo, which must be
  verified in that app.
- A failed shortcut read leaves the source editor focused and shows a brief
  warning instead of requiring dismissal of a Bean window.
- Native local checking is bounded to 50,000 characters and manual provider
  actions to 8,000; a larger field is not treated as a successful clean review.

Optional AXEditable/AXReadOnly attributes are not implemented by every app.
Readable text with a settable selection can be editable despite having no
AXValue setter. Bean proves the actual selection before using the supported
selected-text setter or one guarded Paste/Delete command, then verifies the
complete result. It does not repeat an uncertain delivered edit blindly.

## Scope, rich content and Undo

Selected passages, whole drafts and the current paragraph are distinct scopes.
Native paragraph actions require a proven numeric caret and writable range;
opaque text markers do not provide guessed paragraph offsets. An explicitly
selected marker passage retains its guarded paste path. Selected rewriting may
change formatting inside that selection, while unrelated content stays outside
the target.

Rich whole-field Proofread and Rewrite preserve unchanged spans through bounded
edits. Changes to paragraph structure, attachment markers, grapheme boundaries,
or unprovable ranges are declined. Native fields without those editing
capabilities need an explicit selected passage; there is no silent rich-document
plain-text fallback. Proven plain single-line inputs retain their guarded
whole-value fallback.

Browser rich edits also require safe text-node boundaries. A paragraph-start or
end insertion uses the actual paragraph node; an ambiguous boundary without
that scope is refused. Page handlers that move focus, alter text or take over
the caret stop further edits. Bean restores an unrelated typing position only
while its last edit still owns the selection. A confirmed partial batch may
offer Undo for exactly the verified subset; newer writing makes that Undo
unavailable. Arbitrary rich rewrites and every source app's Undo grouping are
not guaranteed.

Owned AppKit and nonpersistent WebKit editor fixtures exercise attributed spans,
links, lists, signatures, attachments, Unicode, selection and reversible edits.
They establish editor-model behavior, not third-party app or cross-process AX
compatibility. Live WebKit AX fixtures unavailable in the test host remain skips.

## Checking coverage and controls

Live checking combines conservative local rules with available macOS spelling
and basic grammar services. Missing language dictionaries, service failures and
bounded scans are reported as limited coverage. No suggestions means these
checks found none; it does not certify an error-free draft. Without the native
bridge, the browser provides its smaller basic rule checker.

Fix All applies only verified, nonoverlapping deterministic local corrections;
ambiguous spelling guesses and AI suggestions require review. A trusted Learn
word action saves a spelling token in Bean's dictionary. Browser learning needs
the compatible bridge and running Bean GUI to acknowledge persistence; failure
does not claim the word was saved. Ignored occurrences remain dismissed while
their exact context can be tracked.

English dialect can be Automatic, Canadian, US or British. Automatic follows the
Mac's spelling language with source-language detection where available; valid
regional spellings and saved terms are protected. This does not promise complete
grammar support for every language.

Native automatic assistance can be paused for one hour or until resumed from
the menu bar; Resume is also available in Writing settings. Manual native
shortcuts and explicit provider actions remain available. The focused extension
refreshes app-pause status every five seconds, suppresses automatic basic/Mac/AI
suggestions when the pause is known, and retains explicit writing controls.
Website pause lasts
one hour for the exact host and resumes from the extension popup/settings or on
expiry. Permanent website disabling includes subdomains. Cancel stops a pending
explicit provider result from being applied; work already sent may still be
billed. Native Cancel is available during provider work, before guarded editing.

## Browser extension

The user confirmed Command-Option-G directly replaces text in ChatGPT, Claude,
Slack, and Chrome's Gmail composer on October 2, 2026, and subsequently confirmed
that Mail works after the shared rich-editor fix. These are pre-candidate,
user-reported manual workflows on those fields, not new 1.7.0 compatibility
tests. Live underlines and every editor variant still require verification.

For a supported, focused web field, the extension's single control handles
review, Proofread, and Rewrite while a short lease suppresses overlapping native
controls. Local checking combines page rules with offline macOS spelling when
the native bridge is available. Browser toolbar/address controls retain native
assistance, and an expired or released lease restores the native path.

A separate content-free focus guard can suppress a duplicate native control on
permanently disabled HTTP(S) websites. It does not inject writing assistance or
read draft text on those sites. Temporary site pause retains suppression for its
focused field; browser toolbar/address controls remain separate.

The unpacked Chromium extension works best in plain text inputs, textareas, and
simple contenteditable editors such as basic Gmail composition. Framework-based
rich editors, including Slack web's ProseMirror composer, are evaluated by their
editing capabilities and remain unverified on this candidate. Google Docs canvas
editing, password/search/email-address fields, and code editors are excluded.
Slack desktop and Safari use the native path rather than the Chromium extension.

When an unsupported or ambiguous target is detected, the correct behavior is to
show no highlight or decline replacement—not to guess.

Compatibility reports should include app/version, macOS version, field type,
and synthetic reproduction text. Focus the problem field and run Bean → Help →
Check Current Field, then use Settings → Privacy & Help → Preview Support Report.
Review the preview before copying it; Bean never uploads the report. See
[SUPPORT.md](SUPPORT.md).
