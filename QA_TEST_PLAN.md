# Bean 1.6.0 Public Beta QA Test Plan

This plan verifies the system-wide writing pass for Bean **1.6.0
(build 11)** and Bean for the Web **0.7.2**. It complements the shorter recurring
checklist in [TESTING.md](TESTING.md). Use this document for release-candidate
sign-off and regression testing after a relevant change.

Local live checks and field-side actions are enabled by default. Safe Proofread
and Rewrite actions replace the unchanged source directly; paid background AI
remains opt-in. Use [SUPPORTED_APPS.md](SUPPORTED_APPS.md) for capability limits,
especially rich-document selection and plain-text whole-field replacement.

## Release decision

A candidate is ready for a public GitHub prerelease only when:

- every automated gate passes from a clean checkout;
- every P0 and P1 case below passes, with no unexplained intermittent result;
- the five reference surfaces have a recorded live result on the candidate app;
- the exact installed app is the app staged in the ZIP and DMG;
- all known limitations are truthful in the UI, support matrix, and release notes;
- no real writing, API key, clipboard content, or other personal data appears in
  test evidence.

P0 means privacy, data loss, unintended provider spend, unsafe replacement, or
an unusable release artifact. P1 means a broken core workflow or misleading
recovery state. P2 means a non-blocking usability or visual defect.

## Test record

Record the following with each run:

| Field | Value |
| --- | --- |
| Commit | |
| App version/build | 1.6.0 (11) |
| Extension version | 0.7.2 |
| macOS version / hardware | |
| Browser and version | |
| Field type / selection or whole field / native or extension path | |
| Spelling language / input method / display setup | |
| Acquisition path | Source / ZIP / DMG |
| Signing mode | Ad hoc unnotarized / Developer ID notarized |
| Tester / date | |
| Automated result | |
| Manual result | |
| System-wide acceptance result | Not run / unverified until a recorded run |
| Open unverified or unsupported cases | |
| Open P2 exceptions | |

For every failure, capture the case ID, expected and actual behavior, exact
synthetic input, app/browser version, and reviewed content-free diagnostics.
Record **Pass**, **Fail**, **User-reported**, **Not run**, or **Unsupported** per
case. A user report, unavailable app, skipped integration test, or successful
plain-text check does not establish a pass for another editor variant.

As of October 2, 2026, the user reports that the manual workflow now works in
Apple Mail, following reports of working shortcuts in ChatGPT, Claude, Slack,
and Chrome's Gmail composer. This is user-reported evidence, not candidate
sign-off. Mail's exact selection/full-field scope, live issues, rich formatting,
attachments, and Undo still need separately recorded runs.

## Environments and fixtures

Use these profiles; do not repurpose a personal profile for destructive cases.

1. **Clean Mac profile:** no Bean preferences, Keychain entries, login item,
   native-host manifest, extension storage, or Accessibility grant.
2. **Upgrade profile:** a backed-up prior Bean release with an API key, custom
   style, Writing Context, dictionary term, usage, and legacy extension settings.
3. **Reset profile:** disposable macOS account containing Bean data plus clearly
   named unrelated Keychain, preference, file, and native-host sentinels.
4. **Browser profile:** unpacked extension loaded from the candidate app, with
   the local fixture, Gmail, and Slack web available.

Use only synthetic samples such as `i has a apple`, `This  has extra spaces.`,
and `The report was completed by the team.` Never use a production API key for
automated tests or attach a real support report to a public issue.

## Automated release gates

Run from the repository root:

```bash
BEAN_DISABLE_SWIFTPM_SANDBOX=1 ./scripts/run_all_tests.sh
BEAN_ALLOW_ADHOC_RELEASE=1 ./scripts/package_release.sh
```

Then verify the exact artifacts:

```bash
codesign --verify --deep --strict --verbose=2 \
  release/Bean-1.6.0-unnotarized/Bean.app
lipo -archs release/Bean-1.6.0-unnotarized/Bean.app/Contents/MacOS/Bean
(cd release && shasum -a 256 -c Bean-1.6.0-unnotarized.sha256)
hdiutil verify release/Bean-1.6.0-unnotarized.dmg
```

Expected: XCTest, standalone logic, extension, shell, metadata, repository, and
credential-history checks all pass; the binary contains `arm64` and `x86_64`;
strict signature and checksums verify; the DMG verifies; release metadata says
app 1.6.0 (11) and extension 0.7.2. Record skipped macOS service or editor
integration tests explicitly; a passing aggregate does not turn a skip into
live compatibility evidence.

## Phase 1 — Activation and onboarding

| ID | Pri | Test | Expected result |
| --- | --- | --- | --- |
| ACT-01 | P1 | Launch in the clean profile from `/Applications/Bean.app`. | Welcome opens automatically, Bean appears in the Dock while its window is open, and the menu-bar item remains available. |
| ACT-02 | P1 | Complete onboarding without selecting a provider or saving a key. | AI setup is visibly optional; local tryout and **Finish Setup** remain available. |
| ACT-03 | P1 | Close onboarding midway, quit, and relaunch. | Bean does not mark setup complete and resumes onboarding safely. |
| ACT-04 | P1 | Use the built-in tryout, then finish onboarding. | Quick Fix runs entirely inside Bean; the ready page explains the real-app shortcut without requiring TextEdit. |
| ACT-05 | P1 | Grant, deny, and later grant Accessibility. Use **Check Again** after each change. | State is accurate, denial is recoverable, and no success is claimed before macOS reports the grant. |
| ACT-06 | P1 | Save and verify one optional provider key. Relaunch Settings several times. | Keychain access is requested only for an intentional key action; opening ordinary Bean windows does not cause repeated password prompts. |
| ACT-07 | P1 | Open Settings, About, onboarding, and the Bean menu; close the final Bean window. | Dock presence follows open Bean windows without quitting the menu-bar app or spawning duplicate instances. |
| ACT-08 | P1 | Invoke the shortcuts displayed in Settings in an editable field; repeat with a saved custom shortcut and with each primary action choice. | Fresh defaults are `⌘⇧G` and `⌃⌥B`; saved shortcuts remain respected. Quick Fix is local, AI Proofread is explicitly provider-backed, and the writing menu retains the captured scope. |
| ACT-09 | P1 | Choose **Help → Check Current Field** on editable and non-editable controls. | The check reads metadata only, reports separate action/replacement/Bubble/inline capabilities, and never records field text. |
| ACT-10 | P2 | Inspect every onboarding page at minimum size, large window size, and larger Accessibility text. | Primary action, progress, explanatory copy, and back/close controls remain visible without clipped critical content. |
| ACT-11 | P1 | After setup, quit and relaunch Bean, then invoke a writing action from another app. | Bean stays in the menu bar; assistance works in the source app without opening Bean Writer. |

## Phase 2 — Correction trust and recovery

| ID | Pri | Test | Expected result |
| --- | --- | --- | --- |
| TRU-01 | P1 | Quick-fix `Please fix teh  draft.` in selected-text and focused-field modes; separately AI-proofread `i has a apple`. | Local Quick Fix applies proven typo/spacing rules without a provider; AI Proofread handles grammar through the configured provider. Neither result includes labels, analysis, commentary, or model thoughts. |
| TRU-02 | P1 | Run Quick Fix on an already-correct sentence. | Text is not needlessly replaced; the UI gives a clear no-change result. |
| TRU-03 | P0 | Feed fixtures containing markdown fences, `Revised text:`, prompt leaks, commentary, scripts, or an empty response. | Hard-blocked output never reaches replacement or clipboard fallback. |
| TRU-04 | P0 | Trigger suspicious length, fact, question-shape, or language changes in direct Proofread/Rewrite. | Unsafe output is blocked and the source remains untouched; these actions do not require a routine before/after approval window. Generative reply/compose retain their separate draft review. |
| TRU-05 | P1 | Make target validation or normal Paste fail while a safe correction exists. | A truthful recovery notice offers Copy Result and Return to Writing; no comparison window is required and no unverified result is called fixed. |
| TRU-06 | P0 | Change the field contents or selection while a provider request is running. | Stale replacement is refused and the result remains recoverable without overwriting newer text. |
| TRU-07 | P0 | Force verified-paste failure and inspect the clipboard before and after. | Success is claimed only after verification; ordinary replacement restores the prior clipboard, while explicit fallback accurately says the correction was copied. |
| TRU-08 | P1 | Run clearer, concise, professional, and casual rewrites in selected-text and plain whole-field modes. | Each applies directly to the unchanged source and preserves text outside the intended scope. Confirmed edits offer Bean Undo only when a safe undo path exists. |
| TRU-09 | P1 | Run reply/compose actions against an existing message. | Draft is copy-first and never replaces the source message. |
| TRU-10 | P0 | Replace a whole field, use **Undo Last Bean Change**, then repeat after editing the field or waiting beyond the undo window. | Fresh matching replacement is restored from memory; stale or mismatched fields are refused; original text is never persisted. |

## Phase 3 — Cost, limits, and provider boundaries

| ID | Pri | Test | Expected result |
| --- | --- | --- | --- |
| CST-01 | P0 | Start with clean preferences and type normally for several minutes. | Automatic provider features are off and no paid request occurs. |
| CST-02 | P0 | Run Quick Fix and local live checking with no key and with network blocked. | Proven local fixes and available macOS spelling suggestions work without a provider session. Ambiguous spelling remains a user choice; unavailable spelling is not reported as a complete clean review. |
| CST-03 | P1 | Complete one OpenAI and one Anthropic manual operation using disposable keys or mocked responses. | Reported input/output usage is decoded; unavailable usage is clearly marked estimated. |
| CST-04 | P0 | Enable each automatic source, set the daily cap to three, and attempt concurrent passive/native/web work; then explicitly invoke native and extension Proofread/Rewrite. | Exactly three automatic attempts can reserve capacity; later automatic attempts stop locally. Trusted explicit actions remain available and record manual usage separately without spending automatic capacity. |
| CST-05 | P0 | Reach the cap, clear visible usage/history, and retry automatic work. | Visible history clears but the private same-day cap remains reached. |
| CST-06 | P0 | Corrupt or make private accounting unavailable. | Paid automatic work fails closed; the UI reports accounting unavailable rather than zero and offers **Check Accounting Again** plus truthful last-resort reset guidance. |
| CST-07 | P0 | Clear usage while a request is in flight, then let it settle. | A late result cannot repopulate cleared visible ledgers or restore capacity. |
| CST-08 | P1 | Cross the configured 30-day token warning threshold. | Dashboard labels the estimate as approximate, identifies the threshold, and does not claim provider billing accuracy. |
| CST-09 | P0 | Submit provider text at and above the shared maximum input size through manual, passive, native-inline, and browser paths. | Allowed input is bounded; oversized input is rejected before provider creation or budget reservation. |
| CST-10 | P1 | Select **Disable automatic AI checks**. | Passive provider work, provider inline fallback, and web AI turn off together; local/manual actions remain available. |

## Phase 4 — Field compatibility and false-positive control

Run each row with current-field diagnostics before and after the action.

| ID | Surface | Selected/focused action | Bubble | Inline expectation |
| --- | --- | --- | --- | --- |
| CMP-01 | TextEdit editor | Direct verified correction | Editor only | Native highlight or documented range fallback |
| CMP-02 | Apple Notes note body | Preserve note structure | Editor/best effort | Exact native underlines where exposed; field-side cards otherwise |
| CMP-03 | Apple Mail composer | Record selected passage and plain whole-field behavior separately; preserve unrelated greeting/signature | Composer only | Exact native underlines where supported; field-side cards otherwise; user-reported manual success is not a live-issues pass |
| CMP-04 | Slack desktop composer | Capability-based guarded paste; recent click + typing evidence only for the AX-free fallback | Editable composer or verified typing anchor | Native positions where exposed; floating cards otherwise; no guessed underline geometry |
| CMP-05 | Chromium plain input, textarea, and simple Gmail contenteditable; separately Slack web | Extension path on supported fields; native/manual path only when the control can be verified | One control for an extension-owned field | Local extension checks by default; complex Slack web remains an unverified/unsupported extension variant per the support matrix |

The following control-boundary checks are P0 for secure data and P1 otherwise:

| ID | Target | Expected result |
| --- | --- | --- |
| CMP-06 | Native secure/password control and DOM password control | No read, correction, Bubble, or inline marker. Do not infer that an ordinary native text field is secure merely from its app name. |
| CMP-07 | Disabled or read-only field | No focused replacement, Bubble, or inline marker. |
| CMP-08 | Native search, browser address, and email-address controls | Evaluate the actual editable control; preserve queries, URLs, and technical tokens. Field-button preferences apply. The Chromium extension still excludes search/address/email DOM inputs. |
| CMP-09 | Ordinary button, toolbar item, static label | No Bean icon and no text action. |
| CMP-10 | Native code-app text control; separately browser code editor and Google Docs canvas | Native editable controls are eligible with technical-token protection and exact bounds; no blind whole-document capture. Unsupported DOM code/canvas targets are skipped; unreadable controls are never presented as clean. |
| CMP-11 | Field moves, disappears, or loses focus during action | Bean revalidates the target and declines stale geometry/replacement. |
| CMP-12 | DOM one-time-code, card-number, numeric-secret, telephone, or numeric-only input | The extension performs no text inspection, correction, or field control. Record native unmarked secret-field behavior separately; the DOM exclusions do not prove a native exclusion. |

### Focused system-wide acceptance pass

Run these cases first in a disposable TextEdit document and Mail draft, then in
Notes, one Electron composer, a browser textarea, and a simple contenteditable
fixture. Never send the test email or message. Record each app/field/path
separately; these are expected acceptance outcomes, not claims that the current
candidate has passed. Unsupported geometry may use cards, but an unreadable
field must not be called clean.

| ID | Pri | Setup and action | Expected result / evidence to record |
| --- | --- | --- | --- |
| SYS-01 | P0 | Put `Please fix teh draft.` between an unrelated greeting and signature. Select only the sentence and run Quick Fix, AI Proofread, then each rewrite on restored fixtures. | Only the selected passage changes; greeting/signature, surrounding whitespace, and other fields remain exact. Safe actions apply without a comparison window and return focus to the editor. |
| SYS-02 | P0 | Collapse the caret at the start, middle, and end of a plain draft; run each direct action with focused-field fallback enabled, then disabled. | Enabled mode captures only the active field; disabled mode leaves it untouched and reports the missing selection. A caret never masquerades as a selected line or whole document. |
| SYS-03 | P0 | Put the same typo in two fields, then select the second `teh` in `teh draft and teh signature`. Change selection to the first occurrence during a delayed result. | The captured destination is revalidated. A changed marker/range is refused even when selected strings match; no first-occurrence guess, wrong-field replacement, or unsupported Undo is offered. |
| SYS-04 | P0 | Use `👩🏽‍💻 Please fix teh draft.` and a later second typo; accept one issue, then the next. Repeat with composed/decomposed `café`, combining accents, and mixed line endings. | Exact UTF-16 spans identify the intended occurrence; emoji/accents and untouched code units are preserved. Normalization changes during a delayed request invalidate the old snapshot instead of passing as identical text. |
| SYS-05 | P0 | Select a short passage in rich Mail/Notes content surrounded by bold/italic text, a link, list, signature, quoted reply, and a synthetic attachment. Apply a correction and rewrite separately. | Unselected formatting, links, attachments, and quoted content survive. Record formatting inside the edited passage separately; matching plain text alone does not establish rich-format preservation. |
| SYS-06 | P1 | Attempt a whole-field action on the same rich fixture, including a document-style WebKit editor without a numeric selection API. | Current whole-field support is plain text; rich preservation remains an open compatibility item until demonstrated. Unsupported document-wide replacement declines safely, and an individual card must not flatten the rich document to change one word. |
| SYS-07 | P0 | Before an edit, copy synthetic styled text or an image. Repeat while copying a different item during activation, Copy validation, Paste, and the delayed clipboard restore. | Ordinary edits restore all prior clipboard types; a newer user Copy survives. Recovery states accurately distinguish a copied result from a preserved clipboard and never claim an unverified edit succeeded. |
| SYS-08 | P1 | Place the caret before and after a typo; accept a length-changing correction. Move the caret or click elsewhere immediately after Paste. | A supported caret-restoration path maps the original position around the edit without overriding newer navigation. Otherwise record the editor's native caret behavior as an explicit limitation. |
| SYS-09 | P0 | Apply a confirmed plain-text edit and use Bean Undo and the source app's native Undo on separate fixtures. Repeat after more typing, switching fields, app closure, expiry, and a marker-only edit. | Undo never overwrites newer writing or another field. Bean Undo appears only for a safe stored edit; marker-only selection must not trigger whole-document restoration or reuse an older undo record. Check native Undo and rich structure independently. |
| SYS-10 | P0 | During a delayed request, type, paste, switch apps, focus another field, close the draft, and replace the editor node/window. Repeat with a selection that remains visually identical. | Stale source/focus/identity causes a safe decline. No keystroke, clipboard correction write, or paste goes to the new target; diagnostics identify the content-free failure reason. |
| SYS-11 | P1 | Apply several issues consecutively, including spacing and punctuation deletion where offered; then request a rewrite. | Remaining issue ranges remap to the exact current text; no duplicate Paste, stale underline, orphan card, or false success appears. The editor's input model and native Undo observe normal edits. |
| SYS-12 | P1 | Type `okay lets see if it works in the email this tme`, `another misspeling`, and `writting`; add names, dictionary phrases, URLs, identifiers, and quantities as controls. | Available macOS spelling finds ordinary typos beyond the small deterministic list. Contextual suggestions and alternatives are plausible; ambiguous guesses require choice. Protected tokens and facts are not rewritten merely to increase the issue count. |
| SYS-13 | P1 | Check an already-correct draft, then stop the Mac spelling connection and repeat with an unreadable editor. | Empty issue lists do not imply error-free text. Basic, unavailable, checking, and supported local states are truthful; a stalled/unreadable path does not display a complete clean result. |
| SYS-14 | P1 | Focus an eligible native field with issues, then the same page field with the extension active. Disable the extension on that field, disconnect/reconnect the bridge, and let ownership expire. | One actionable Bean field control appears per active owner; no overlapping native/extension buttons or conflicting cards. Native browser toolbar/address assistance is not suppressed by page ownership. |
| SYS-15 | P1 | Scroll, resize, move a window between displays, change display scaling, attach/detach a display, and test browser zoom at 100%/200%. | Underlines track exact ranges where available; cards stay visible and anchored. Missing geometry uses a truthful fallback, with no offscreen controls, stale hit targets, or guessed highlights. |
| SYS-16 | P0 | Compose with an IME, accents/dead keys, and an RTL input method; pause with marked text, then commit and request a correction. | Background checks do not alter or interrupt composition. Edits act only on committed, revalidated text; record language-specific spelling and editor support rather than assuming English behavior. |
| SYS-17 | P0 | Dictate a synthetic draft, including interim revisions; stop dictation and proofread. Repeat with paste and programmatic input instead of key events. | Checks follow the latest committed field value without requiring a particular keyboard event. No old interim result replaces later dictation; focus and dictation remain usable. |
| SYS-18 | P1 | Check fields just below/above native live-check and provider limits, plus long single lines and newline-rich browser drafts. | Native live work is bounded to 50,000 characters and manual provider input to 8,000 with byte limits. Oversized/partially checked input has a truthful state and a smaller-selection path; no hidden whole-document capture or silent clean verdict. |
| SYS-19 | P1 | After relaunch, first-focus a prefilled draft with `teh` and an unlisted misspelling without typing. Immediately open native review/local checking before any issue cache exists. Repeat on another field with identical text. | The latest focused snapshot is actually analyzed, with a checking state while work is pending. A cache miss is not a clean result or a silent early return; another field's cached result and geometry are not reused. |
| SYS-20 | P1 | First establish a clean cached result, then introduce a typo by paste/programmatic input. Immediately request review before the typing pause settles; repeat after an issue was previously cached and the draft becomes clean. | Each new text revision invalidates the prior result and checks the current snapshot. Clean caches do not hide new issues, and old issues do not survive a fresh clean check. Record cold-cache, clean-cache, and detected-cache results separately. |

The following are **proposed development goals, separate from candidate
sign-off**, not measured results or current product guarantees. Collect a
baseline on the agreed synthetic fixtures and record sample size, field path,
hardware, and spelling language before judging them:

- Zero wrong-target edits, outside-scope changes, attachment loss, or newer-user
  clipboard overwrites in the P0 cases.
- At least 97% suggestion precision and 90% recall on seeded common spelling
  errors in an annotated English corpus. Report grammar recall, technical/name
  controls, and ambiguous alternatives separately.
- At least 99.5% confirmed edit success on explicitly supported scenarios;
  record the denominator and safe declines/fault-injection outcomes separately.
  Measure primary replacement accuracy against the intended correction as a
  separate quality result; offering a correct alternative does not make a
  wrong primary replacement correct.
- Local feedback at the 95th percentile within 750 milliseconds of the last
  committed input on ordinary short fields, and a confirmed simple acceptance
  within 500 milliseconds. Measure provider latency separately and verify that
  progress appears promptly; current timings have not been measured here.
- One control per owned field and no need to dismiss a comparison window for a
  safe direct proofread/rewrite. Count recovery notices separately from success.

## Phase 5 — Simplicity, browser control, and updates

| ID | Pri | Test | Expected result |
| --- | --- | --- | --- |
| SIM-01 | P1 | Inspect Settings navigation and resize the window. | Exactly General, Writing, AI & Usage, Browser, and Privacy & Help appear; brand tint replaces default blue; important controls are not hidden below an avoidable scroll. |
| SIM-02 | P2 | Open the Bean writing menu at minimum and normal screen sizes. | Primary actions fit the redesigned layout and remain keyboard reachable without a long hidden list. |
| SIM-03 | P1 | Inspect built-in profiles and migrate a profile named `Slack Casual`. | The public built-in is **Casual** and legacy references migrate without losing selection. |
| WEB-01 | P1 | Load the unpacked extension in a fresh browser profile and open an ordinary HTTP/HTTPS page. | Bean works locally by default; there is no redundant global enable switch or approved-sites whitelist. |
| WEB-02 | P1 | Block `example.com`, visit it and a subdomain, then unblock it. | Both are inactive while blocked; removal restores registration after reload. |
| WEB-03 | P1 | Use **Disable on this field** on two separate editors, then re-enable one. | Each field has session-only independent state; website-wide behavior is unchanged. |
| WEB-04 | P1 | Use **Disable on this website** from the Bean icon and simulate a storage-write error. | A successful block persists; a failed write leaves Bean active and announces failure. |
| WEB-05 | P1 | Use pointer, Enter, Space, and VoiceOver/AXPress on issue markers and the single field control: review, Accept/Ignore, Proofread, Clearer/Concise/Professional/Friendly, and Undo. | Controls expose correct roles/names, announce the selection/paragraph/draft scope, and return focus predictably to the editor or next action. |
| WEB-06 | P1 | Install/repair the Mac connection from Bean Settings with no Terminal command. Restart Chrome and choose **Check again**. | Exact manifest is installed and live status reaches Connected or an actionable Error within seven seconds; it never remains Checking indefinitely. |
| WEB-07 | P2 | Inspect browser toolbar, options, and field icon at 100%/200% zoom and light/dark appearance. | Official Bean artwork, legible states, blocked-site controls, and no placeholder dot-in-square icon. |
| WEB-08 | P1 | With no API key and automatic browser AI disabled, check the `tme`/unlisted-typo fixtures through the Mac bridge; repeat with the bridge unavailable. | Connected offline spelling supplies exact UTF-16 issues without paid usage. Disconnected operation retains basic rules and says full spelling is unavailable instead of showing a misleading complete clean state. |
| WEB-09 | P0 | With a verified provider, explicitly click Proofread/Rewrite while automatic browser AI is disabled or its daily cap is reached. Repeat with an untrusted page-triggered request. | The trusted action applies only to its fresh captured scope and records manual usage; automatic work remains gated. Forged or expired text authorization never reaches the provider or DOM replacement. |
| WEB-10 | P0 | Change DOM text, selection, eligibility, or field ownership during offline or provider work; include repeated typos and emoji. | Old results do not mark or replace a changed snapshot. Exact ranges and single-use authorization prevent replay; another field cannot consume the result. |
| WEB-11 | P1 | Keep a provider action pending while changing another eligible field and checking connection/ownership status. | Local checks and ownership remain responsive; responses retain the right request ID and deadline. No field waits indefinitely or acquires duplicate controls behind the provider call. |
| UPD-01 | P0 | Launch and leave Bean idle while monitoring network access. | No update request occurs. |
| UPD-02 | P1 | Click **Check for Updates** with current, newer, prerelease, offline, rate-limited, malformed, and hostile-link fixtures. | State is actionable; only canonical HTTPS `github.com/aneesio/bean/releases/` pages can be opened; Bean downloads or installs nothing. |

## Phase 6 — Personalization, support, privacy, and reset

| ID | Pri | Test | Expected result |
| --- | --- | --- | --- |
| PER-01 | P1 | Create, edit, duplicate, select, and delete custom styles; exercise all four scales and live preview. | Changes persist, built-ins remain canonical, invalid references repair predictably, and every persistence failure leaves the prior state clear. |
| PER-02 | P1 | Add/edit/delete Writing Context, dictionary terms, case sensitivity, and per-app defaults. | Limits, normalization, duplicates, app matching, and active/default labels behave consistently after relaunch. |
| PER-03 | P0 | Export preferences, review an import, confirm it, and inspect the automatic pre-import backup. | Nothing changes before confirmation; exact prior state is recoverable; repairs/skipped duplicates are disclosed. |
| PER-04 | P0 | Import malformed, future-version, duplicate-heavy, symlinked, non-regular, sparse, and over-2-MB files. | Preview rejects them before mutation or unbounded main-thread allocation; no safety backup is falsely claimed. |
| PER-05 | P0 | Force import persistence failure and rollback failure separately. | Successful rollback says current data is unchanged; failed rollback gives distinct recovery instructions and never makes that claim. |
| SUP-01 | P1 | Choose **Copy Diagnostics Summary**, then separately **Preview Support Report**. | Copy contains only the diagnostics block; preview is visible before any clipboard/browser action and is not saved or uploaded. |
| SUP-02 | P0 | Review support data with custom names, hostnames, field labels, app paths, keys, and synthetic source/output present elsewhere. | Report uses bounded/coarse metadata and excludes all those sensitive values, prompts, clipboard contents, and writing. |
| SUP-03 | P1 | Simulate failed clipboard write and failed GitHub open from support preview. | Failure stays visible; neither action claims success; copying never opens GitHub and opening GitHub never copies. |
| SUP-04 | P1 | Trigger each repair card: Accessibility, unstable app path, duplicate instance, and broken Mac browser connection. | Only actionable cards appear, language matches the actual button names, and an absent optional extension is not called broken. |
| RST-01 | P0 | Open **Full Reset Bean…** and cancel. | No state changes. |
| RST-02 | P0 | Confirm Full Reset in the disposable reset profile. | Exact Bean keys, content/backups, accounting, preferences, onboarding, login item, native-host manifests, and manual approvals are verified removed; Bean quits only after success. |
| RST-03 | P0 | Fail each reset stage in turn with injected fixtures. | Bean remains open, identifies completed/failed/not-attempted areas, and never claims full success. |
| RST-04 | P0 | Inspect unrelated Keychain items, files, preference domains, browser profiles/extensions, and neighboring native hosts after reset. | Every sentinel remains byte-for-byte unchanged. |
| RST-05 | P1 | Reopen after successful reset. | Guided onboarding returns with optional AI and safe feature defaults. Accessibility and extension storage remain, with truthful instructions for manual removal. |
| SEC-01 | P0 | Install/uninstall the native host with intermediate-directory symlinks, unsafe manifests, and unrelated neighboring files. | Scripts fail closed, never traverse redirected ancestors, and preserve all sentinels. |
| SEC-02 | P0 | Invoke native-host mode from an unsigned process and binaries spoofing allowed identifiers/team metadata. | Host rejects them; only a live Apple-anchored, exact allowlisted browser identity can enter native-host mode. |
| SEC-03 | P0 | Inspect browser-to-host payloads and persisted ledgers. | Hostname/field semantics are omitted; provider receives fixed Browser/web-editor context; content-free records are sanitized, bounded, lock-safe, and retention-limited. |
| DOC-01 | P1 | Open About and every project/support/privacy/license/changelog/update destination. | Version/build and public-beta status are truthful; links are canonical and reflow at large text sizes. |

## Cross-cutting accessibility and visual QA

| ID | Pri | Test | Expected result |
| --- | --- | --- | --- |
| A11Y-01 | P1 | Navigate onboarding, menu, Settings, sheets, recovery previews, About, and extension UI using keyboard only. | Focus order follows visual order; every action is reachable; Escape/Cancel is predictable; destructive default focus is avoided. |
| A11Y-02 | P1 | Repeat primary flows with VoiceOver. | Controls have concise names, state/value, and hints; success/error changes announce once; decorative artwork is hidden. |
| A11Y-03 | P2 | Test light/dark appearance, Increase Contrast, Reduce Motion, and larger text. | Brand color retains readable contrast, information is not color-only, animation is nonessential, and primary content does not clip. |
| VIS-01 | P2 | Compare spacing, typography, button hierarchy, empty/error/loading states, and window behavior across every page. | One consistent Bean visual system is used; troubleshooting is progressively disclosed; no developer-only copy is exposed. |

## Upgrade and persistence regression

| ID | Pri | Test | Expected result |
| --- | --- | --- | --- |
| UPG-01 | P0 | Upgrade the prepared prior-release profile in place. | API key, shortcuts, personalization, and safe settings remain; no repeated Keychain prompts or onboarding loop. |
| UPG-02 | P1 | Upgrade legacy all-site/approved-site extension storage. | Local checks default to all ordinary sites, valid blocked sites migrate, and removed redundant switches cannot silently disable everything. |
| UPG-03 | P0 | Replace `/Applications/Bean.app` while preserving a backup, then launch. | One candidate instance runs, version is 1.6.0 (11), native host points to the installed executable, and rollback remains possible. |
| UPG-04 | P1 | Roll back using the preserved app backup without deleting user data. | Prior app launches; the rollback path and any expected settings-version limitation are recorded. |

## Artifact and GitHub prerelease QA

| ID | Pri | Test | Expected result |
| --- | --- | --- | --- |
| REL-01 | P0 | Compare plist, command-line fallback, changelog, extension manifest, artifact name, and intended tag. | App 1.6.0 (11), extension 0.7.2, and the intended 1.6.0 prerelease metadata agree; record the exact build because version-only artifact names do not distinguish rebuilds. |
| REL-02 | P0 | Mount the DMG and drag Bean to `/Applications`. Launch through the documented unnotarized flow. | Volume layout is understandable; warnings match the GitHub-beta documentation; app launches after explicit user approval. |
| REL-03 | P0 | Inspect staged resources. | Current README, TESTING, QA plan, SUPPORT, SUPPORTED_APPS, PRIVACY, LICENSE, CHANGELOG, extension, native-host scripts, icons, and Info.plist are present. |
| REL-04 | P0 | Download the GitHub prerelease artifacts into a new directory and verify SHA-256. | Published bytes match checksums and local release candidate; release remains marked prerelease. |
| REL-05 | P1 | Follow README installation, onboarding, browser connection, troubleshooting, and rollback instructions as a nontechnical user. | No Terminal step is required for normal use; every named UI control exists and instructions disclose API cost and Gatekeeper status. |

Developer ID candidates add `spctl`, notarization submission, stapling, and
ticket validation. Do not describe an ad-hoc build as notarized or suppress its
`-unnotarized` artifact suffix.

## Sign-off

| Role | Name | Date | Result / exceptions |
| --- | --- | --- | --- |
| Engineering automated gate | | | |
| Product/visual QA | | | |
| Accessibility QA | | | |
| Privacy/security review | | | |
| Five-surface compatibility | | | |
| Release artifact verification | | | |

Any accepted P2 exception must have a GitHub issue, a user-visible workaround,
and no conflict with current documentation. P0 and P1 failures cannot be waived
for a public release.
