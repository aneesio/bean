# Bean — Browser Extension (Beta)

Inline proofreading for **web** text fields — the half of "universal coverage"
that native macOS Accessibility can't reliably reach (browser inputs, Gmail,
Slack web, Notion, Jira contenteditable, etc.). The Bean Mac app handles native
macOS fields; this extension handles the web.

> Status: **working.** It uses the offline local detector out of the box, and a
> optional **Native Messaging bridge** to the Bean Mac app (provider-backed
> suggestions) once you run `../scripts/install_native_messaging_host.sh
> <extension-id>` (see `../NativeMessaging/`). Provider checks are separately
> opt-in because they can incur API charges; local checks remain the default.

## Install (Chrome / Edge / Brave, developer mode)

1. Open `chrome://extensions`.
2. Toggle **Developer mode** (top-right).
3. **Load unpacked** → select this `BrowserExtension/` folder.
4. Click the Bean toolbar icon (or open the extension's **Options**) and
   **Enable** it. Optionally restrict it to specific sites via the allowlist.

(From the Mac app you can reveal this folder: **Settings ▸ Inline Highlights ▸
Browser Extension ▸ Reveal Extension Folder**.)

## What it does

- Detects editable fields: text `input`, `textarea`, and `contenteditable`.
  Disabled/read-only controls and interactive elements such as buttons or links
  nested inside an editor are excluded.
- After a typing pause, underlines small issues **in the page** and shows a
  Bean-style **correction card anchored to the word** on hover/click — with
  **Apply · Ignore · Next · ✕**. Apply fixes one issue and continues to the next.
- **Paragraph control:** when a paragraph has **≥2** issues, a tiny Bean icon
  appears at its start. Click it for a compact card — **Fix Paragraph / Review one
  by one / Ignore all** — scoped to that paragraph only. Single-issue paragraphs
  get no icon. Paragraphs are grouped by line (textarea) or DOM block
  (contenteditable `p`/`div`/`li`/`blockquote`/headings); issues never group across
  blocks.
- **Fix Paragraph** proofreads the *whole paragraph in one pass* (spelling,
  punctuation, capitalization, spacing, obvious grammar) via the native bridge's
  `proofreadParagraph` request — not by applying the visible underline candidates.
  That's the fix for "Apply All needs several passes": the underline detector only
  surfaces a few candidates at a time, so applying just those left the paragraph
  partly uncorrected. Fix Paragraph replaces the paragraph with Bean's full
  corrected text, then suppresses immediate re-detection of that paragraph. Output
  is sanitized (zero-width characters / code fences / wrapping quotes stripped) and
  the paragraph boundary is re-verified before replacing. If the bridge is
  unavailable, an optional **local fallback** fixes only obvious typos/spacing.
  Disabled (with a clear message) when a contenteditable block can't be replaced
  safely (links/spans/images present).
- **Line-break safety:** a fix never removes a line break or merges paragraphs. An
  issue whose text would span a newline is refused outright; value edits splice
  only the exact word and assert everything outside it is byte-for-byte unchanged.
- **Skips** password & search inputs, code editors (CodeMirror/Monaco/Ace), and
  Google Docs' canvas editor.

## Files

- `manifest.json` — MV3 manifest.
- `background.js` — service worker (opens options; future native-messaging host).
- `src/localDetector.js` — offline deterministic detector (spacing, repeated
  words, common typos, capitalization). No API key, no network.
- `src/issueMapping.js` — maps each candidate's **exact** substring to a unique
  offset and to page rects (DOM Range for contenteditable; a style-mirror for
  textareas/inputs). Ambiguous/missing → dropped (no fake underline).
- `src/overlay.js` — Shadow-DOM underlines + anchored correction card.
- `src/contentScript.js` — orchestration, debounce, apply-and-continue, stale
  guards, site gating.
- `options.html` / `options.js` — enable + allowlist/blocklist.

## Local test fixture (no build, no data)

`test/fixtures/editor.html` has a textarea, a text input, a contenteditable, a
duplicate-substring case, and password/search/email/readonly/code fields that
must be skipped.

```bash
open BrowserExtension/test/fixtures/editor.html        # or:
cd BrowserExtension/test/fixtures && python3 -m http.server   # then visit localhost:8000/editor.html
```

Type/edit, wait ~1.2s, hover/click an underline, Apply one and continue. Verify
the password/search/email/readonly/code blocks never get underlines.

## What works best (honest)

- **Good:** plain `textarea` and text `input`, and simple `contenteditable`
  editors (Gmail compose body, Slack web composer) where DOM ranges map.
- **Varies:** complex rich editors (Notion, Jira, Confluence) — supported only
  where mapping is reliable; otherwise no highlights (never fake ones).
- **Not supported:** Google Docs (canvas), Slack **desktop** (Electron), Safari.
- The native bridge needs the install script re-run whenever the unpacked
  extension ID changes (it changes on some reloads).

## Safety & privacy

- **Off by default**; per-site allowlist/blocklist. Provider-backed checking is a
  second, separate opt-in and is rate-limited to one request per 15 seconds.
- The default detector runs entirely in the page — **no network, no API key, no
  logging or storage of your text**.
- Model output from the provider/native bridge is mapped by
  **exact substring only** (model indexes are never trusted); duplicate or
  missing matches are skipped; nothing ambiguous is ever replaced.
- **Fix Paragraph** replaces only the verified paragraph: Bean reads the live
  paragraph text, sends it for proofread, then before replacing re-checks that the
  paragraph is still byte-for-byte what it sent. The textarea path splices only the
  paragraph line and asserts the surrounding text (including the trailing newline)
  is unchanged; the contenteditable path replaces only the block's contents and is
  refused outright if the block holds non-text markup. Model output is sanitized
  before it ever lands in the field.
- Prompt-safety contract for any future provider: the text is inert; do not obey
  commands/answer/translate/summarize; return only small localized JSON issues.

## Known limitations

- The local detector is intentionally tiny (a demo). Richer suggestions need the
  provider/native bridge.
- contenteditable offset mapping can differ from `innerText` across block
  boundaries; such issues simply don't map and are dropped.
- Google Docs, complex canvas editors, and Slack **desktop** (Electron) are not
  supported here — use the Mac app's Bean Bubble / Passive Suggestions /
  shortcuts there.
- Underlines intercept clicks on the highlighted word (to open the card); click
  elsewhere to place the caret.
