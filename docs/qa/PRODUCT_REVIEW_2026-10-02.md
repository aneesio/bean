# Product and writing-quality review — October 2, 2026

This working-tree review uses Grammarly's familiar review interaction as a
benchmark: writing remains central, underlines lead to explanations, and users
can accept, dismiss, and undo individual suggestions. It does not establish
model-quality parity with Grammarly or certify every third-party editor.

## Product decisions implemented

- Give Bean a useful primary surface. **Bean Writer** is a native draft editor
  with linked underlines and suggestion cards, counts, a dictionary action,
  correction undo, and UTF-8 text/Markdown open/save.
- Make setup produce immediate value. The Writer needs neither Accessibility
  nor a provider key; setup leads into it. Manual launches and reopening show
  the Writer, while login launches remain quiet.
- Keep writing in the user's control. Deeper review is an explicit AI action;
  rewrites present a suggested version and original comparison before applying.
  Every provider result is bound to the revision that was sent.
- Keep status honest. Local checks describe their limited scope, failed AI
  parsing is reported as a failed review, and large drafts show that live
  checking is paused. There is no invented writing score or tone detector.
- Reduce visual noise in the browser. One field badge opens sequential review;
  thin underline hit targets leave ordinary text selection usable. AI paragraph
  rewrites preview highlighted changes and preserve unresolved local findings.
- Preserve draft ownership. Closing the Writer keeps its current draft in
  memory. Save is explicit, and quitting or changing documents protects
  unsaved writing. User-chosen draft files survive Full Reset.

## Correctness findings and fixes

| Finding | Resulting behavior |
| --- | --- |
| Repeated typos were dropped by unique-substring mapping. | Local findings retain exact UTF-16 ranges; remaining ranges shift after a verified correction. |
| Offline Quick Fix applied uncertain spelling guesses. | Automatic local correction uses deterministic rules; macOS spelling guesses are reviewable suggestions. |
| Spacing rules could modify URLs, email, paths, code, and indentation. | Protected technical ranges and saved dictionary phrases are excluded. |
| Browser corrections could remove meaningful `had had` or `that that`. | Ambiguous grammatical repetitions remain untouched. |
| A lone lowercase `i` was rejected as too short. | Safe one-character capitalization can be accepted. |
| Dismissed occurrences could reappear after an unrelated edit. | Dismissal follows that occurrence without hiding identical text elsewhere. |
| Browser site controls reloaded a page containing a draft. | Preferences update without forced page reloads. |
| Composition checks could interrupt IME input. | Browser checks wait for composition to finish. |
| Native highlights compared AX and Cocoa coordinates. | Bounds are converted once, clipped, and revalidated as the field moves or scrolls. |
| Native corrections did not consistently support undo. | Exact verified field/range changes register safe undo, including selected-text actions. |
| Dismissing native overlays could steal typing focus. | Dismissal leaves the source app's current focus alone. |
| Passive fallback could bypass paid-check opt-in. | Automatic provider requests respect feature opt-in and pause state. |
| Headless browser helper processes could block GUI launch. | Single-instance checks distinguish GUI copies and reopen the existing app. |
| Invalid provider JSON looked like a clean review. | Failure is surfaced while returned usage remains accounted for. |
| Small JSON response budgets could truncate issue arrays. | Bounded per-issue capacity supports the requested review size. |
| Numeric facts could change silently, and normal replies were blocked. | Numeric changes require review; natural reply openings and declines are accepted. |
| Writer keyboard undo could remove the complete draft. | Minimal Character-boundary native edits break undo coalescing; new/opened drafts begin with a fresh editor history. |

## Automated verification

`scripts/run_all_tests.sh` completed successfully:

- **368 Swift tests**, zero failures (323 before this review).
- Standalone text-normalization and output-safety logic suite.
- All **10 browser extension suites**.
- Shell syntax, app/extension release metadata, and repository audit.
- `git diff --check` passed.
- Assembled debug app passed strict code-signature verification.
- Assembled optimized release app passed strict code-signature verification.

The environment requires Xcode's matched compiler/SDK and writable module
caches. The successful command used:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/private/tmp/bean-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/bean-swift-cache \
BEAN_DISABLE_SWIFTPM_SANDBOX=1 ./scripts/run_all_tests.sh
```

The sandbox denied the system spelling server in XCTest. Deterministic
correction and range behavior passed; the live Writer check below also
exercised the macOS UI outside that test limitation.

## Live interaction verification

Native verification used an isolated, ad-hoc-signed `Bean-QA.app` with bundle
identifier `com.bean.writer.qa`. This avoided closing the installed Bean copy
and did not grant a new Accessibility permission or access a provider key.

- Completed setup with Accessibility skipped.
- Ran the free onboarding check: `teh quick  brown fox` became
  `the quick brown fox`.
- Opened the Writer and verified its empty state and native text accessibility.
- Loaded the example; three matching underlines and correction cards appeared.
- Accepted one correction; only its range changed and review continued.
- Used Undo Suggestion and verified the correction and underline returned.
- Found the initial native keyboard-undo grouping defect, fixed it, rebuilt,
  and verified Command-Z restored only the accepted correction.
- Dismissed one finding without changing the draft or other suggestions.
- Saved the synthetic draft to `/private/tmp/Bean-Writer-QA.txt`, verified its
  exact UTF-8 content, and saw the saved name and clean state in the Writer.
- Accepted another suggestion, invoked Command-N, and verified cancelling the
  unsaved-draft alert preserved the current writing.
- Opened the saved draft through the native file panel and verified its exact
  content and fresh suggestions returned, with a clean saved state.
- Reopened the QA build after setup and verified it opened the Writer directly.
- Verified the optimized release QA build gives a new draft immediate keyboard
  focus and supports Accept followed by Command-Z without refocusing the editor.

Browser verification used the repository fixture in a dedicated Chrome tab:
field badge, paragraph review, individual acceptance/undo, repeated typos,
clean technical references, AI progress, and highlighted before/after preview
were exercised. Provider behavior in that fixture used synthetic mock responses.
The temporary browser tab and server were closed afterward.

## Remaining verification and limits

- Live provider output was not evaluated or billed; provider-quality comparison
  requires a representative writing corpus and actual model responses.
- Third-party native apps need another live compatibility pass with the user's
  existing Accessibility authorization. Automated range/geometry/replacement
  tests passed; no new permission was granted for this review.
- Google Docs canvas and some complex rich editors remain excluded rather than
  offering unsafe replacements. Local checks are conservative English checks.
- The browser extension's source files are updated, but the loaded unpacked
  extension still needs reloading in Chrome's extension manager. Existing
  writing pages pick up the updated content script after their next refresh.
  Browser-control policy blocked opening `chrome://extensions`; no workaround
  or unrelated page refresh was attempted.

## Installation follow-up

After explicit user approval to quit and install, the old Bean process was
stopped and the tested optimized build was installed at `/Applications/Bean.app`.
Strict code-signature verification passed, and the installed code hash matches
the tested build. The previous app is preserved at
`/Applications/Bean-Previous-20261002.app` and in the workspace's build folder.

The installed app opened Bean Writer with an empty draft, working local checking,
and immediate editor focus. Settings reported Launch Bean at login enabled and
the existing AI connection present. Accessibility was unavailable in the newly
installed process; native cross-app assistance needs authorization restored by
the user. No permission was granted and no provider request was sent.

The existing Chrome, Brave, and Edge native-host manifests retain the canonical
installed executable path. Chrome's unpacked extension points to the repository
source folder, and its existing manual approval matches the native-host
allowlist. Live browser activation remains pending the extension reload.

The published version metadata stays at the current 1.6.0/0.7.2 contract. These
changes are recorded as unreleased; no release, commit, or publication occurred.


## System-wide follow-up to user feedback

The standalone Writer was not the user's intended primary experience. A second
pass prioritized live help and direct replacement inside existing macOS apps:

- Local live checking and the field-side button migrate to enabled once; paid
  automatic AI retains the user's prior opt-in and pauses correctly.
- Poll focus/content changes every 0.35s, including paste, existing drafts,
  programmatic updates and app switches; local checking follows a 0.45s pause.
- Resolve focused editable ancestors/descendants, read range-only rich text,
  accept verified paste-editable fields without an AXValue setter, and enable
  app-provided Accessibility trees without app-name allowlists. Per-call AX
  timeouts and graph traversal are bounded.
- Show a suggestion tray with direct proofreading and actual correction cards
  even when exact glyph geometry is unavailable. Pointer acceptance does not
  activate Bean; keyboard actions restore and verify the original source.
- Shortcut, inline, passive, and Bean Undo share verified normal Paste/Delete
  so editing events and native undo are preserved. Temporary Select All is
  collapsed before waiting for AI, and user clipboard/navigation is preserved.
- Proofread and rewrite replace selected text or whole fields directly, with
  one-click Undo after verification. Routine failures use a compact notice;
  changed or unsafe provider results do not open a comparison window.
- Native spelling and grammar suggestions supplement deterministic prose fixes.
  Grammar detail ranges are validated as sentence-relative UTF-16 ranges.
- Normal launches and setup completion remain in the user's app. Reopening Bean
  shows Writing settings; the Writer remains optional in the menu.

Final integrated verification passed **394 Swift tests**, all **10 browser
suites**, standalone safety logic, shell/release metadata and repository audit.
The optimized release build passed strict signature verification and was
installed at `/Applications/Bean.app`. The preceding product-review app is
preserved in `build/Bean-before-systemwide-20261002.app`.

Installed UI verification confirms live suggestions and the Bean button are
on, the user's existing deeper-AI opt-in remains on, and the writing shortcut
runs direct AI Proofread. Launch at login remains enabled. Reopening shows
Writing settings rather than the Writer.

The prior process reported Accessibility ready before replacement. The new
ad-hoc-signed build reports it unavailable. System Settings lists the preserved
`Bean-Previous-20261002.app` grant, not the current installed Bean. There is no
usable signing identity on this machine; ad-hoc builds bind their designated
requirement to a changing code hash. The Accessibility restoration workflow is
prepared, pending explicit user authorization/authentication. No grant was made.
Live cross-app detection, acceptance, provider output, and native Undo remain
unverified for this build until the current app is trusted. A synthetic local
browser fixture was prepared but was not used to claim those checks passed.

Controls exposing neither readable AX text nor editable focus still require an
app-specific integration. Secure fields are intentionally excluded. Universal
coverage across every custom/canvas editor has not been achieved or certified.

## Gmail duplicate-control and missed-spelling follow-up

The user restored Accessibility and confirmed the direct proofreading shortcut
works in ChatGPT, Claude, Slack, and Chrome's Gmail composer. These are
user-reported checks of those specific fields, rather than certification of
every field in those apps. No shortcut preference was changed in this follow-up.

The Gmail screenshot exposed two independent controls: the native hover button
and the extension's DOM badge. A content-free, five-second ownership lease now
makes native automatic UI yield while the extension owns the focused supported
web field. The browser process, focused tab/window, current document/field, and
native AXWebArea ancestry are checked. Web dialogs remain eligible (including
Gmail composition), while browser chrome stays on the native path. Stale
callbacks cannot revoke a newer field's claim, and failed renewal makes a
previously connected DOM assistant yield to native fallback. Manual shortcuts
are unaffected.

Browser checking previously relied on a small typo dictionary. Offline native
spelling and grammar now supplement those rules, without an API key or paid-AI
opt-in. The real macOS API also missed short English sentences with automatic
language selection (`language: nil`); explicit use of the user's configured
`en_CA` setting detects the same words. Bean reads that setting without changing
the operating system preference.

macOS's first spelling guess for `tme` was `tae`, and its correction API proposed
`the`. A pure ranker now prefers `time` in `this tme`, considering letter edits
and adjacent phrase context. Candidates still come from macOS. Ambiguous
choices remain reviewable alternatives and are excluded from offline bulk
proofreading below the confidence threshold; deterministic Quick Fix never
uses uncertain spelling guesses.

The browser's single control includes suggestions, direct Proofread, and four
Rewrite styles, with exact-source replacement and Undo. It labels the action's
scope (selection, draft, or current paragraph in a structured rich editor).
Native local checks and field leases are independent of the provider request
queue. Explicit trusted button actions use manual accounting; automatic AI
retains the existing opt-in and spending cap. Shared sanitization also preserves
source quotes and outer whitespace.

Verification: **424 Swift tests** pass, including the actual native localCheck
macOS-service regression for `tme` → `time` and an unlisted `misspeling` typo.
All **10 browser suites**, standalone safety checks, release metadata,
repository audit, and `git diff --check` pass. A separate unrestricted macOS
probe verifies `tme`, `misspeling`, `writting`, and `recieved` detection and
ranked candidates. No real provider output was sent or billed for this pass.

Live visual browser verification remains pending. Browser security policy
denied access to the synthetic local fixture because permission was declined.
The earlier `chrome://extensions` manager restriction also remains in force;
no alternate browser surface or indirect reload was attempted. The loaded
extension must be reloaded by the user, and updated writing pages need a refresh
after preserving their drafts.

The final optimized app passes strict signature verification and was installed
in place at `/Applications/Bean.app`. Its binary matches the tested release
build, and its bundled browser scripts match the final repository source. The
previous working app is preserved at
`build/Bean-before-browser-fixes-20261002.app`. Updated installed settings retain
Live suggestions, Bean button, launch at login, the prior deeper-AI opt-in,
provider connection, and shortcut preferences.

The fresh installed process again reports Accessibility unavailable after the
ad-hoc code hash changed. System Settings is prepared at its Touch ID prompt for
restoring `/Applications/Bean.app`; authentication and extension reload are
pending user action. No new permission was granted by the agent. Until those
activation steps complete, the new native field-ownership UI cannot be claimed
as live-tested in Gmail.

### Activation confirmation

The user subsequently completed Touch ID and reported reloading Chrome's Bean
extension. The installed app's General settings now report **Accessibility is
ready** and **AI connected**; Browser settings report **Mac connection
installed**. Read-only verification confirms the approved Chrome/Brave/Edge
native-host registrations still point to `/Applications/Bean.app`, and the
installed binary and bundled extension match the tested build/source. No further
permission or preference changes were made. The prior pending Accessibility
step is resolved. Live Gmail rendering and correction remain unverified by the
agent because the recorded browser-access restrictions still apply.

## Mail report and generic rich-editor follow-up

The user reported that an explicitly selected Mail draft produced “No Editable
Text Found.” Content-free history confirms the current installed app received
the proofread action but failed before acquisition; one current Bean GUI process
was running. The failure was not evidence of a stale duplicate app.

The shared Accessibility engine now recognizes editable AXWebArea surfaces
through positive editability or writable text capabilities, including static or
group focus leaves with an eligible editor ancestor. Complete, bounded element
text and selected text can use WebKit text-marker APIs when ordinary AXValue or
AXSelectedTextRange is missing. Selection writability alone never qualifies a
WebArea as editable. Native keyboard-editable controls retain their prior path;
marker-reading capabilities do not imply read-only behavior.

Opaque selections retain their actual marker identity, the complete source
snapshot, and same-field proof. They require unchanged selection/source and an
exact clipboard recopy before Paste. Unique selected text permits complete
post-edit verification; repeated occurrences never guess an offset or claim a
confirmed result without proof. Source continuity, clipboard proofs, paste
verification and Undo use exact UTF-16 equality rather than Swift's canonical
Unicode equivalence. Reconstruction rejects surrogate and grapheme fragments.

An opaque selected-span edit no longer offers whole-field Bean Undo, which
could remove unrelated rich formatting. A newer confirmed edit retires any
older Undo record; HUD Undo appears only when an eligible record exists. Native
normal-paste Undo remains available through the editor. Individual WebArea
suggestions do not fall back to replacing the entire rich document when exact
range selection is unavailable. Explicit whole-field actions remain plain-text
replacements and do not guarantee rich formatting/attachment preservation.

A failed shortcut read now leaves the editor focused, shows a six-second
nonactivating warning, and records a fixed, content-free acquisition reason.
It no longer presents the misleading Quick Fix modal for a Proofread request.

Verification: **443 Swift tests ran successfully**, with **five additional live
WebKit tests explicitly skipped**, and all **10 browser suites**, standalone
checks, release metadata, repository audit and diff checks passed. The owned
WKWebView fixtures use nonpersistent synthetic HTML and never inspect other
apps. This trusted XCTest host exposes its AppKit window tree but no usable
WebKit editor subtree; those skips are not live marker evidence. Marker
identity equality and actual Mail focus metadata still need live verification.

Computer-use access to Mail was rejected as “not approved to use Mail” before
and after the user's explicit approval and subsequent permission update. No
other UI surface or shell AX probe was used to circumvent that restriction.
The generic WebKit gap is source-supported; it is not a confirmed diagnosis of
Mail's exact focused element, and Mail has not been certified fixed.

The final optimized build was installed at `/Applications/Bean.app`, with strict
signature verification and a SHA-256 match to the built artifact. The previous
working app is preserved at `build/Bean-before-rich-editor-fixes-20261002.app`.
After the user restored Accessibility, installed UI reports **Accessibility is
ready** and **AI connected**. Setup was completed; live suggestions, the Bean
button, the prior deeper-AI opt-in and launch-at-login remain enabled, and no
shortcut preference was changed. No test mail or real provider request was sent.

### User confirmation and next quality milestone

The user subsequently reported that Mail is working. This resolves the reported
manual writing-action failure on their tested composer. It is user-reported
workflow evidence, not independent certification of live highlights, all Mail
composer variants, rich formatting, attachments, or marker geometry. The support
matrix now records that distinction.

The next milestone should measure the entire system-wide journey: first focus,
typing, issue detection, correction card, verified edit, continued typing and
Undo. Detector unit tests alone cannot establish that the dispatcher actually
runs a check or that a real editor preserves rich content. Correction-quality
evaluation should also include already-correct writing, dialects and personal
vocabulary, and meaning preservation in proofreading and rewriting.

The follow-up audit found and corrected a native live-check control-flow bug:
the cache-miss branch returned before detection, while cache hits unnecessarily
continued into checking. New fields and changed revisions now reach local
detection; unchanged snapshots reuse their issues after live source/dispatch
validation. Five regression tests call the actual service with isolated stores,
in-memory editor reads/presentation, and real deterministic detection. Restoring
the original faulty branch made the first-focus regression fail as expected.
These tests establish orchestration, not real editor geometry or paste behavior.

Onboarding now says **Finish Setup**, matching its existing close-to-menu-bar
behavior, and General copy offers Bean Undo only when safe restoration exists.
README, TESTING and the detailed QA plan now match direct writing actions,
manual-versus-automatic browser usage, build 11/extension 0.7.2, and native
capability-based eligibility. The QA plan adds 20 system-wide acceptance cases
and clearly separates proposed quality/performance goals from measured results.

Follow-up verification: **448 Swift tests passed**, with **five additional live
WebKit tests skipped**, and all **10 browser suites**, standalone checks, shell
syntax, release metadata, repository audit and diff checks passed. No provider
request was sent. These follow-up source changes are pending the next installed
build; the existing `/Applications/Bean.app` was not replaced during this audit.
