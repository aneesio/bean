# Bean 1.7.0 system-wide candidate QA

Date: October 2, 2026. This is an implementation and local-candidate record,
not public-release sign-off or universal-app certification.

## Candidate and preservation

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

Native live TextEdit transport, formatting/caret/Undo and final permission
recovery remain pending the macOS Touch ID handoff. Browser and native fixture
renders are recorded separately from real-app journeys.

A newly created synthetic TextEdit rich document was closed and retained at
`/private/tmp/bean-native-live-candidate-qa/Bean build13 synthetic proofreading.rtf`
for the pending journey. It contains a bold word, two known spelling errors,
emoji, a date/time and a synthetic email address. No personal draft was changed
or message sent. The temporarily changed shortcut action and Deeper AI setting
were restored to their original AI Proofread/on values before handoff.

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
