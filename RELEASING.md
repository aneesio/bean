# Releasing Bean

Bean supports two release modes:

- an explicitly unnotarized GitHub beta that requires no Apple membership;
- a Developer ID-signed and notarized release when Apple credentials are
  available.

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

The public tag must exactly match the app version: version `1.2.0` uses tag
`v1.2.0`.

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

## Publish and verify

- Confirm the release is marked prerelease while Bean remains beta.
- Include installation/Gatekeeper wording appropriate to the artifact type.
- Download the published artifacts into a clean directory and verify checksums.
- Test installation, first launch, Accessibility, one provider action, and an
  update from the previous beta.
- Keep the prior release available for rollback.
