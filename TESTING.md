# Bean Testing Guide

Current candidate: **Bean 1.7.0 (17), Chromium extension 0.8.3**. A checklist
below is a required test, not a recorded pass. Historical user reports and the
current automated evidence must be recorded separately.

Automated checks are necessary but cannot fully exercise macOS Accessibility,
clipboard replacement, or third-party editor geometry. Every public beta should
pass both the automated suite and the focused manual matrix below.

The complete phase-by-phase release-candidate protocol and sign-off record live
in [QA_TEST_PLAN.md](QA_TEST_PLAN.md).

Use synthetic text only. Never place real API keys or private writing in test
logs, screenshots, fixtures, or issues.

## Automated checks

Run the complete local suite:

```bash
./scripts/run_all_tests.sh
```

It runs:

- XCTest regression tests against the app module;
- the standalone safety/normalization harness;
- browser detector, mapping, settings-migration, and manifest tests;
- shell syntax checks;
- repository and Git-history secret/path audits.

Then assemble a fresh app:

```bash
./scripts/build_app.sh release
codesign --verify --deep --strict --verbose=2 build/Bean.app
```

Run the owned editor and transaction regressions when changing replacement:

```bash
swift test --filter 'NativeEditPlanTests|NativeEditTransactionTests|OwnedWebEditorModelTests|ReplacementUndoStoreTests'
```

The AppKit fixture uses synthetic attributed text and attachments; the
nonpersistent WKWebView fixture loads the production browser mapping helper
without network content, cross-process AX, clipboard access or other apps. Its
passes do not replace third-party app tests. Unavailable live WebKit AX tests
remain skips, with their reason recorded.

Writing quality has a separate, opt-in local evaluation:

```bash
./scripts/run_quality_benchmark.sh build/quality-reports/candidate
./scripts/run_quality_benchmark.sh --enforce build/quality-reports/candidate-gated
```

The frozen, family-isolated 1,024-case synthetic corpus and measured results are
documented in [WRITING_QUALITY_2026-10-02.md](docs/qa/WRITING_QUALITY_2026-10-02.md).
The recorded strict gate currently fails preferred correction accuracy on the
heldout split; do not reduce the gate or call the candidate certified. These
checks make no paid provider request. An unavailable dictionary/service is not a
clean pass. Human-reviewed labels, external corpora and real-provider judgment
remain separate evidence.

Prepare the separate provider-evaluation review pack without credentials or
paid requests:

```bash
./scripts/run_provider_quality_evaluation.sh --dry-run
```

Paid evaluation is opt-in with an explicit provider/model, request and estimated
cost budget; blind human ratings are required. A dry-run pack or mock response
does not establish provider quality.

## Clean-install gate

- Quit every running copy of Bean.
- Put the candidate in a stable path, normally `/Applications/Bean.app`.
- Remove the prior Accessibility entry when testing an identity change.
- Launch Bean and complete onboarding without developer assistance.
- Confirm provider selection, Keychain persistence, Accessibility re-check, both
  shortcuts, menu bar icon, Settings, About, and launch at login.
- Quit and relaunch; settings and shortcuts must remain stable.

## Core action gate

Exercise selected text and focused-field mode with short synthetic samples:

| Scenario | Expected result |
| --- | --- |
| `i has a apple` → Proofread | Small grammatical correction; no commentary footer. |
| Already-correct sentence | No replacement or a clear no-changes result. |
| Make Clearer/Concise/Professional/Casual | Safe output replaces the unchanged source directly; Bean Undo appears only when safe restoration is available. |
| Whole rich draft Proofread/Rewrite | Bounded span edits preserve unchanged formatting, links, signatures and attachments; structural or unprovable edits decline safely. |
| Current paragraph | Exact paragraph scope is shown before the action; a missing numeric native caret or ambiguous browser boundary refuses the action. |
| Explicit marker-selected passage | Guarded selected-span paste remains available; do not offer whole-document Bean Undo for opaque selection. |
| Fix All obvious issues | Applies only deterministic local, nonoverlapping verified corrections; no provider call and no automatic choice of ambiguous spelling guesses. |
| Reply actions | Draft is copy-first and never replaces the source message. |
| Provider returns a label/fence/footer | Wrapper is removed or unsafe output is rejected. |
| Field changes while request is running | Bean refuses stale replacement and preserves the correction safely. |
| Paste cannot be verified | UI reports an unconfirmed replacement or the actual clipboard recovery state; it never falsely says “fixed.” |

After every replacement test, verify text before and after the intended range,
rich node/attachment identity, caret and native Undo. Bean Undo must affect only
the same field while its exact output remains present. Check exact partial Undo
after one verified span and an interrupted batch; a newer or unverified mutation
must not be rolled back. The prior clipboard must be restored unless the UI
explicitly reports a clipboard fallback; a newer user copy must survive.

Exercise first focus, a new revision and the clean cache path, not just a card
that was already visible. Include repeated typos, emoji/combining sequences,
CRLF, source quotation/outer whitespace, paragraph-start/end insertions,
deletions and attachments. Move focus/caret, edit the source or copy new text
while a provider is pending and during a controlled transaction. No result may
overwrite those newer changes. Cancel a pending native/browser explicit action
and let a delayed completion arrive; it must not apply. Work already sent may
still be billed. Native Cancel ends before guarded application begins.

## App compatibility gate

The five reference experiences are release-blocking. Record pass/fail and a
reason code for every non-pass; do not silently mark an unavailable app as
tested.

| Surface | Selected text | Focused field | Bubble | Inline/fallback | Boundary check |
| --- | --- | --- | --- | --- | --- |
| TextEdit | Correct + verify | Correct + verify | Anchors only to editor | Native highlight or documented range fallback | Read-only view excluded |
| Apple Notes | Correct selection | Preserve note structure | No button/control anchors | Native or passive fallback | Formatting outside target unchanged |
| Apple Mail | Correct in composer | Preserve greeting/sign-off | Composer only | Native or passive fallback | Displayed mail excluded |
| Slack desktop | Correct selection | Composer replacement or honest fallback | Composer/evidence only | Range underlines/cards only with proven editor capabilities | Channel buttons excluded |
| Chromium (Gmail + Slack web) | Manual path best effort | Honest AX fallback | Native controls or supported DOM field | Local extension checks on by default unless blocked; complex editors may use the native path | Extension skips search/email-address fields; ordinary buttons excluded |

Also test one code editor, a search field, password field, disabled field,
read-only field, and ordinary button. Eligible editable controls in code apps
and search fields use the native capability policy; secure, disabled, read-only,
and non-text controls fail closed according to [SUPPORTED_APPS.md](SUPPORTED_APPS.md).

Record macOS version, app version, acquisition path, replacement result, and any
content-free diagnostics. Update [SUPPORTED_APPS.md](SUPPORTED_APPS.md) when a
repeatable compatibility boundary changes.

The October 2 reports for ChatGPT, Claude, Slack, Gmail and subsequently Apple
Mail are user-reported pre-candidate manual workflows. They do not mark this
candidate's live correction, rich formatting, attachment or Undo journeys passed.

Repeat one native and one browser control with input-method composition,
dictation, zoom, display changes and light/dark appearance. Compose text must not
be edited mid-composition. Record keyboard/VoiceOver focus and a readable issue
card without automatic card opening or overlapping native/browser controls.

## Cost and privacy gate

- Fresh preferences enable local live suggestions and the Bean dot;
  diagnostics remain Off.
- Fresh preferences show Automatic provider checks: Off.
- Pausing after typing makes no provider request with defaults.
- “Disable automatic AI checks” turns off passive, provider inline, fallback,
  and web inline paths while preserving explicit actions.
- Reach the daily automatic-call limit, clear usage/history, and confirm the
  visible ledgers clear while today's private limit remains reached.
- If private accounting is unavailable or corrupt, AI & Usage shows a warning
  instead of reporting a misleading zero; automatic provider checks fail closed.
- Clear usage/history with a request in flight, then let it finish; neither
  visible ledger may be recreated by the late result.
- Explicit native AI actions and browser field-control **Proofread** / **Rewrite**
  remain available after the automatic cap and are recorded as manual calls; the paragraph
  **Fix Paragraph** path remains automatically capped.
- Diagnostics are off by default and contain no source or output text when on.
- API keys never appear in UserDefaults, Application Support, logs, diagnostics,
  browser storage, packaged resources, or Git history.
- Writing Context items and dictionary terms are sent only when relevant to the selected
  action as documented in [PRIVACY.md](PRIVACY.md).

## Browser extension gate

- A fresh install enables local checks across ordinary websites and has no
  blocked sites. Deeper AI remains governed by the Bean app's provider and
  browser-AI settings; the extension has no redundant global switch.
- Saving an exact blocked hostname stops Bean there immediately and excludes
  that hostname and its subdomains from future registration.
- Reloading an ordinary, unblocked site activates plain text inputs, textareas,
  and simple contenteditable editors.
- **Disable on this field** stops Bean on that DOM field for the page session;
  **Disable on this website** persists the current hostname in the blocklist.
- Disable two fields, return to each one, and verify its own **Re-enable**
  control restores that field only. A failed blocklist write must leave Bean
  active and announce that the website could not be blocked.
- Activating the single Bean field control opens review and writing actions,
  including selected/draft/paragraph scope, local obvious fixes, Learn word,
  pause and disable controls.
- Activate issue underlines and the field control with VoiceOver/AXPress as well
  as pointer, Enter, and Space. Next, Ignore, Apply, and Review one by one must
  keep a sensible focus target or return focus to the source field.
- Password, search/ARIA-search, email, one-time-code, card-number,
  numeric-secret, read-only, and code fields plus Google Docs canvas are skipped.
- Local checks work with no native host and make no network request.
- Missing native spelling, unavailable language services or bounded/invalid
  scans show Basic/limited coverage. Zero findings never becomes an error-free
  claim. Verify configured dialect and learned words in both native and browser
  results; a word after many protected spans must remain protected.
- Learn word requires real Bean UI activation and an exact spelling occurrence;
  a page-created event cannot save it. Missing GUI/native bridge or a failed
  dictionary write must report failure. A subsequently saved GUI preference
  must not overwrite the learned term.
- Pause the exact website for one hour, relaunch/reload, Resume via popup or
  Options and verify expiry resumes an open draft without reload. Permanent
  blocking remains separate and includes subdomains. No paused/blocked-page
  text may cross the automatic bridge or produce a duplicate native control.
- Automatic provider checks require a compatible local bridge, a configured
  provider, and **Allow deeper AI checks from the browser** in the Bean app.
- Sender hostname and field type are validated inside the extension, then
  omitted from the native payload. Provider prompts use only Bean's fixed
  `Browser` / `web editor` labels.
- Applying an issue verifies the exact live substring and preserves line breaks.
- Options reports all-site coverage, lists blocked websites, and saves changes
  automatically.
- An unsafe explicit Proofread/Rewrite result remains unapplied with a compact
  notice. The legacy review-required automatic paragraph route retains its
  approval gate; routine explicit actions do not require a comparison window.
- **Check again** reports the automatic daily-call count and limit.
- Automatic browser checks and **Fix Paragraph** stop at the reported automatic
  limit. Explicit field-control **Proofread** and **Rewrite** remain available
  with a verified provider and bridge even when automatic checks are off or capped;
  local issue application remains available.
- **Check again** reaches a final Connected/Error state within seven seconds;
  it never remains on Checking indefinitely.
- Settings discovers a loaded Bean extension and Connect/Repair writes an exact
  per-user host manifest without Terminal.
- In Slack desktop, click the composer and type at least two characters before
  choosing Bean → Help → Check Current Field. The report should identify the
  guarded Slack typing fallback; clicking Bean's menu must not erase that evidence.

Use `BrowserExtension/test/fixtures/editor.html` for deterministic manual cases.

## Update and navigation gate

- Settings has exactly five primary destinations: General, Writing, AI & Usage,
  Browser, and Privacy & Help. Personalization lives within Writing.
- Troubleshooting details, field metadata, and operation history appear only
  inside Advanced diagnostics; the menu bar keeps only everyday actions.
- First launch shows the guided onboarding flow. Closing it early does not mark
  onboarding complete, and **Finish Setup** closes the completed setup to the
  menu-bar experience without opening Writer.
- Native one-hour and Until Resumed app pauses persist across relaunch and stop
  automatic native checks and browser suggestions. The focused extension
  refreshes content-free app status every five seconds; once paused, it must not
  scan/read drafts automatically or authorize automatic text sends. Resume is reachable from menu bar or
  Writing settings; an expired pause is not listed as active. Manual native
  shortcuts and explicit browser provider actions remain available. Browser
  local fallback Proofread may offer its basic deterministic checks while Mac
  automatic checking is paused.
- English dialect is shared by native and bridge checks. Canadian, US and UK
  conventions preserve already-valid regional spellings and saved vocabulary;
  confident non-English text must not be forced through English-only rules.
- Ignore an occurrence, change unrelated writing and re-check: that occurrence
  stays dismissed when exact mapping remains provable; an ambiguous new
  occurrence must not inherit the dismissal.
- Launching and leaving Bean idle makes no GitHub update request.
- Clicking **Check for Updates** shows the installed version and newest
  non-draft GitHub release, including its prerelease status.
- Offline, rate-limited, malformed, and empty responses produce an actionable
  error and leave the rest of Settings usable.
- The release button is offered only for an HTTPS URL below
  `github.com/aneesio/bean/releases/` and opens the browser without downloading
  or installing an asset.

## Support and full-reset gate

Use a disposable macOS account or a purpose-built test profile. Never run the
manual reset gate against personal API keys, personalization, or browser data.

- Privacy & Help shows repair cards only for actionable setup findings. An
  optional, absent browser extension must not be presented as a broken setup.
- **Copy Diagnostics Summary** copies only the diagnostics block and does not
  open GitHub. **Preview Support Report** shows the complete report before any
  clipboard or browser action.
- Simulate failed pasteboard and GitHub-open results. Neither action may show
  success, and each error must remain visible in the surface where it occurred.
- After a successful copy, the preview says the report was copied but not saved
  or sent; it must no longer claim that Bean never copied it.
- Opening the GitHub bug form does not copy, save, or upload the report. Copying
  the report does not open a browser. Review both clipboard payloads for source
  text, transformed text, prompts, API keys, clipboard content, and field labels.
- Diagnostics use current Writing Context/Live suggestions names, classify the
  active style as a canonical built-in or `custom`, and omit custom profile
  names, personalization text, full app/native-host paths, hostnames, and field
  labels.
- About shows Bean 1.7.0 (17), identifies the community-supported public beta,
  and opens only the canonical `aneesio/bean` GitHub, Support, Privacy, License,
  Changelog, and manual update-check destinations. At the minimum width and
  larger Accessibility text sizes, links reflow and **Open Update Check…** lands
  on the visible Updates section in General.
- Cancel **Full Reset Bean…** and verify nothing changes.
- Both visible **Clear usage and operation history** controls require a
  destructive confirmation and preserve today's private automatic-call count.
- On a disposable profile, confirm Full Reset removes both provider Keychain
  entries, all Bean user-content artifacts/generated backups, visible usage and
  operation history, private automatic-call state, onboarding/preferences,
  launch-at-login registration, exact `com.bean.nativehost.json` manifests, and
  Bean's manual extension approval. Unrelated Keychain items, preference
  domains, files, browser profiles, extensions, and neighboring native hosts
  must remain untouched.
- A successful reset quits Bean. Reopen it and verify Welcome appears with safe
  defaults. A failed cleanup must keep Bean open, name the failed area, list any
  protected steps not attempted, and never say the reset completed.
- Accessibility authorization remains until the tester removes or disables Bean
  in System Settings → Privacy & Security → Accessibility. The Chrome extension
  and its local settings/blocked-sites list also remain until cleared or removed
  in the browser. Reset copy must state both boundaries.

## Release artifact gate

Create an explicitly unnotarized public-beta artifact with:

```bash
BEAN_ALLOW_ADHOC_RELEASE=1 ./scripts/package_release.sh
```

Verify:

- the app is universal (`arm64` and `x86_64`);
- the ZIP and DMG names include `-unnotarized`;
- filenames also include build 17; packaging must refuse overwriting an already
  committed build, while an interrupted/failed package can be retried safely;
- the SHA-256 file matches both artifacts;
- the app contains current README, TESTING, QA_TEST_PLAN, SUPPORT, PRIVACY, LICENSE, CHANGELOG,
  and extension resources;
- the repository remains clean except for intended source changes;
- installation from the DMG preserves shortcuts, Keychain access, and settings;
- local installer tests use private signed app copies, never `/Applications`,
  and cover upgrade, rollback, signature rejection, concurrency and interrupted
  publication. Run `./scripts/test_local_install.sh build/Bean.app` before
  claiming that evidence. Preserve the installed app if Bean/native hosts are
  running; verify backups before publishing a replacement;
- app/build/changelog/tag versions match, and the extension version was
  incremented when extension code changed;
- README, Privacy, DMG, and release notes consistently identify the artifact as
  an unnotarized prerelease and describe browser/provider-cost behavior.

Developer ID releases must additionally pass notarization, stapling, and
Gatekeeper assessment. The packaging script fails closed when those credentials
are incomplete. Developer ID signing/notarization is explicitly postponed for
this local candidate; strict ad-hoc signature verification is not notarization.

## Performance and evidence gate

Use Writing → Advanced → Copy Performance Summary after synthetic typing and
acceptance journeys. Counts and timings are content-free, bounded, in memory
only, and separate local analysis, typing-pause feedback, acceptance and provider
work. Browser Settings diagnostics also include bounded worker-memory analysis,
last-committed-edit-to-feedback and acceptance timings. Capture sample counts,
supported-path outcomes, cache behavior and idle/
typing CPU work; do not combine provider latency with local feedback latency.

For an explicitly selected Bean process, `./scripts/profile_bean_runtime.sh PID 15`
records content-free CPU/RSS samples. Record idle or synthetic typing
activity separately; the script does not inspect fields or generate typing.

The roadmap's proposed p95 goals are local feedback within 750 ms of committed
input and simple confirmed acceptance within 500 ms. Detector-only and owned
editor-model timings exclude AX/clipboard/UI transport and do not establish
these goals. The 97% precision, 90% common spelling recall, 99.5% confirmed edit
success and zero critical wrong-target/data-loss goals also need independent
evidence on declared supported paths; grammar recall and preferred correction
accuracy are separate measures. Keep missing manual, provider and profiling
evidence open in [SYSTEM_WIDE_IMPLEMENTATION.md](docs/qa/SYSTEM_WIDE_IMPLEMENTATION.md).


### Compact status dot regression (build 17)

Use crowded native and browser composer fixtures with Send, attachments,
microphone and scrollbar controls. Verify the 10-point paint has no logo, pill or
visible count, while its complete 28-point pointer target stays outside the
editor and clear of controls. Move neighboring controls without editing text;
change focus between two fields with identical bounds; scroll, resize and zoom.
Missing geometry and a full-window editor must hide the dot rather than move it
over content. Check brown/amber status in light/dark appearance, hover details,
click/keyboard review, and source focus. The older native launcher must obey the
same rules, including dragging only into verified space. Browser ownership must
remain with visible underlines/cards when the dot cannot fit.
