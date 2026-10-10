# Bean green rebrand verification

Date: October 7, 2026. Local Bean 1.7.0 (20), Chromium extension 0.8.6.

## Final appearance

The active Mac app, extension, and editable SVG use Bean Green `#237A48`,
with `#81DCA5` for dark appearance. Warning text, indicators, and native
warning fills also use green. Source audits found no remaining custom brown,
amber, violet, or purple palette values. Errors retain clear red/rose cues;
the bean retains its intentional pale yellow seed scar and green shading.
Historical artwork, release records, and writing samples were preserved.

Action buttons share a capsule shape across the native app and browser, with
green primary actions and quiet secondary actions. Native macOS 14+ styles
preserve system interaction behavior; macOS 13 uses a capsule ButtonStyle
fallback. Cards, navigation, inputs, inline dots, and underline targets retain
geometry appropriate to their roles. Browser dictionary actions have an 8px
gap before the footer actions.

Every app and browser resolution was regenerated from `Resources/Icons/AppIcon.svg`.
The ten macOS icon sizes, four extension sizes, ICNS, 1024-pixel preview, and
matching monochrome menu-bar template were verified. The SVG remains editable
vector artwork. Icon inspection confirmed transparent corners, no stray pixels
outside the tile, and legibility at small sizes.

## Automated checks

The final `scripts/run_all_tests.sh` run passed: **646 XCTest cases, 8 skipped,
zero failures**, plus standalone logic checks, all 14 browser test groups,
shell syntax, release metadata, and repository audit. Final log:
`/tmp/bean-green-all-tests-capsule-final.log`.

The eight skips are six unavailable Accessibility test-host fixtures, one
opt-in external-provider evaluation requiring an explicit budget, and one
opt-in macOS quality benchmark. They are not reported as passes. This rebrand run made no paid
provider evaluation requests or universal third-party app certification claim.

Native and browser palette tests verify production text, controls, selected
rows, warning/error pills, and issue marks in both appearances. Warning pill
text contrast is 4.65:1 in light appearance and 7.14:1 in dark appearance.
All 39 exported native/browser renders were visually reviewed, including HUD
Cancel/Undo controls and narrow/desktop light/dark cards. The focus-preservation
regression also exercised actionable HUDs. Separate capsule previews verified
native and forced macOS 13 fallback styling in both appearances, including
disabled controls. The fallback compiles targeting macOS 13; this host did not
run macOS 13 itself.

Twenty actual Settings, onboarding, and Workspace snapshots were generated and
independently visually reviewed using isolated preferences and temporary stores with no keychain reader or
provider requests. The offscreen Settings sidebar was uncaptured by native
readback; the installed sidebar was checked separately. Popup/Options and
warning pills were checked through source, contrast tests, and installed UI.

Exports: `/tmp/bean-build20-native-visuals-capsule-final`,
`/tmp/bean-build20-browser-visuals-capsule-final`, `/tmp/BeanButtonQA`, and
`/tmp/BeanActualViews`. SVG XML validation, icon structure
audit, and `git diff --check` passed. Build publication, release packaging,
and local installation fault suites also passed during this rebrand work.

## Build, installation, and live observations

The final release build and local installation succeeded. The installed
`/Applications/Bean.app` is byte-identical to `build/Bean.app`; its bundled
extension is byte-identical to `BrowserExtension`. Strict deep signature
verification passed. This is a locally signed ad hoc candidate.

Logs: `/tmp/bean-green-build-capsule-final.log` and
`/tmp/bean-green-install-capsule-final.log`. The immediate verified rollback
is `build/installed-backups/installed.M5sUfV/Bean.app`.

The running app showed Version 1.7.0 (20). Its permission warning rendered
green. Writing settings retained the user's enabled switches and green
controls. After the user authenticated the existing Accessibility grant refresh,
Bean was relaunched from `/Applications/Bean.app`. The final installed capsule
build explicitly reported “Accessibility is ready” and “AI connected.”

The existing unpacked extension was reloaded in both Chrome profiles where
Bean was installed. Its path, ID, permissions, and user settings were retained.
Popup/Options showed the green-bean icon and a connected Bean 1.7.0 host.
The previously violet automatic-AI warning dot was visually confirmed green.

The final installed General/Writing/Browser settings and browser popup/Options were
inspected in Dark appearance. Mint accents, green warning labels, neutral/forest
surfaces, primary/secondary capsules, and text remained legible. macOS
Appearance was restored from Dark to the user's original Automatic setting,
and the browser Options page was inspected again in light appearance. No
provider credentials, writing preferences, or browser site controls were changed.

The pre-install Browser setup Menu is hidden once the Mac connection is installed.
Its actual view code was checked onscreen in a separate temporary app with a
synthetic three-browser setup state and no-op actions. With matching AppKit and
SwiftUI Dark appearance, the Menu label, chevron, and opened browser choices were
legible. The earlier black-on-dark offscreen readback did not reproduce; its
AppKit appearance had not matched the SwiftUI environment. This fixture did not
access the installed bridge or change Bean's user preferences.

Already-open websites can retain their previously injected styling until a
full page refresh/navigation. Extension reload updates popup/Options and
future documents; it does not replace old closed shadow roots. No personal
drafts or real website pages were refreshed during verification. Save any
open draft before refreshing its page to load the updated inline UI.
