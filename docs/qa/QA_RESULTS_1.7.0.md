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
messaging timeout. These are being repaired together before the final candidate;
build 14 is retained as recorded evidence, not complete recovery certification.
