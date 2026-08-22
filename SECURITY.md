# Security Policy

## Supported versions

Security fixes are applied to the latest public beta release and the `main`
branch. Older beta artifacts are not supported.

## Report a vulnerability privately

Do not open a public issue for a suspected vulnerability. Email
`hello@anees.io` with the subject **Bean security report** and include:

- the affected version or commit;
- reproduction steps and impact;
- whether the report involves provider keys or user text;
- a safe way to contact you.

Do not include real API keys, private writing, or third-party data. Use synthetic
examples. You should receive an acknowledgement within seven days. The project
will coordinate disclosure after a fix is available; a 90-day disclosure window
is the default unless active exploitation requires a faster response.

## Security boundaries

- Accessibility permission is powerful. Bean limits normal actions to selected
  text or a guarded focused editable field, but macOS grants permission at the
  application level.
- API keys belong in Keychain and must never be committed, logged, included in
  diagnostics, or stored by the browser extension.
- Native messaging accepts only defined JSON message types with bounded payloads
  and an extension-origin allowlist installed on the local Mac. Website access
  is separate: local checks work broadly, with user-controlled blocked sites.
- Changes affecting text acquisition, replacement, model-output sanitization,
  native messaging, Keychain access, or release signing require regression tests
  and explicit review.

See [PRIVACY.md](PRIVACY.md) for the data-flow description.
