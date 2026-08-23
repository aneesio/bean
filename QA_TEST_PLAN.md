# Bean 1.6.0 Public Beta QA Test Plan

This plan verifies the six-phase public-release overhaul for Bean **1.6.0
(build 8)** and Bean for the Web **0.7.0**. It complements the shorter recurring
checklist in [TESTING.md](TESTING.md). Use this document for release-candidate
sign-off and regression testing after a relevant change.

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
| App version/build | 1.6.0 (8) |
| Extension version | 0.7.0 |
| macOS version / hardware | |
| Browser and version | |
| Acquisition path | Source / ZIP / DMG |
| Signing mode | Ad hoc unnotarized / Developer ID notarized |
| Tester / date | |
| Automated result | |
| Manual result | |
| Open P2 exceptions | |

For every failure, capture the case ID, expected and actual behavior, exact
synthetic input, app/browser version, and reviewed content-free diagnostics.

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
app 1.6.0 (8) and extension 0.7.0.

## Phase 1 — Activation and onboarding

| ID | Pri | Test | Expected result |
| --- | --- | --- | --- |
| ACT-01 | P1 | Launch in the clean profile from `/Applications/Bean.app`. | Welcome opens automatically, Bean appears in the Dock while its window is open, and the menu-bar item remains available. |
| ACT-02 | P1 | Complete onboarding without selecting a provider or saving a key. | AI setup is visibly optional; local tryout and **Start using Bean** remain available. |
| ACT-03 | P1 | Close onboarding midway, quit, and relaunch. | Bean does not mark setup complete and resumes onboarding safely. |
| ACT-04 | P1 | Use the built-in tryout, then finish onboarding. | Quick Fix runs entirely inside Bean; the ready page explains the real-app shortcut without requiring TextEdit. |
| ACT-05 | P1 | Grant, deny, and later grant Accessibility. Use **Check Again** after each change. | State is accurate, denial is recoverable, and no success is claimed before macOS reports the grant. |
| ACT-06 | P1 | Save and verify one optional provider key. Relaunch Settings several times. | Keychain access is requested only for an intentional key action; opening ordinary Bean windows does not cause repeated password prompts. |
| ACT-07 | P1 | Open Settings, About, onboarding, and the Bean menu; close the final Bean window. | Dock presence follows open Bean windows without quitting the menu-bar app or spawning duplicate instances. |
| ACT-08 | P1 | Invoke `⌘⇧G` and `⌃⌥B` in an editable field. | Shortcuts match the displayed labels and lead to Quick Fix and the writing menu respectively. |
| ACT-09 | P1 | Choose **Help → Check Current Field** on editable and non-editable controls. | The check reads metadata only, reports separate action/replacement/Bubble/inline capabilities, and never records field text. |
| ACT-10 | P2 | Inspect every onboarding page at minimum size, large window size, and larger Accessibility text. | Primary action, progress, explanatory copy, and back/close controls remain visible without clipped critical content. |

## Phase 2 — Correction trust and recovery

| ID | Pri | Test | Expected result |
| --- | --- | --- | --- |
| TRU-01 | P1 | Quick-fix `i has a apple` in selected-text and focused-field modes. | The correction is concise and contains no label, analysis, “all looked good,” footer, or model thoughts. |
| TRU-02 | P1 | Run Quick Fix on an already-correct sentence. | Text is not needlessly replaced; the UI gives a clear no-change result. |
| TRU-03 | P0 | Feed fixtures containing markdown fences, `Revised text:`, prompt leaks, commentary, scripts, or an empty response. | Hard-blocked output never reaches replacement or clipboard fallback. |
| TRU-04 | P0 | Trigger a large but plausibly valid length/question-shape change. | A before/after review appears and the source remains untouched until explicit approval. |
| TRU-05 | P1 | Make direct AX replacement fail while a safe correction exists. | A persistent recovery preview offers Copy, Retry, and Cancel; it never falsely says the text was fixed. |
| TRU-06 | P0 | Change the field contents or selection while a provider request is running. | Stale replacement is refused and the result remains recoverable without overwriting newer text. |
| TRU-07 | P0 | Force verified-paste failure and inspect the clipboard before and after. | Success is claimed only after verification; ordinary replacement restores the prior clipboard, while explicit fallback accurately says the correction was copied. |
| TRU-08 | P1 | Run clearer, concise, professional, and casual rewrites. | Each is preview-first and preserves text outside the intended range. |
| TRU-09 | P1 | Run reply/compose actions against an existing message. | Draft is copy-first and never replaces the source message. |
| TRU-10 | P0 | Replace a whole field, use **Undo Last Bean Change**, then repeat after editing the field or waiting beyond the undo window. | Fresh matching replacement is restored from memory; stale or mismatched fields are refused; original text is never persisted. |

## Phase 3 — Cost, limits, and provider boundaries

| ID | Pri | Test | Expected result |
| --- | --- | --- | --- |
| CST-01 | P0 | Start with clean preferences and type normally for several minutes. | Automatic provider features are off and no paid request occurs. |
| CST-02 | P0 | Run **Local Quick Check** with no key and with network blocked. | Local corrections work and no provider session is created. |
| CST-03 | P1 | Complete one OpenAI and one Anthropic manual operation using disposable keys or mocked responses. | Reported input/output usage is decoded; unavailable usage is clearly marked estimated. |
| CST-04 | P0 | Enable each automatic source, set the daily cap to three, and attempt concurrent passive/native/web work. | Exactly three automatic attempts can reserve capacity; later attempts stop locally and manual native actions remain available. |
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
| CMP-02 | Apple Notes note body | Preserve note structure | Editor/best effort | Native or passive fallback |
| CMP-03 | Apple Mail composer | Preserve greeting and signature | Composer only | Native or passive fallback |
| CMP-04 | Slack desktop composer after click + two typed characters | Electron replacement or honest recovery preview | Recent typing evidence only | Passive/manual; no fake native range highlight |
| CMP-05 | Gmail and Slack web in Chromium | Extension path plus honest AX fallback | Editable DOM only | Extension local checks by default unless blocked |

The following exclusions are P0 for secure data and P1 otherwise:

| ID | Target | Expected result |
| --- | --- | --- |
| CMP-06 | Password, one-time-code, card-number, or numeric-secret field | No read, correction, Bubble, or inline marker. |
| CMP-07 | Disabled or read-only field | No focused replacement, Bubble, or inline marker. |
| CMP-08 | Search field, browser address field, email-address field | No Bubble/inline/focused replacement; explicit safe selection only where policy allows. |
| CMP-09 | Ordinary button, toolbar item, static label | No Bean icon and no text action. |
| CMP-10 | Code editor and Google Docs canvas | No automatic UI unless the documented explicit code setting applies; no guessed geometry. |
| CMP-11 | Field moves, disappears, or loses focus during action | Bean revalidates the target and declines stale geometry/replacement. |

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
| WEB-05 | P1 | Use pointer, Enter, Space, and VoiceOver/AXPress on issue markers, paragraph icon, Next, Ignore, Apply, and Review. | Controls expose correct roles/names and return focus predictably to the editor or next action. |
| WEB-06 | P1 | Install/repair the Mac connection from Bean Settings with no Terminal command. Restart Chrome and choose **Check again**. | Exact manifest is installed and live status reaches Connected or an actionable Error within seven seconds; it never remains Checking indefinitely. |
| WEB-07 | P2 | Inspect browser toolbar, options, and field icon at 100%/200% zoom and light/dark appearance. | Official Bean artwork, legible states, blocked-site controls, and no placeholder dot-in-square icon. |
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
| UPG-03 | P0 | Replace `/Applications/Bean.app` while preserving a backup, then launch. | One candidate instance runs, version is 1.6.0 (8), native host points to the installed executable, and rollback remains possible. |
| UPG-04 | P1 | Roll back using the preserved app backup without deleting user data. | Prior app launches; the rollback path and any expected settings-version limitation are recorded. |

## Artifact and GitHub prerelease QA

| ID | Pri | Test | Expected result |
| --- | --- | --- | --- |
| REL-01 | P0 | Compare plist, command-line fallback, changelog, extension manifest, artifact name, and intended tag. | App 1.6.0 (8), extension 0.7.0, and tag `v1.6.0` agree. |
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
