# Bean 1.7.1 — public beta

Build **21**, with Chromium extension **0.8.7**. This release focuses on writing
in other apps; ordinary launch and completed setup return to the menu-bar
experience.

## What changed

- Bean now uses Bean Green (`#237A48`) across the Mac app and browser extension,
  with a dimensional green-bean icon, a larger yellow seed scar, and a gentler
  bend. App and browser icon sizes are regenerated from the editable SVG, and
  the menu-bar template uses the matching bean silhouette.
- Actions use rounded capsule buttons throughout the Mac app and extension,
  retaining clear primary and secondary treatments.
- Field controls are now tiny status dots without a pill, logo or visible count.
  Bean-green dots indicate no current suggestions. Vivid red dots with a tiny
  contrasting exclamation mark indicate possible issues in the Mac app and browser.
  The contrasting marker distinguishes the state beyond color in light/dark
  appearances and browser forced colors. Hover shows status and click opens the review/actions panel.
- Place the dot inside the exact text area, preferring a clear top-right corner.
  Normal fields keep a 28-point pointer target; compact fields use 20 points,
  with the same 8-point dot. Text, caret and exposed control geometry guide
  alternate inside positions; no candidate is clamped over a Send button.
- Visibility no longer depends on an empty outside margin or verifying every
  unrelated app/page branch. Full-window editors can show an inside dot. Missing
  exact source geometry, obscured fields or no usable clear space still hide it;
  underlines and menu-bar/shortcut assistance keep their own capability paths.

- One field-side assistant provides quiet checking status, issue review,
  Proofread and Rewrite. Supported browser fields use the extension assistant
  while native controls yield for that field. Native handoffs cancel pending
  fallback dots, and extension contexts reuse one overlay and clear stale UI
  when invalidated. Reloading the extension updates eligible open pages in
  place without refreshing pages or changing drafts, focus, or selection;
  local checks remain available without the native host.
- Routine Proofread and Rewrite apply directly to the verified source. Readable
  rich drafts use bounded span edits to retain unchanged formatting, links,
  signatures and attachments. Selected text, whole draft and precise current
  paragraph are separate scopes; unsafe structural or ambiguous edits decline.
- Fix native replacement in Slack and other Chromium/Electron editors by using
  guarded keyboard edits instead of their misleading writable selected-text
  capability. Native editors with a supported selected-text setter retain that
  path. Both paths verify the settled range, selected text and source; commands
  target the captured app, and an uncertain edit cannot be blindly retried.
- Unconfirmed native delivery cannot become a copied-result retry. Undo claims one
  operation at a time, consumes an attempted inverse, and preserves newer history.
- Browser range editing no longer repeats a mutation after the page receives or
  cancels an editing event. A fallback requires a proven undelivered no-op.
- Native field controls and review windows have descriptive accessibility names;
  decorative underlines are omitted from the navigation tree.
- Exact source, focus, clipboard and UTF-16 checks protect newer writing.
  Unrelated carets are retained while Bean still owns the selection. Undo is
  offered for an exact confirmed change, including a safely verified partial
  batch, and becomes unavailable after newer text.
- Offline macOS spelling and basic grammar supplement conservative local rules.
  Browser checks use the compatible local bridge without an API key; missing
  spelling/language services show limited coverage. Ambiguous spelling offers
  alternatives rather than blindly applying the first guess.
- Fix All handles verified deterministic local corrections. Trusted Learn word,
  stable occurrence dismissal and Automatic/Canadian/US/British English dialect
  settings protect vocabulary and valid regional spelling.
- Native app assistance can be paused for one hour or until resumed. Website
  pause lasts one hour on the exact host; permanent website disabling remains
  separate. Explicit provider actions can be cancelled before application;
  already-sent provider work may still be billed.
- Provider-specific model choices apply compatible request settings, including
  Claude Haiku 5.5, and preserve previously saved model IDs on upgrade. OpenAI
  `gpt-5-nano` and Anthropic `claude-haiku-4-5` remain the defaults. Usage
  accounting includes cost estimates for Claude Haiku 5.5.
- Build, local install and packaging now verify candidates before publishing,
  retain rollback copies/artifacts and guard concurrent or interrupted updates.

## Compatibility and quality boundaries

Editors must expose readable text and a safe editing destination. Whole rich
documents without exact writable ranges require an explicit selected passage;
marker-only selections do not provide guessed paragraph offsets or whole-document
Undo. Browser changes spanning incompatible rich nodes, code or attachments are
declined. See [SUPPORTED_APPS.md](https://github.com/aneesio/bean/blob/v1.7.1/SUPPORTED_APPS.md).

Owned synthetic AppKit/WebKit editor tests and a family-isolated local writing
benchmark provide reproducible evidence, not third-party compatibility or
Grammarly parity. The recorded benchmark still misses its strict heldout
preferred-correction goal. Historical user reports that manual actions worked
in ChatGPT, Claude, Slack, Gmail and Apple Mail predate this release; live
underlines, every app variant and rich-document behavior still need separate
manual validation. No real provider quality certification is claimed. See the
[quality record](https://github.com/aneesio/bean/blob/v1.7.1/docs/qa/WRITING_QUALITY_2026-10-02.md).

## Before you install this public beta

This GitHub beta is an **unnotarized prerelease**. Download the DMG only from
the official Bean repository, open it, and drag Bean to Applications. On first
launch, macOS may block the app; if you trust the download, use **System
Settings → Privacy & Security → Open Anyway**. No Terminal command is required.
The optional checksum procedure and Finder-only rollback steps are in the
[README](https://github.com/aneesio/bean#github-beta-dmg).

Bean's local Quick Fix and offline browser checker are free and do not call an
AI provider. Provider setup is optional. Any provider-backed action uses your
own API key and may incur provider charges; automatic provider checks are off by
default and can be disabled or capped in **Settings → AI & Usage**.

The unpacked browser extension runs local checks on ordinary websites by default,
except sites you block. Deeper browser AI is a separate opt-in, and the
extension can be paused or disabled for an individual website from the Bean
control, or disabled for a field during that page session. Explicit browser
Proofread/Rewrite provider actions use the manual-action path and remain
available when automatic AI is off or capped. Without a provider, browser
Proofread offers local checks; native Quick Fix stays local. See the
[privacy policy](https://github.com/aneesio/bean/blob/v1.7.1/PRIVACY.md)
for the complete data boundary.
