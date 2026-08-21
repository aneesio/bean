# Releasing Bean

Bean supports two release modes:

- an explicitly unnotarized GitHub beta that requires no Apple membership;
- a Developer ID-signed and notarized release when Apple credentials are
  available.

Publishing source code or an ad-hoc-signed DMG on GitHub does **not** require an
Apple Developer Program membership or fee. That path produces a deliberately
unnotarized build and users will encounter stronger Gatekeeper warnings.
Developer ID signing and Apple notarization do require paid Apple Developer
Program membership. Apple currently lists membership at USD 99 per year (or
local equivalent; eligible organizations may receive a waiver). Verify current
terms on Apple's [membership comparison](https://developer.apple.com/support/compare-memberships/)
before making that optional distribution investment.

| Distribution path | External account/payment | Bean release status |
| --- | --- | --- |
| Source on GitHub | None | Supported |
| Unnotarized GitHub ZIP/DMG | None | Supported public-beta path |
| Developer ID + notarized ZIP/DMG | Paid Apple membership and credentials | Packaging supported; credentials pending |
| Unpacked Chromium extension | None | Supported beta path |
| Chrome Web Store | Registered publisher and Google's current one-time fee | Optional; listing/review work pending |

## Prepare

1. Start from a clean `main` branch.
2. Update `CFBundleShortVersionString` and increment `CFBundleVersion` in
   `Resources/Info.plist`.
3. Update `CHANGELOG.md` and any behavior/privacy documentation.
4. Run:

   ```bash
   ./scripts/run_all_tests.sh
   ./scripts/build_app.sh release
   ```

5. Commit the version change before packaging.

The public tag must exactly match the app version: version `1.3.0` uses tag
`v1.3.0`.

## Unnotarized GitHub beta

```bash
BEAN_ALLOW_ADHOC_RELEASE=1 ./scripts/package_release.sh
```

This creates universal artifacts named `Bean-<version>-unnotarized.*` and a
SHA-256 file. The suffix is mandatory so users are not misled about Gatekeeper
status.

Verify locally:

```bash
lipo -archs release/Bean-<version>-unnotarized/Bean.app/Contents/MacOS/Bean
cd release
shasum -a 256 -c Bean-<version>-unnotarized.sha256
```

Pushing a matching `v*` tag runs the GitHub prerelease workflow and uploads the
DMG, ZIP, and checksums after all tests pass.

## Developer ID and notarization

Store notarization credentials in a Keychain profile and provide the exact
Developer ID Application identity:

```bash
DEVELOPER_ID_APPLICATION="Developer ID Application: Example (TEAMID)" \
APPLE_NOTARY_PROFILE="bean-notary" \
./scripts/package_release.sh
```

The script enables hardened runtime signing, submits the app to Apple's notary
service, waits for acceptance, staples and validates the ticket, creates final
artifacts, and requires Gatekeeper assessment to pass. It refuses a Developer
ID release when the notarization profile is missing.

Never commit signing certificates, private keys, App Store Connect keys, or
notarization credentials. See [SECURITY.md](SECURITY.md).

Apple's current notarization requirements include a Developer ID Application
signature, hardened runtime, a secure timestamp, and a successful notary
submission. The final artifact must carry a stapled ticket and pass both strict
signature validation and Gatekeeper assessment. See Apple's
[notarization documentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

## Chrome Web Store decision gate

The unpacked extension remains free to build, share, and test. Publishing it in
the Chrome Web Store is a separate product decision. Do not submit until every
item below is complete:

- register and secure a dedicated publisher account, accept the current terms,
  and pay Google's current one-time registration fee;
- package only the extension contents with `manifest.json` at the ZIP root and
  increment its version above the last uploaded version;
- pass the browser automated suite and the Gmail/Slack web manual matrix with a
  release build of the native app and host;
- provide store name, description, icon, screenshots, support URL, and a public
  privacy-policy URL that match actual beta behavior;
- declare the single purpose, every required/optional permission, site access,
  native messaging, local processing, provider transmission, and retention
  behavior in the Store privacy form;
- obtain prominent in-product consent before provider-backed page text is
  handled and confirm that all permissions remain the narrowest necessary;
- provide reviewer instructions for installing the native app/host and testing
  local-only and provider-backed paths; then submit for review without enabling
  automatic publishing.

Google's official guides cover [developer registration](https://developer.chrome.com/docs/webstore/register),
[extension preparation](https://developer.chrome.com/docs/webstore/prepare),
[publication](https://developer.chrome.com/docs/webstore/publish), and
[user-data disclosures](https://developer.chrome.com/docs/webstore/program-policies/user-data-faq).
The fee and policy text can change, so re-check them at submission time.

## Maintainer metadata gate

Before tagging any public release:

- confirm `CFBundleShortVersionString`, `CFBundleVersion`, the `AppInfo`
  command-line fallbacks, changelog heading, and `v<version>` tag agree;
- increment `BrowserExtension/manifest.json` whenever extension files change;
- run the update-check fixtures and manually click **Check for Updates** against
  the current public release; verify the installed version, latest tag,
  prerelease label, failure copy, and canonical release URL;
- confirm no launch hook, timer, background task, download code, or installer is
  connected to `UpdateChecker`;
- use a clean preference domain to verify Bean Bubble, Passive Suggestions,
  Inline Highlights, Web Inline Support, diagnostics, and automatic provider
  calls start off;
- review README, Privacy, release notes, DMG title, and GitHub release title so
  `unnotarized`, `prerelease`, API cost, Labs, and Gatekeeper behavior are
  described consistently.

## Publish and verify

- Confirm the release is marked prerelease while Bean remains beta.
- Include installation/Gatekeeper wording appropriate to the artifact type.
- Download the published artifacts into a clean directory and verify checksums.
- Test installation, first launch, Accessibility, one provider action, and an
  update from the previous beta.
- Keep the prior release available for rollback.
