# Changelog

Notable user-facing changes are recorded here. Bean follows semantic versioning
once public release tags begin.

## 1.4.0 — 2026-08-21 (public beta)

- Changed the browser extension from an approved-sites allowlist to writing help
  on ordinary websites by default, with a persistent blocked-sites list.
- Added **Disable on this field** and **Disable on this website** controls to web
  correction and paragraph cards, plus hover access from paragraph Bean icons.
- Kept browser AI checks independently opt-in; default browser detection stays
  local and has no provider token cost.
- Redesigned browser Options around a minimal readiness summary, blocklist, and
  a bounded connection check instead of setup/test terminology.
- Reduced Bean Settings from eight technical destinations to six human-focused
  areas, with detailed diagnostics hidden under an Advanced disclosure.
- Simplified the menu-bar menu to everyday actions and moved permission/support
  recovery into Settings.
- Refined first-run onboarding copy and hierarchy, hid model IDs from the main
  path, removed the misleading Skip action, and stopped window-close from
  marking an unfinished setup complete.
- Simplified browser setup to an in-app two-step flow with automatic extension
  discovery and connection repair—no Terminal command required.

## 1.3.1 — 2026-08-21 (public beta)

- Fixed a native-host main-actor deadlock that left the browser extension's
  connection check stuck on “Checking…” with no response.
- Added bounded bridge timeouts and actionable recovery messages in both the
  extension service worker and Options page.
- Replaced the Terminal-based native-host setup with in-app extension
  discovery and one-click Install/Repair for Chrome, Brave, Edge, and Chromium.
- Added a guided, optional browser step to first-run onboarding and a numbered
  setup flow in both Bean Settings and extension Options.
- Preserved guarded Slack composer typing evidence while Bean's menu is used,
  and applied that fallback consistently to field inspection, the Bean Bubble,
  and whole-composer manual replacement.
- Replaced internal field-policy reason codes in Settings with plain-language
  capability explanations and added content-free browser-bridge diagnostics.

## 1.3.0 — 2026-08-21 (public beta)

- Added a Setup dashboard, metadata-only field inspection, guided TextEdit
  verification, and a bounded content-free operation history.
- Split unsafe output into hard-block and review-required paths; added compact
  comparisons, persistent replacement recovery, retry/copy controls, and safe
  in-memory undo for confirmed whole-field changes.
- Added provider-reported token accounting, a 30-day usage/cost dashboard,
  per-source totals, automatic-call limits, and a configurable token warning.
- Added a provider-free Local Quick Check and made provider-backed actions
  explicit in the UI.
- Changed the default OpenAI model for new configurations to `gpt-5-nano`.
- Added explicit browser review for unusual whole-paragraph output.
- Centralized field capability decisions and added executable profiles for
  TextEdit, Notes, Mail, Slack desktop, and Chromium web editors.
- Added Gmail/Slack web approval and automatic-budget diagnostics to extension
  status.
- Simplified Settings to eight primary categories and grouped the Bean Bubble,
  Passive Suggestions, Inline Highlights, and browser extension under Labs.
- Added a manual-only GitHub Releases update check with verified release links,
  prerelease labeling, and no download or install behavior.
- Documented separate open-source, unnotarized GitHub, Apple-notarized, unpacked
  extension, and Chrome Web Store distribution gates.

## 1.2.0 — 2026-08-21 (public beta)

- Prepared the repository for an open-source public beta.
- Added reproducible CI, release validation, community documentation, and
  automated regression tests.
- Removed generated release binaries and personal Xcode state from tracking.
- Changed the browser extension from blanket host access to explicit per-site
  optional permissions.
- Added visible Keychain/personalization persistence errors and restrictive
  local personalization file permissions.
- Hardened native-messaging reads against partial pipe frames and unaligned
  length decoding.

## 1.1.0 — internal beta

- Added the Bean Bubble, passive suggestions, experimental native/browser inline
  checks, writing actions, personalization, and native messaging.
- Improved replacement verification, provider-output sanitization, and Slack
  desktop focus/replacement behavior.
- Disabled paid automatic provider paths by default and added cost controls.
