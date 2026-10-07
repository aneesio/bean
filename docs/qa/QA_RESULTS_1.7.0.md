# Bean 1.7.0 system-wide candidate QA

Date: October 2, 2026. This is an implementation and local-candidate record,
not public-release sign-off or universal-app certification.

## Build 13 baseline and preservation

| Field | Recorded value |
| --- | --- |
| Original work checkpoint | `e1f4a47` |
| System-wide implementation milestone | `8b2dd8d` |
| Build 13 source | `6d4acb3` on `codex/systemwide-quality` |
| Installed app | `/Applications/Bean.app`, 1.7.0 (13) |
| Chromium extension | 0.8.0 |
| Host | macOS 26.6.2 (25G83), Apple silicon |
| Package architectures | `x86_64 arm64` |
| Signing | Valid ad hoc signature; unnotarized; Developer ID work postponed by the user |

The prior installed build 11 remains recoverable at
`build/installed-backups/installed.XE4u0o/Bean.app`. The immediate build 12 rollback
is `build/installed-backups/installed.fCwAXq/Bean.app`. Both are retained; completed
build 12 release artifacts were preserved when build 13 was packaged.

## Automated engineering checks

`scripts/run_all_tests.sh`: **PASS**, 566 Swift cases, **559 passed, seven skipped,
zero failures**; all 13 browser suites, standalone logic, shell syntax, metadata,
and repository/credential audit passed. Final log:
`/private/tmp/bean-build13-full-tests-final.log`.

Five skips are unavailable own-process WebKit Accessibility fixtures; two are
explicitly opt-in evaluations. They are not reported as passes. The real local
macOS quality evaluation was run separately. All 18 owned WebKit editor/overlay
tests pass without skips, exercising the production editing helpers and UI.
These fixtures do not establish cross-process behavior in third-party apps.

Final build 13 also passes **three private fault suites**:

- `scripts/test_build_publication.sh`: compile, signature, publish and interruption
  failures preserve the prior signed bundle; concurrency and lock recovery pass.
- `scripts/test_local_install.sh`: fresh install, upgrade and verified rollback;
  invalid signature/symlink refusal; publication, final verification and
  interruption recovery; concurrent installer refusal.
- `scripts/test_release_packaging.sh`: build/DMG failures leave no completed
  artifacts; retry produces valid ZIP/DMG/checksums; a completed artifact cannot
  be overwritten by a second publication.

Logs: `/private/tmp/bean-build13-{build,install,package}-fault-tests.log`.
Fixtures use private destinations, not the actual installation. Both Mach-O
architecture UUIDs and every file-backed section match the current SwiftPM
release product (37 arm64 sections, 35 x86_64 sections).

## Actual package and installation

`BEAN_ALLOW_ADHOC_RELEASE=1 scripts/package_release.sh` and
`scripts/install_local_build.sh`: **PASS**. The installed, build, staged, ZIP and
mounted DMG executables match byte for byte. Each bundle passed strict signature
verification. Both checksum entries and `hdiutil verify` pass. The mounted DMG
contains the Applications link and exact current public documents; it was
detached after verification. All 30 bundled browser-extension files match the
source tree. The running Chrome extension was not reloaded or certified by this
run; reloading the unpacked extension remains a separate user/browser step.

```text
28ecb64fc291c7a643fe4fdc59d15a2145a87e2304b2df7e04fc2a0e875b4f34  Bean executable
5db1242da9ed517ab2f4b4e601d8a7058035d04968dca22d12136ef402966b1e  Bean-1.7.0-build13-unnotarized.zip
9797b14a08464cb54a311e142a53abb3bad1e69f9dea1b9bd223a29beacf6fbf  Bean-1.7.0-build13-unnotarized.dmg
```

Packaging and install logs: `/private/tmp/bean-package-build13.log` and
`/private/tmp/bean-install-build13.log`. The ZIP verification extraction is
retained in `bean-build13-artifact-verify-zazhnxez` under this Mac's temporary
directory.

## Installed UI observations

- Welcome leads with assistance in existing text fields, local spelling/basic
  grammar, and in-place corrections. The actual Bean icon and primary controls
  render without clipping at the reviewed window size.
- Ready labels the user's configured shortcut **AI Proofread**, discloses provider
  use, and distinguishes it from the explicitly local sample.
- The installed sample changes `teh quick  brown fox` to `the quick brown fox`
  through **Run Free Check**, without a provider request or Accessibility grant.
- Finishing setup returns to the menu-bar experience; Settings shows **1.7.0 (13)**.
- **Open Accessibility Settings** opens the actual macOS Accessibility list
  directly. macOS requires authentication to refresh the pre-existing grant
  after the ad hoc signature changed. Recovery routing preserves completed
  setup in the isolated regression test.

After the user completed Touch ID and Accessibility, installed Settings reported
**Accessibility is ready**. The user's screenshot confirms two automatic native
suggestions and the open assistant beside the rich TextEdit field. Browser and
native fixture renders are recorded separately from real-app journeys.

The subsequent build 13 live replacement **failed**. Source:
`This is teh draft. Please recieve it. Test.` followed by the unchanged synthetic
emoji/date/time/email paragraph; `draft` was bold. After the shortcut attempt,
actual TextEdit AX text and screenshot showed
`This is teh draft. Please receieive it. Test.` and Bean displayed **Couldn’t Apply
the Change**: **Bean sent the replacement but could not confirm what changed.**
The user corrected their initial success answer to report this failure. Earlier
tool-generated shortcut attempts and focus changes make attribution to one
physical event uncertain; the corrupted output is an observed failure, not a
pass or a proven transport root cause. No personal writing was involved.

This is an open P1 in build 13. Native replacement and Undo certification remain
withheld until the repaired transport is tested on the installed candidate.
The synthetic word and temporary `Test.` addition were restored with targeted
editor actions and saved for retesting, retaining the bold word and paragraph.

The synthetic TextEdit rich document is retained at
`/private/tmp/bean-native-live-candidate-qa/Bean build13 synthetic proofreading.rtf`
for the pending journey. It contains a bold word, two known spelling errors,
emoji, a date/time and a synthetic email address. No personal draft was changed
or message sent. The prior handoff restored the shortcut and Deeper AI settings. For the current
replacement retest, they are temporarily Quick Fix/off again; restoring the
user’s AI Proofread/on settings is required before the next handoff.

## Process sampling

The installed build 13 was sampled for 12 seconds (47 samples), with Writing
Settings foreground, all three assistance switches on, no active test editor,
and Accessibility recovery still pending: mean CPU 0.20%, CPU p95 1.5%, maximum
RSS 131.30 MiB. Record:
`/private/tmp/bean-idle-build13-permission-pending-profile.json`.

Earlier build 11 setup-idle sampling recorded mean CPU 0.18%, p95 0.3%, maximum
RSS 116.34 MiB. Permission/runtime contexts differ, so this is not an
apples-to-apples performance comparison or active-checking benchmark. Neither
record establishes real input-to-feedback or acceptance latency.

## Quality limits and unfinished validation

See [writing-quality evidence](WRITING_QUALITY_2026-10-02.md) for the frozen
1,024-case, agent-curated synthetic corpus and exact split provenance. Combined
local/macOS results: precision 100%, recall 91.57%, preferred correction 98.52%,
clean retention 100%; scan p95 20.35 ms. **The strict quality gate fails** heldout
preferred correction accuracy, 92.5% against the 99% requirement. The nine wrong
preferred corrections remain in the report; no threshold was lowered and the
heldout families were not used for further tuning.

Provider evaluation tooling completed a 36-record dry run with zero API requests.
A real paid run is pending the user's budget answer. Synthetic mapping replay
and injected provider tests are not real model-quality evidence. Human review,
an independent corpus, and candidate journeys across Mail, Notes, Slack,
ChatGPT/Claude and browser editors remain outstanding. Earlier user-reported
manual successes are preserved as pre-candidate evidence only.

Live feedback/acceptance p95 goals and 99.5% real-app verified-edit reliability
remain unmeasured. CPU/RSS process samples measure a different property from
feedback latency. This candidate is not ready to be certified as Grammarly
parity, universal compatibility, or a publicly signed/notarized release.

## Build 14 replacement repair

Build 14 repairs the generic native transport used by numeric-range corrections
and selected rewriting. It prefers a supported `AXSelectedText` setter after
settled range, actual selected text, complete source and destination proof.
Fallback Paste/Delete targets the captured process using isolated key state.
An unconfirmed setter cannot claim that text was copied or enable a replacement
retry. Verified partial batches retain an exact-subset Undo and an honest count.
The observed build 13 corruption remains a failure; its precise transport cause
is a hypothesis because earlier queued attempts/focus changes were involved.

Independent source review found no remaining blocker in the final repair. The
focused native transport suite passes **85/85**, including the exact typo
sequence, real owned NSTextView selected-text edits, rich attributes/attachment
preservation and native Undo. Those are owned editor-model tests, not external
Accessibility or physically held-shortcut certification.

Native field controls and review windows now publish descriptive floating-window
identities; decorative underline windows/views are omitted from accessibility
navigation. Pointer behavior and explicit keyboard-focus guards remain covered.
Passive updates reuse the badge host/view. Focused overlay tests: **five passed,
one skipped, zero failures**. The skipped control-descendant fixture first
proves the native NSButton walker, then finds that even a plain SwiftUI Button
baseline publishes no descendants in this unit host. Panel/tree assertions pass
separately; actual VoiceOver and external AXPress remain unverified.

`scripts/run_all_tests.sh`: **PASS**, **579 Swift cases: 571 passed, eight skipped,
zero failures**; all 13 browser suites, standalone logic, shell syntax, metadata
and repository/credential audit pass. The eighth skip is the unavailable owned
SwiftUI descendant fixture described above. Log:
`/private/tmp/bean-build14-full-tests.log`. Focused logs:
`/private/tmp/bean-native-transport-regression-tests.log` and
`/private/tmp/bean-native-overlay-accessibility-tests.log`.

Build 14 was packaged and installed from **`f52e35d`**. The actual Settings UI
shows **1.7.0 (14)**. All three private build/install/package fault suites pass
against this final candidate. Both architecture UUIDs and all file-backed
sections match the current release product (37 arm64, 35 x86_64).

Installed, build, staged, ZIP and mounted DMG executables match byte for byte;
strict signatures, both checksum entries and `hdiutil verify` pass. Mounted DMG
documents exactly match the eight public source documents and the Applications
link is valid. The image was detached. All 30 bundled extension files match
source; the running Chrome extension is not independently certified. The ZIP
verification extraction is retained as `bean-build14-artifact-verify-fnfovj_6`
under this Mac’s temporary directory.

```text
1b34a1e5af6b39c16a7b0dbe2f555eda1f1b6c1095e8a0f42821a714c9152b53  Bean executable
523a363b7b08af711cb45ed5f1791fc00fc7dfc02b29f59fd296488cb262a1b1  Bean-1.7.0-build14-unnotarized.zip
c082adf5ffe7d32c3f704ff6d1b6feaeee9afdc3cb181c2ff5dc2037031900be  Bean-1.7.0-build14-unnotarized.dmg
```

The immediately previous installed build 13 is retained at
`build/installed-backups/installed.ItFqry/Bean.app`, in addition to the older
rollback bundles. Completed build 13 release artifacts were preserved. Logs:
`/private/tmp/bean-package-build14.log`, `/private/tmp/bean-install-build14.log`
and `/private/tmp/bean-build14-{build,install,package}-fault-tests.log`.

After installation, General requested Accessibility recovery despite the existing
macOS switch being enabled. Refreshing it presented a Touch ID sheet. The user
completed the prompt and refreshed the switch; actual build 14 General now
reports **Accessibility is ready**. No authentication bypass was attempted.

The restored synthetic TextEdit fixture was tested on installed build 14 with
Quick Fix/offline assistance. A CUA app-scoped shortcut leaves the source
unchanged; the user then pressed the hardware shortcut once. Actual TextEdit AX
and pixels confirm **`This is the draft. Please receive it.`**, with `draft` still
bold and the entire emoji/date/time/email paragraph unchanged. No error or retry
was reported for this physical attempt.

Caret proof: typing the owned ` Test.` sentinel placed it after `it.` at the
original unrelated caret; native Undo removed only that sentinel. TextEdit native
Undo then restored the two corrections separately (`teh`, then `recieve`), and
native Redo restored the exact corrected draft. The user chose **Undo Last Bean
Change**; actual AX/pixels show both original typos restored in one operation,
with bold text and the second paragraph intact. The user separately confirmed
Undo worked. The source fixture was saved again. **The reported TextEdit P1 is
resolved on build 14 for this recorded journey.** Native Undo groups each span;
it is not one native batch, while Bean Undo is one action. No personal draft or
clipboard was read and no paid request was made.

This live result does not certify every editor, Clipboard fallback transport,
VoiceOver, or provider rewriting. CUA app retrieval opens/reopens Settings instead
of exposing the field-side panels on this host, so actual panel controls remain
separate from the passing owned panel/tree regressions.

Final source review found additional failure-only P1 retry boundaries outside the
successful journey: an unconfirmed Undo could re-register its old record, and
unchanged text after a sent Paste could be classified as a retryable copied
fallback. A setter error Boolean also does not distinguish a refusal from an AX
messaging timeout. These were repaired in build 15 source and covered by the focused and combined
checks below. Build 14 remains the recorded live result for its successful path.


## Build 15 delivery and Undo recovery follow-up

Native post-delivery verification now treats every nonconfirmation as uncertain,
including unchanged text and an Accessibility setter error. A sent edit cannot
be reclassified as an undelivered copied fallback. Undo consumes its owned
record before delivery, serializes concurrent requests, preserves newer records,
and restores an old record only after a proven refusal before delivery.

Browser regression replay reproduced a queued page handler turning `teh ending`
into `therere ending` after an unsafe second edit. Accepted commands, exceptions,
uncertain results, and observed editing events now prevent fallback. A cancelled
`beforeinput` is respected. A genuine no-op fallback still requires exact source,
focus, selection and connected original nodes. Failed batches stop immediately.
These are editor-capability repairs rather than per-app exceptions.

Independent native and browser source reviews found no remaining blocker in
these contained changes. Native recovery/Undo: **95/95 passed, zero skips**.
Owned WebKit editor models: **19/19 passed, zero skips**; with the three overlay
fixtures, **22 owned WebKit editor/overlay tests passed**. All **13 browser suites
passed**. Focused logs:
`/private/tmp/bean-native-delivery-undo-recovery-tests.log` and
`/private/tmp/bean-browser-delivery-regression-tests.log`.

`scripts/run_all_tests.sh`: **PASS**, **593 Swift cases: 585 passed, eight skipped,
zero failures**. Standalone logic, shell syntax, metadata (1.7.0 build 15,
extension 0.8.1) and repository/credential audit pass. The skips remain five
unavailable own-process AX web-area fixtures, one SwiftUI descendant fixture,
and two opt-in evaluations; none is counted as a pass. Log:
`/private/tmp/bean-build15-full-tests.log`.

Packaging, installed-app observations and retained rollback are recorded after
publication below. The new browser transport requires extension 0.8.1 to be
reloaded, followed by a page refresh; owned WebKit tests do not certify the
running Chrome extension. No paid request was made.


Build 15 was packaged from **`dcb3b2f`**. Build, staged, ZIP and mounted DMG
executables match byte for byte, with both `arm64` and `x86_64` architectures.
Strict signatures, both checksums and `hdiutil verify` pass. The mounted DMG's
eight public documents match source exactly and its Applications link is valid;
the image was detached. All 30 bundled extension files match source 0.8.1.
Completed build 13 and 14 packages remain intact. Logs:
`/private/tmp/bean-package-build15.log` and
`/private/tmp/bean-build15-artifact-verify.log`.

```text
26766b7a02a44a1e04bb36b7b47ca2689dce225eb2169ca19982b485c5e0a658  Bean executable
3af01838bc24e41463228de154fbe4b42cf267254f723b5237788717c6d84ebe  Bean-1.7.0-build15-unnotarized.zip
a091a27c6608e33d465d4b00962db6fc4d72ca0325d9d08ec536a031b763089b  Bean-1.7.0-build15-unnotarized.dmg
```

The verification ZIP extraction is retained as
`bean-build15-artifact-verify-260smz_y` under this Mac's temporary directory.
At package verification, actual installed/running Bean remained build 14;
computer use reported that the Mac was locked. Build 15 installation and live
retest await unlocking, so package checks are not labelled installed-app passes.


All **three private build/install/package fault suites pass** against the exact
build 15 staged candidate, each exit code zero. They cover refusal and recovery
for build/signature/publication/DMG failures, interruption, concurrency, verified
rollback and preservation of completed artifacts. Both architecture UUIDs and
all file-backed sections match the current release product (37 arm64, 35 x86_64).
The candidate's complete bundle tree identity and executable hash remained
unchanged. Logs:
`/private/tmp/bean-build15-{build,install,package}-fault-tests.log`.

A second computer-use attempt still reported the Mac locked. No process was
forcibly terminated and no live installation was attempted. The owned TextEdit
fixture is saved with the original two typos. Temporary native testing settings
remain Quick Fix and Deeper AI off; the user's original AI Proofread/Deeper AI on
settings must be restored after the final live smoke test and closing only that
owned fixture. The hardware shortcut remains unchanged. Installation, any
required ad hoc Accessibility refresh, actual build 15 replacement/Bean Undo,
settings restoration and Chrome 0.8.1 reload remain pending. No paid request or
external message was sent.


## Build 15 installation after unlocking

The user unlocked the Mac. Bean 14 was quit through its normal UI, and the
installer verified/published the exact staged build 15 bundle. Actual Settings
shows **1.7.0 (15)**. Strict installed signature and complete installed/staged
bundle identity pass; the executable matches the build/ZIP/DMG hash above.
The immediately previous build 14 is retained at
`build/installed-backups/installed.gCcT2U/Bean.app`. Log:
`/private/tmp/bean-install-build15.log`.

General requested recovery of the existing Accessibility authorization. System
Settings showed Bean enabled, but refreshing the switch presented a Touch ID
sheet. The physical authentication step was handed to the user; no bypass was
attempted. Live build 15 replacement/Undo and settings restoration follow once
actual access is ready. Extension 0.8.1 reload and page refresh were also
requested; there is no actual Chrome candidate pass yet.


## Final build 15 live result and handoff

The user completed Touch ID and refreshed the existing permission. Actual build
15 General reports **Accessibility is ready**. The user also reports reloading
the Chrome extension and refreshing pages; that is a user-reported activation,
not an independently observed Chrome edit/Undo pass.

The saved owned TextEdit fixture was focused with its caret after the first
sentence. After the requested physical Quick Fix, actual AX and pixels show
**`This is the draft. Please receive it.`**. Both spelling changes are exact;
`draft` remains bold, the caret remains after `it.`, and the complete emoji,
launch date/time and email paragraph is unchanged. The user then chose **Undo
Last Bean Change**. Actual AX and pixels show the exact original `teh` and
`recieve` restored together, with rich text and surrounding content intact.
**Build 15 live Quick Fix and Bean one-action Undo pass for this journey.**
The fixture was saved and closed normally before restoring automatic AI.

Actual Settings confirms the original **AI Proofread** shortcut action and
**Deeper AI suggestions on** are restored. The shortcut itself remains **⌘⇧G**;
no key-combination reset occurred. Live suggestions, the Bean button and launch
at login retain their enabled settings. Browser Settings reports its Mac
connection installed and browser deeper checks enabled; live browser connection
and transport are checked inside the extension, not certified by that screen.
No paid QA request, personal-draft edit, clipboard inspection or external
message occurred.

Remaining product-quality work is explicit: the strict heldout preferred
correction gate still fails (92.5% versus 99%). A development-only ranking review
found all 488 returned development suggestions correct; it did not inspect
heldout cases or justify a weight tweak. Better confidence calibration and
candidate diagnostics can support a contextual reranker, but improved preferred
corrections require independently reviewed development data and a fresh holdout.
No heuristic was tuned to erase the known failure. Real provider evaluation
still awaits a budget, and broader candidate app journeys, VoiceOver, actual
feedback/acceptance latency and real-app edit reliability remain unverified.
Developer ID signing/notarization remains explicitly postponed by the user.
This final local candidate is not universal-app or Grammarly-parity sign-off.

## Build 16 compact field control — October 5, 2026

The Mac app (1.7.0 build 16) and browser extension (0.8.2) replace the field
logo/pill/count with a 10-point/CSS-pixel status dot. A hollow gray ring indicates
no current findings; amber indicates suggestions. Gray does not certify clean
writing. Hover/help and accessibility labels retain status details; clicking
retains the existing assistant and actions. The clear rectangular pointer target
is 28 points/pixels in both implementations.

Automatic placement validates the entire target outside the complete editable
field, within its source window/display or browser viewport, and clear of nearby
controls. Bounded, content-free AX/DOM geometry collection fails closed on
unknown, opaque, incomplete, crowded or offscreen layouts. Controls are refreshed
even when text does not change. No caret/click guess or viewport clamp may place
the control inside the editor. Hidden native sessions suppress the old launcher;
browser underlines/cards retain ownership when the dot alone cannot fit. Legacy
native drag is restricted to freshly verified safe space. Existing shortcuts,
menu actions and eligible underlines remain available when the dot hides.

Independent native/browser source review found no remaining placement blocker.
The new regressions caught and repaired a legacy hosting-controller zero-size
panel and circular browser hit target; final rectangular-corner hit tests pass.
All 54 focused native cases pass, with one existing SwiftUI AX descendant skip.
All four owned WebKit overlay cases pass, including desktop/narrow/light/dark
crowded composers, neighboring Send/attachment/microphone hit routing, thin
unknown controls, full-target corner clicks, tooltip/assistant focus retention,
offscreen recovery and deliberate no-space/shadow-layout hiding.

`scripts/run_all_tests.sh`: **PASS**, **610 Swift cases: 602 passed, eight skipped,
zero failures**. All 13 browser suites, standalone logic, shell syntax, version
metadata and repository/credential audit pass. The existing skips remain five
own-process AX WebKit fixtures, one SwiftUI descendant baseline and two opt-in
evaluations. Logs: `/private/tmp/bean-build16-full-tests.log`,
`/private/tmp/bean-build16-dot-render-tests.log` and the earlier focused geometry
run `/private/tmp/bean-build16-dot-focused-tests-final.log` (before the browser
corner repair, whose four failures are superseded by the final passing run).

Actual production-view renders were inspected at
`/private/tmp/bean-build16-native-dot-visuals` and
`/private/tmp/bean-build16-browser-dot-visuals`. Owned AppKit geometry fixtures
exercise the shared traversal but do not certify external AX transport. Owned
WebKit hits and synthetic dispatch verify layout and handler routing, not trusted
physical Chrome input. Chrome automation rejected `chrome://extensions/` because
its URL policy permits HTTP/HTTPS only; no alternate surface or bypass was used.
Manual extension reload remains separate. Broader real-app placement, VoiceOver,
the existing writing-quality gate and signed/notarized release limits remain.

Build 16 was packaged from **`2dc8a9f`** and installed at
`/Applications/Bean.app`. Build, staged, ZIP, mounted DMG and installed complete
bundle trees match; strict signatures, both artifact checksums and DMG integrity
pass. Independent inspection confirms both architecture UUIDs and all 72
file-backed sections match the universal SwiftPM product (37 arm64, 35 x86_64).
All 30 bundled extension files match source 0.8.2 byte for byte. The DMG includes
the Applications link and eight exact public documents, and was detached after
verification. Completed earlier artifacts remain intact. Build 15 rollback:
`build/installed-backups/installed.AEAzAv/Bean.app`.

```text
83d8facd2820ef606232290f7beb745f633343e3d9aaa7ca2433ff3ce9995c45  Bean executable
292baebdf4c5b168362cdb9230b48bdbae0c9783ea7192e140ad9b3524602847  Bean-1.7.0-build16-unnotarized.zip
683e79b078e879b83544db7b4214b4f2f4b26e2ae4674f5e199ec7678caee571  Bean-1.7.0-build16-unnotarized.dmg
```

Logs: `/private/tmp/bean-package-build16.log`,
`/private/tmp/bean-install-build16.log`,
`/private/tmp/bean-build16-artifact-verify.log` and
`/private/tmp/bean-build16-installed-verify.log`. The first verification ZIP
extraction is retained at
`/var/folders/mt/ywk26cl921l2mt__0nw71jv00000gn/T/bean-build16-artifact-verify-9es06y1r`.

Actual installed General shows **1.7.0 (16)** and Writing shows **Bean dot** with
the new safe-space explanation. AI Proofread/⌘⇧G, Deeper AI on, Live suggestions
on, dot on and launch-at-login on retain their settings. General requires
Accessibility recovery. Refreshing the existing System Settings switch presents
a Touch ID sheet; the user was asked to authenticate and toggle Bean off/on.
Native live placement awaits that physical refresh. Extension 0.8.2 reload/page
refresh was also requested; it is not yet independently observed or reported.

Chrome allowed a separate owned HTTP fixture in explicit `beanqa=1` mock mode.
Its production scripts displayed a tiny amber dot outside a textarea; a real
browser pointer click opened assistance without losing the source caret. One
Proofread click changed synthetic `This is teh draft.` to `This is the draft.`
directly, and the status became a hollow gray ring. AX text and pixels agree.
This verifies Chrome rendering/click flow against local API mocks, not the
installed extension/native bridge or real model judgment. The disposable tab
was closed and the loopback-only fixture server stopped. No personal draft,
clipboard contents, provider key, paid request or external message was used.

## Build 17 brown dot and placement recovery — October 5, 2026

The default native and browser dot now uses Bean's solid brand brown, with amber
for current suggestions. It remains ten points/CSS pixels with a complete
28-point/pixel rectangular target; no visible count, logo or pill returns.
Existing palette tokens adapt the brown to light/dark appearance.

Placement searches free intervals along the complete verified field edges,
removing the previous 96-point search cutoff. Neutral AX ancestors may lack
their own bounds when exact field/window bounds and the complete bounded source
path remain available. Browser pointer-events:none wrappers do not exclude
their own rectangle, but their descendants are still checked; display:contents
text/children remain exclusions. display:none subtrees can be omitted.

Independent native/browser review caught unsafe assumptions about parent
clipping. The final native scanner resolves unknown container descendants even
when the parent frame is far away, and refuses incomplete/opaque branches.
The browser scanner does not use paint containment or content-visibility:hidden
as a subtree clipping proof. Exact whole-target/window/viewport constraints,
48-node/eight-ancestor/depth-two/30ms native bounds and the browser traversal/
8ms/96-candidate proof bounds remain. Opt-in native diagnostics contain only
static reason/count/timing values, never writing, labels or application identity.

The actual installed build 16 General reported Accessibility ready before this
update; the dot and Live preferences were on. An owned unsent AppKit fixture
exposed a zero-frame neutral editor wrapper and synthetic source only. It was
closed normally; Deeper AI was restored on after provider-free testing. This
does not establish third-party overlay visibility. The missing-dot app/field has
not yet been identified by the user. Computer-use review rejected inspection of
com.openai.codex for safety reasons; no alternative surface or bypass was used.
Custom/misreported AX trees, unobservable closed-shadow content and bounded
over-limit layouts remain explicit capability limits. No claim that the user's
specific composer or universal-app placement has been certified is made.

`scripts/run_all_tests.sh`: **PASS**, **622 Swift cases: 614 passed, eight skipped,
zero failures**. All 13 browser suites, standalone logic, shell syntax, release
metadata and repository/credential audit pass. The eight existing service/AX/
opt-in skips remain explicit; none became live compatibility evidence.
All six owned WebKit overlay tests pass, including desktop/narrow/light/dark
full-edge brown paint, crowded hit routing, pointer-events override and boxless
children, thin content-hidden hosts, ineffective inline containment, top-layer
popover escape and bounded over-limit hiding/recovery. Clip-margin painting is
reported according to actual WebKit support, while its child rectangle remains
an exclusion on every engine. Source text, caret and focus guards pass.

The final gate started with a nonexistent browser snapshot directory. The
snapshot helper now creates its own output folder, removing alphabetical-test
order dependence. It uses direct offscreen capture and reports/rethrows export
errors; there are no retries or ignored assertions. Earlier failing runs
`bean-build17-full-tests.log` and `bean-build17-browser-focused-tests.log` are
superseded by `/private/tmp/bean-build17-full-tests-final.log`. The attempted
native frame wait was unsuitable for hidden test views and was removed.

Actual production native light/dark and browser crowded/full-edge renders were
visually inspected at `/private/tmp/bean-build17-native-dot-visuals` and
`/private/tmp/bean-build17-browser-dot-visuals-final`. These are owned fixture
renders, not certification of installed native AX or physical Chrome delivery.
No personal draft, provider key, clipboard contents, paid request or outgoing
message was used for this update.

Build 17 was packaged from **`b0d7dee`** and installed at
`/Applications/Bean.app`. Built, staged, ZIP, mounted DMG and installed complete
45-file bundle trees match. Strict signatures, universal architectures, both
artifact checksums, DMG integrity, the Applications link and eight exact public
documents pass. The verification mount was detached. Independent inspection
confirms all 72 file-backed product sections and both architecture UUIDs match:
arm64 `9C7136DD-141C-364F-8DC4-0CE47CB2F568` (37 sections), x86_64
`A898591D-6BDF-3BE3-80F9-6E1679D5F987` (35 sections). All 30 bundled extension
files match source 0.8.3 exactly; both native-host utilities also match.
Build 16 rollback: `build/installed-backups/installed.Fd2LVL/Bean.app`.
Earlier completed release artifacts remain intact.

```text
e6bc22aec10fca222b66a344c7e640f2dce19a46c395346d8c7c8c96490578ba  Bean executable
ffa7836e7fa15dda836d7027f7492cdd6fc9223049bc1fdafa0aca28d3db6e03  Bean-1.7.0-build17-unnotarized.zip
0caf6f5f9785a31c97ff9501a65c09a33f62b3d9414ad56fbaeafe5110b9dd5a  Bean-1.7.0-build17-unnotarized.dmg
```

Logs: `/private/tmp/bean-package-build17.log`,
`/private/tmp/bean-build17-artifact-verify.log`,
`/private/tmp/bean-install-build17.log` and
`/private/tmp/bean-build17-installed-verify.log`. Retained ZIP verification tree:
`/var/folders/mt/ywk26cl921l2mt__0nw71jv00000gn/T/bean-build17-artifact-verify-bz6b_d_k`.

Actual installed General shows **1.7.0 (17)**. Live suggestions, Deeper AI, Bean
dot and launch-at-login remain on; AI Proofread/⌘⇧G is unchanged. General reports
that Accessibility recovery is required after the changed local ad hoc build.
The existing System Settings Bean entry is on, but refreshing it presents a
Touch ID sheet. The user was asked to authenticate and toggle the same entry
off/on; physical refresh remains pending at this record. Manual extension
0.8.3 reload/page refresh was also requested and is not yet confirmed. No live
build 17 native overlay or installed Chrome bridge pass is claimed.

Activation follow-up: the user reports completing Touch ID, refreshing Bean's
Accessibility entry and reloading extension 0.8.3/pages. System Settings shows
Bean enabled. After one normal Bean restart, actual build 17 General reports
**Accessibility is ready**. AI Proofread/⌘⇧G and all writing/login preferences
remain intact. The user-reported extension reload is not an independently
observed installed Chrome bridge test.

A final owned native fixture check used screenshot-grounded pointer clicks on
Send, Attach and Mic. Each counter incremented once with a normal wrapper and
once with its AX frame zero (all counters reached two); synthetic text remained
unchanged. The fixture was quit normally and Deeper AI was restored on. The
app-scoped fixture screenshot does not establish another process's overlay
presence, so this is a control-routing smoke check, not a certified live dot
visibility pass or third-party composer check. No paid QA call was made.

## Build 18 inside-field dot — October 5, 2026

The user reports no dot in external apps and requests inside placement,
preferably top-right. This supersedes the previous outside-only rule. The
previous whole-window AX and whole-document DOM prerequisites could suppress
otherwise usable fields because unrelated branches lacked complete geometry.
That is a code finding, not a live diagnosis of every reported app.

Both launchers now prefer the editor's inside top-right, with other clear
inside edges available. Paint stays 10 points, brown by default and amber for
suggestions; the complete semantic target is 28 points normally, 20 in compact
fields. Below 20 points, missing exact source geometry or no usable inside slot
can still hide the dot. No issue count or outer pill is added.

Native capture requires exact field/window continuity, samples bounded local
controls and protects exposed caret/text bounds. A positively bounded immediate
scroll viewport clips the source area; neutral wrapper frames do not.
Application-local candidate probes reject identified controls but distinguish
unavailable AX hit APIs from positive obstruction. Text geometry is best
effort, uses the existing captured draft, and does not change selection or
request a provider. The full target is checked before explicit opening; stale
focus, text, relocation or an identified obstruction prevents opening.

Browser placement uses actual text fragments, source-local controls and bounded
nearby geometry with time reserved for candidate ownership checks. Input
alignment/direction, CSS-styled placeholders, scrolling and compact 20-point
fields have real WebKit coverage. Arbitrary contenteditable pseudo-element
placeholders and unobservable custom controls remain limitations.

Independent native, browser and integration reviews are complete. They found
and repaired placeholder style copying, compact target parity, optional feed
budget consumption, scroll viewport clipping, explicit-open focus identity and
text-bounds deadlines. Two first WebKit failures were fixture setup errors
(pre-render shadow root and paragraph layout boxes mistaken for glyphs); they
were corrected without changing production code or relaxing text-overlap
assertions. The corrected six WebKit cases pass. An initial test launch used
the Command Line Tools instead of the repository's Xcode toolchain and failed
to load SwiftUI macros; the Xcode run and final script are the valid evidence.

`scripts/run_all_tests.sh` passes **639 Swift cases: 631 passed, eight baseline
skips, zero failures**, all 13 Node suites, standalone logic, shell syntax,
release metadata and repository audit. Focused native placement, panel, cached
selection/text and bounded Unicode range-planning checks also pass. The eight
skips retain the existing own-process WebKit AX, plain SwiftUI AX baseline and
opt-in evaluation reasons; they are not successful live app tests.

Twelve native and 17 browser light/dark/narrow/short renders were exported to
`build/qa-build18-native` and `build/qa-build18-browser`. Representative native
brown/amber and browser inside light/dark screenshots were inspected. The
geometry assertions check the complete pointer target, source preservation,
local control routing and known text avoidance. Owned fixtures do not certify
all third-party editors or installed Chrome bridge behavior.

Before installation, exactly one `Bean` process is running, at the stable
installed application path, and actual build 17 General reports Accessibility
ready. Bean Writer has no writer-owned system dot implementation; the global
polling path skips Bean's own process. Its reported dot is not accepted as proof
of external source ownership. Build 18 packaging/activation and external
fixture observations will be recorded separately. No paid QA call was made.

Build 18 source **`e63b239`** is packaged and installed at the stable
`/Applications/Bean.app` path. Strict signatures, universal architectures,
checksums, ZIP extraction and read-only mounted DMG verification pass. All
45 bundle files match across the assembled, staged, extracted ZIP, mounted
DMG and installed app. All 30 extension files and eight public documents
exactly match source. Independent native verification matches all 72
file-backed Mach-O sections to the current SwiftPM release product:

- arm64 UUID `EA938B8B-D8C4-3FF8-9808-CD355F77CB6E`, 37 sections.
- x86_64 UUID `51388131-E9DB-3B4F-A09C-F785DA747F8F`, 35 sections.
- Executable SHA-256: `5ac59f42855648a37e3d6207cc50d7369e195d17e5068d4471ded80eb6e4d0f3`.
- ZIP SHA-256: `2ce6e926646896660ae603d3ebaf646797a043f58eff4c7bd2a727c768900b91`.
- DMG SHA-256: `7392792dedac1a8aeaf2015da06698ddb95e0ed83d02be72103ac926e2f6a12f`.

The installer initially refused because a Bean process remained/restarted
after Quit. A normal Quit and process absence check preceded successful
installation. Build 17 rollback is retained at
`build/installed-backups/installed.68HMzr/Bean.app`; all 45 files match its
previous release bundle. No process was forcibly killed.

Actual General shows **1.7.0 (18)**. Its initial Accessibility state was stale
despite the existing System Settings switch being on. Refreshing the same
entry off/on succeeded within the already unlocked session; actual General
then reports **Accessibility is ready**. Live suggestions, Bean dot, login
and AI Proofread/⌘⇧G preferences remain intact. Deeper AI was switched off for
the owned live fixture and restored on after the fixture quit.

The owned external composer preserves its synthetic text and reaches Send,
Attach and Mic through screenshot-grounded pointer clicks, once with a normal
AX wrapper and once with its wrapper frame zero (all counters reach two).
The fixture is closed and its process absence is verified. An app-scoped
fixture screenshot omits Bean's other-process overlay; observing Bean's own
floating-control AX window does not establish its external source/coordinates
and can disturb focus. Therefore no independent screenshot-based live dot
placement sign-off is claimed from those tools. The user independently reports
that the dot now starts appearing in different apps while this work is active.
This is recorded as user-reported external visibility, not every-app coverage.

Extension 0.8.4 is bundled and source/owned-WebKit tested. Its manual Chrome
reload/page refresh has been requested and is not yet confirmed at this record.
The browser tool cannot navigate to extension settings. No installed Chrome
bridge or universal custom-editor pass is inferred from the Node/WebKit gate.
No paid QA action was invoked.


## Build 19 distinct issue dot — October 6, 2026

The user reports that brown and amber look too similar. Both native launchers
and the browser assistant now retain the neutral brown and use vivid red for
suggestions: `#D92D20` in light appearance, `#FF6B6B` in dark appearance. A small
geometric exclamation inside the same 10-point dot supplies a shape cue. The
white light-mode marker and dark `#24120F` dark-mode marker exceed 4.5:1 contrast
against their dot backgrounds. Browser forced colors use Highlight and
HighlightText. No count, larger pill, new placement rule or writing action is
introduced; the inside placement and complete 28/20-point targets remain.

Native pixel tests cover neutral/issues, both appearances and several counts.
The new real WebKit case measures the exact colors, glyph dimensions, centered
containment, normal/compact targets and issues-to-clear transition, retaining
source text, focus and semantic control identity. Its first run found an actual
subpixel centering error from absolute positioning within the dot border box.
Flex centering repaired it; the strict <0.03-point centering assertion was
retained. All seven owned browser overlay cases then passed.

`scripts/run_all_tests.sh`: **PASS**, **641 Swift cases: 633 passed, eight baseline
skips, zero failures**, all 13 browser suites, standalone logic, shell syntax,
release metadata and repository audit. The existing skips retain their prior
AX/service/opt-in reasons and are not counted as live compatibility passes.
Final log: `/private/tmp/bean-build19-all.log`. Focused final browser log:
`/private/tmp/bean-build19-browser-focused.log`.

Production native light/dark and browser regular/compact light/dark issue
snapshots were visually inspected in `build/qa-build19-native` and
`build/qa-build19-browser`. Independent source and visual review found no
remaining actionable issue. These owned renders certify this visual change,
not third-party editor coverage or installed Chrome transport. Packaging and
activation evidence will follow separately. No paid QA request was made.


Build 19 source **`3d86bd8`** is packaged and installed at
`/Applications/Bean.app`. Strict signatures, universal architectures, artifact
checksums, ZIP extraction and read-only mounted DMG checks pass. All 45 bundle
files match assembled, staged, extracted, mounted and installed bundles. All
30 extension files and eight public documents match source exactly, including
the copies bundled as app resources. The verification mount was detached.
Independent native inspection matches all 72 file-backed product sections:

- arm64 UUID `F08A837D-3E99-342C-9432-EAEFC41A8A1D`, 37 sections.
- x86_64 UUID `C7ABD6D7-E17B-3068-B169-E147FA319FF9`, 35 sections.
- Executable SHA-256: `77b21cd22bf69b09e5d52f6beed8e48bfa50514980d4cd3dab4316090089df18`.
- ZIP SHA-256: `9c3a3456830a4a2c97398ed75e9ba6c5ae77e8fdddaa961b4a406537af3f2b65`.
- DMG SHA-256: `f809dc7f951d6fb4143ef92ed4d2ed1995782e599a8f384d0c1892d00ecf4a3a`.

Logs: `/private/tmp/bean-build19-package.log`,
`/private/tmp/bean-build19-artifact-verify.log`,
`/private/tmp/bean-build19-browser-stage-audit.json`,
`/private/tmp/bean-build19-install.log`. ZIP verification tree:
`/var/folders/mt/ywk26cl921l2mt__0nw71jv00000gn/T/bean-build19-artifact-verify-lipl4dxf`.
Build 18 rollback is retained at
`build/installed-backups/installed.eD7eMj/Bean.app` and all 45 files match its
previous release bundle. Bean quit normally and process absence was verified
before installation. No user settings, draft or clipboard contents were read
or changed.

Actual General shows **1.7.0 (19)**. Live suggestions, Deeper AI, Bean dot,
login and AI Proofread/⌘⇧G preferences remain intact. General reports stale
Accessibility after the ad hoc signature changed. The existing System Settings
Bean entry is on; refreshing it presents a Touch ID sheet. The user has been
asked to authenticate and refresh the same entry. Manual extension 0.8.5
reload/page refresh is also requested. Both activation steps are pending at
this record. No installed Chrome bridge or live cross-process visual pass is
inferred from the owned render checks.


Activation follow-up: the user reports completing Touch ID, refreshing Bean's
Accessibility entry, reloading extension 0.8.5 and refreshing pages. The existing
System Settings entry is enabled and actual build 19 General reports
**Accessibility is ready**, with AI Proofread/⌘⇧G and login unchanged. Settings
was closed; Bean exposes its semantic floating writing control again. The
user-reported Chrome activation is distinct from an independently observed
installed browser bridge test. This visual change's native/browser owned-render
and source/artifact checks are complete.
