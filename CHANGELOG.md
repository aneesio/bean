# Changelog

Notable user-facing changes are recorded here. Bean follows semantic versioning
once public release tags begin.

## Unreleased

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
