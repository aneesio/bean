# Bean 1.6.0 Public Beta QA Record

Date: August 22, 2026

## Candidate

| Field | Result |
| --- | --- |
| Source commit | Squashed Bean 1.6.0 public snapshot on `main` |
| Branch | `codex/public-release-overhaul` |
| App | Bean 1.6.0 (build 11) |
| Browser extension | Bean for the Web 0.7.2 |
| macOS / hardware | macOS 26.5.2 (25F84), Apple silicon (`arm64`) |
| Build tools | Xcode 26.6 (17F113), Swift 6.3.3 |
| Browser | Google Chrome 151.0.7922.170 |
| Signing | Ad hoc, explicitly unnotarized GitHub beta |
| Acquisition paths | Source, staged app, ZIP, and mounted DMG |

No production API request, message send, Full Reset, personal writing sample, or
personal clipboard capture was used during this run. Provider and destructive
failure paths use injected fixtures and disposable stores.

## Automated release gate

`BEAN_DISABLE_SWIFTPM_SANDBOX=1 ./scripts/run_all_tests.sh`: **PASS**

- XCTest: 321 passed, 0 failed.
- Standalone writing/safety/framing logic: passed.
- Browser extension migration, background, content trust, detector, options,
  popup, overlay accessibility, manifest, and version suites: passed.
- Shell syntax and release metadata: passed.
- Repository safety and current-tree/history credential audit: passed.

Independent reviews also passed the final provider/cost/input/update,
replacement, legacy Keychain upgrade, extension keyboard, release-document,
and native product-flow diffs. Exact regressions cover interrupted v1.4 setup,
stale Keychain presence metadata, canceled/locked reads, stale replacement
targets, external interaction during verified paste, browser focus restoration,
and multi-browser setup routing.

## Release artifacts

`BEAN_ALLOW_ADHOC_RELEASE=1 BEAN_DISABLE_SWIFTPM_SANDBOX=1
./scripts/package_release.sh`: **PASS**

| Check | Result |
| --- | --- |
| Strict code-signature verification | Pass |
| Architectures | `x86_64 arm64` |
| App / extension metadata | `1.6.0 (11)` / `0.7.2` |
| Checksum file verification | Pass |
| `hdiutil verify` | Pass |
| DMG layout | Bean.app, Applications symlink, and required public docs present |
| ZIP / DMG / staged executable identity | Byte-for-byte match |
| Gatekeeper | Expected rejection for ad-hoc unnotarized candidate; docs disclose the Finder **Open Anyway** flow |

Artifact hashes:

```text
d1ddcf9c8c071ff8608b96b4d2d82b3942ea859fa1b5893f7679ca56585288bb  Bean-1.6.0-unnotarized.zip
ebdecbf688f31187e5b97d0bc2dddb6904bb10225e06470141cee743515c79c1  Bean-1.6.0-unnotarized.dmg
5846d236eab5b2e711fc072dd55a38939ee428970bb78bddb5ed971648d9eded  Bean-1.6.0-unnotarized.sha256
9664681041390d2aac32b8ad8dec3a36666718515d75425e5646bcd80d4cf64c  Bean executable
```

## Installation and live checks

- The staged candidate was installed at `/Applications/Bean.app`; its executable
  hash matches the staged, ZIP, and DMG copies.
- The replaced app remains recoverable at
  `/Applications/Bean-1.6.0-build10-pre-da5f16b-20260822-2110.app`.
- Exactly one installed Bean process was observed after launch.
- Chrome, Brave, and Edge native-host manifests remain mode `0600`, allow only
  extension `oalcloaaolfcncopcmnefbhdegkpbcln`, and point to the exact installed
  executable.
- The installed onboarding ready page opened without a provider action. Its
  built-in local check changed `teh quick  brown fox` to `the quick brown fox`,
  and setup completed through **Use Bean Locally** without an AI key.
- The installed Settings window opened at its larger five-section layout and
  exposed General, Writing, AI & Usage, Browser, and Privacy & Help without
  clipped primary controls. The selected sidebar item and segmented controls use
  Bean's brown brand accent rather than the system-blue selection treatment.
- AI & Usage labels the provider as optional, shows the saved-key presence
  without reading it, and explains that Keychain is accessed only for Edit Key,
  Test Connection, or a triggered AI action. Navigating to the page produced no
  password prompt and no key operation was invoked. Usage reported local
  suggestions as free and provider-backed activity separately.
- Writing showed Live suggestions and the Bean button enabled, Deeper AI
  suggestions disabled, and explicit zero-token/local behavior. Browser reported
  **Mac connection installed** with a single **Repair Mac Connection** action.
  Privacy & Help exposed the local-report contract, guided setup, license/privacy
  links, and a confirmatory Full Reset action; Full Reset was not invoked.
- The committed browser fixture displayed the official Bean icon, local issue
  underlines, and a visible keyboard focus ring after Tab. Password, one-time
  code, card-number, search, email, read-only, disabled, and code-like fixtures
  showed no Bean UI. No fixture content left the local mock.
- After reloading the unpacked extension, the exact installed extension also
  displayed the official Bean icon, issue underlines, and a visible keyboard
  focus ring in the local editor fixture. This confirms the live Chrome package,
  not only the committed test mock.
- Chrome opened the exact private Options page for extension
  `oalcloaaolfcncopcmnefbhdegkpbcln`. Browser automation intentionally could not
  inspect the `chrome-extension://` page because private extension pages are
  protected. The user visually confirmed **Connected · Bean 1.6.0**, AI
  suggestions **Ready**, and automatic AI usage **0 of 20**. The page correctly
  explains that local checks are free, browser AI counts toward the daily limit,
  and Bean works by default except on explicitly blocked websites.
- A synthetic, unsent Slack web draft confirmed that the extension injected its
  inline host into Slack's editable message surface. The Bean icon and issue
  highlights were not visibly rendered in the composer crop. The draft was
  deleted and verified empty without sending it. This live discrepancy remains
  excluded from the 1.6 support matrix rather than represented as working.
- Gmail was opened without inspecting inbox content, but Chrome automation could
  not reliably open its composer. No Gmail draft was created or sent.

The protected Options page's live connection label was user-confirmed. Its
blocked-sites list contained `127.0.0.1`, a deliberate local-development entry
that does not affect ordinary websites. Computer Use could not attach to the
Dock process or create a disposable TextEdit document from TextEdit's empty Open
panel, so those two checks are recorded as tool limitations rather than inferred
passes. Native replacement and Slack desktop behavior had already been
user-verified on this candidate line; this run made no personal-app draft and
sent no content.

### Build 9 blocked-site removal regression

The user found that removing `127.0.0.1` could display **Bean could not save
that change** when Chrome closed the service-worker response channel after the
privacy choice had already been persisted. Options now re-reads authoritative
extension storage before reporting failure and separately requests the dynamic
registration refresh. A regression test covers a lost mutation response after
durable removal. The full 321-test release gate and every browser-extension
suite passed again after the fix. Build 9 / extension 0.7.1 was repackaged,
checksum- and DMG-verified, installed at `/Applications/Bean.app`, and its
executable and bundled Options script match the staged candidate byte-for-byte.

The user's live retest showed that add and remove still failed because Chrome
includes `sender.tab` when Options is opened in a normal browser tab. Bean had
incorrectly rejected every tab-bearing settings sender before storage was
touched. Build 10 / extension 0.7.2 authorizes an authenticated
`chrome-extension://` Options sender with a same-extension tab URL while still
rejecting mismatched page URLs. Exact add, remove, and forged-tab regression
tests pass, as does the full 321-test release gate. Build 10 was packaged and
installed, with build 9 preserved as the immediate rollback copy. After loading
extension 0.7.2, the user live-verified that blocked websites can be added and
removed successfully from the Options tab.

### Build 11 configurable writing shortcut

The direct writing shortcut now defaults to the existing free, on-device Quick
Fix contract and can be changed in General Settings to AI Proofread. Unknown or
future stored choices fail back to Quick Fix so an upgrade cannot silently spend
provider tokens. The menu-bar tooltip and key equivalent follow the selected
action immediately. AI Proofread uses the existing provider-setup gate and
verified replacement policy; full-field changes still require preview. Reply,
compose, and tone-rewrite actions remain in the Bean menu because they need more
context. Two new persistence/action-contract tests bring the XCTest total to
323, all passing. The browser-extension audit found no global-shortcut surface:
Chrome owns extension shortcuts, while Bean's macOS shortcut is handled by the
installed app. Browser wording remains consistent with local versus optional AI
checks. Build 11 was packaged, signature/checksum/DMG verified, installed, and
its executable matches the staged candidate byte-for-byte.

## Deferred accessibility work

Bean's native type tokens still use fixed point sizes. Moving 69 usages to
semantic, accessibility-scaled text requires adaptive HStack/frame fallbacks
and normal/large-text render coverage before changing the release UI safely.
The public-beta workaround is to resize the resizable windows and use their
scroll areas. The semantic-type conversion remains in the public roadmap.

## Release decision

**Branch QA complete.** No P0 or P1 automated, artifact, privacy, security,
migration, replacement, bridge-connectivity, or cost-control failure is open.
Slack web's complex rich editor is explicitly outside the 1.6 support matrix;
plain browser fields and simple contenteditable editors remain supported.
