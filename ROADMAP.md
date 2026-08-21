# Bean Product Roadmap

This roadmap turns the public-beta findings into one reliability-focused release.
The phases are deliberately sequential: later product work must not conceal an
unreliable or unexplained core correction flow.

## Product objective

A new user should be able to install Bean, verify setup, and complete a real
cross-app correction within five minutes. Every attempted operation should end
in an understandable, recoverable state without storing the user's text or
silently spending provider tokens.

The north-star measure is **successful manual transformations per active week**.
Supporting local measures are first-success completion, confirmed replacement
rate, clipboard-fallback rate, safety-review rate, provider failure rate, and
automatic versus manual provider usage.

## Product constraints

- No Bean account, hosted text service, advertising, or remote analytics.
- Operation history is content-free, local, bounded, visible, and erasable.
- API keys remain in macOS Keychain.
- Automatic provider calls remain off by default and have explicit limits.
- Unsupported fields fail closed; secure fields are never read.
- Uncertain model output is never applied automatically.
- Experimental features remain opt-in and are grouped as Labs.

## Phase 1 — Activation and diagnostics

**Status:** Complete.

### Actions

1. Add a Setup & Status screen with live checks for app location, API key,
   provider connection, Accessibility permission, shortcuts, and the most recent
   current-field capability inspection.
2. Add a menu-bar **Check Current Field** action that evaluates the frontmost
   field without reading or recording its text.
3. Replace the onboarding-only provider demonstration with a guided TextEdit
   cross-app verification. Completing a confirmed external replacement marks
   the end-to-end check as passed.
4. Add a bounded local operation ledger containing metadata only: timestamp,
   app/category, action, input mode and length, provider/model, duration, safety
   result, replacement result, token counts when known, and automatic/manual
   source.
5. Include recent operation outcomes in the diagnostics summary, add one-click
   copy/clear actions, and open the GitHub bug form from the app.
6. Update privacy/support documentation and add tests proving history excludes
   text and remains bounded.

### Acceptance criteria

- Setup clearly distinguishes provider readiness from cross-app readiness.
- A user can inspect a target field from the menu bar and receive a reason-coded
  capability result.
- A confirmed TextEdit replacement completes the onboarding verification.
- The last 50 content-free operations survive relaunch and can be erased.
- No source or transformed text is encoded in the history or support report.

## Phase 2 — Trust and recovery

**Status:** Complete.

### Actions

1. Divide safety findings into hard blocks (empty output, wrappers, prompt leaks,
   model commentary, script changes) and review-required findings (length or
   question-shape anomalies).
2. Route review-required output to a preview rather than discarding it. The
   original stays untouched until the user explicitly replaces or copies it.
3. Replace transient clipboard-fallback-only messaging with a persistent
   recovery preview containing the sanitized result and clear Copy, Retry, and
   Cancel controls.
4. Add a compact before/after comparison for proofreading and rewrite previews.
5. Add a safe, memory-only **Undo Last Bean Change** command. Undo is offered
   only for a recent confirmed whole-field replacement whose current value still
   equals Bean's result.
6. Record safety-review, fallback-preview, retry, cancel, and undo outcomes.

### Acceptance criteria

- Reviewable output is never auto-applied and is not lost.
- Hard-blocked output can never reach replacement or clipboard fallback.
- Failed replacement always leaves a visible recovery path.
- Undo refuses stale/different fields and never persists original text to disk.
- Preview and safety-policy tests cover every reason code.

## Phase 3 — Cost visibility and controls

**Status:** Complete.

### Actions

1. Capture provider-reported input/output token counts from OpenAI and Anthropic,
   with a conservative local estimate when usage is unavailable.
2. Store aggregate counts by manual, passive, native inline, and web inline
   source; never store request or response content.
3. Add a Usage & Cost dashboard for today, the last 30 days, average tokens per
   operation, automatic-call count, and an explicitly labelled cost estimate.
4. Add a daily automatic-call limit and a monthly total-token warning threshold.
   Manual actions remain available after the automatic limit is reached.
5. Add **Local Quick Check** as a no-provider action while keeping **AI
   Proofread** as the thorough manual action.
6. Keep all automatic provider features disabled by default and show whether a
   chosen action is local or provider-backed before it runs.

### Acceptance criteria

- Provider usage is decoded for both providers and estimate fallback is tested.
- Automatic calls stop locally at the configured limit without disabling manual
  actions or local checks.
- Users can clear usage/history and see that doing so does not remove API keys.
- Local Quick Check makes no network request.

## Phase 4 — Focused compatibility

**Status:** Complete.

### Actions

1. Define explicit capability profiles for TextEdit, Apple Notes, Apple Mail,
   Slack desktop, and Chromium web editors.
2. Centralize capability decisions used by focused-field acquisition, Bubble
   visibility, native inline coverage, and diagnostics.
3. Report four independent capabilities: selected-text action, focused-field
   replacement, Bean Bubble, and inline mode.
4. Add deterministic unit tests for secure, disabled, read-only, search, code,
   native text, Electron, and browser surfaces.
5. Maintain a versioned manual compatibility matrix with expected results and a
   release-blocking smoke-test checklist for the five reference experiences.
6. Improve the extension setup/status language and native-host diagnostics for
   Slack web and Gmail.

### Acceptance criteria

- All UI entry points use the same capability policy.
- Bean never advertises Bubble or focused replacement for a disabled, secure,
  read-only, search-disabled, or code-disabled surface.
- Reference-surface expectations are executable where possible and documented
  where OS/application automation is not reliable.

## Phase 5 — Simplification and sustainable distribution

### Actions

1. Consolidate Bean Bubble, Passive Suggestions, Inline Highlights, and the
   browser extension under one **Labs** settings category.
2. Keep primary navigation limited to Setup, Provider & Usage, Shortcuts,
   Actions & Style, Context, Privacy, Labs, and Troubleshooting.
3. Add a user-triggered GitHub Releases update check with no background polling,
   analytics, or automatic installation.
4. Show the installed version, latest version, prerelease status, and a button
   to open the verified GitHub release page.
5. Document objective gates for Apple notarization and Chrome Web Store
   publication. Neither paid external program is required for source releases.
6. Add maintainer release checks for update metadata, public-beta lab defaults,
   and distribution wording.

### Acceptance criteria

- Experimental controls are visually separated from the dependable core flow.
- Update checks happen only after a user click and fail with an actionable
  message.
- No executable update is downloaded or installed by Bean.
- Paid distribution remains a documented decision, not a hidden build
  dependency.

## Release gate

Before publishing the completed release:

1. Run XCTest, standalone logic tests, browser-extension tests, shell validation,
   and the repository/history credential audit.
2. Run the five-surface manual smoke-test matrix.
3. Build a universal Intel/Apple-silicon app and verify its signature, version,
   bundled documentation, ZIP, DMG, and SHA-256 file.
4. Install the exact artifact into `/Applications`, verify it launches, and
   preserve the prior app for rollback.
5. Commit each completed phase independently, publish `main`, tag the matching
   version, and wait for CI, CodeQL, and the prerelease workflow to finish.
