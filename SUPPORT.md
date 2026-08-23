# Bean Support

Bean is a community-supported, open-source public beta. There is no Bean account,
hosted support portal, background telemetry, or automatic diagnostic upload.

## Start with Bean's repair cards

Open **Settings → Privacy & Help → Help**. Bean checks content-free setup state and
offers focused repair cards when it detects a missing Accessibility permission,
an unstable app location, multiple running copies, or Mac-side browser connection
files that need attention. An optional browser extension that is not enabled is
not treated as a broken setup. These Mac-side checks do not claim a live browser
handshake: open Bean's browser toolbar icon and choose **Check again** to verify
the live extension-to-app connection.

For a field-specific problem, focus the field and choose **Bean → Help → Check
Current Field** from the menu bar. The check records field capability metadata;
it does not read or store the field's text.

## Diagnostics and support reports are different

- **Copy Diagnostics Summary** copies only Bean's content-free operational
  summary. It does not open a browser or submit anything.
- **Preview Support Report** shows a report template and the diagnostics summary
  together. Bean does not save, copy, or upload the preview. Review every line,
  then separately choose whether to copy it or open the GitHub bug form.
- Opening GitHub never attaches the preview automatically. Paste only the lines
  you intend to make public.

The report may include app names/bundle identifiers, versions, feature states,
counts, result codes, and recent content-free operation metadata. It excludes API
keys, source text, transformed text, prompts, provider responses, clipboard
contents, window titles, and field labels/values.

## Before filing a bug

1. Check [SUPPORTED_APPS.md](SUPPORTED_APPS.md).
2. Confirm Bean is at `/Applications/Bean.app` and only one copy is running.
3. Confirm Accessibility is allowed in System Settings.
4. Reproduce with a short synthetic sentence.
5. Run **Check Current Field** while the failing editor is focused.
6. Preview the Support Report and remove anything you do not want public.
7. Open the [GitHub bug form](https://github.com/aneesio/bean/issues/new?template=bug.yml).

Include Bean 1.6.0 (8) or the relevant commit, macOS version, source app/version,
action used, expected result, actual result, and the reviewed report. For
unexpected provider cost, include the AI & Usage source breakdown and automatic
call count—not a provider invoice or account identifier.

Never post an API key, private writing, clipboard contents, provider request or
response body, personal hostname, or sensitive screenshot.

## Full Reset

**Settings → Privacy & Help → Full Reset Bean…** removes Bean's provider keys,
user-content files and Bean-generated backups, usage and operation history,
private automatic-call state, preferences/onboarding state, login registration,
exact native-messaging host manifests, and manual extension approvals. Cleanup is
verified in order. Bean quits only after every removable area succeeds; a partial
failure names the affected area, lists areas already removed, and does not claim
completion or roll completed cleanup back. If personalization cleanup fails,
some Bean-owned artifacts may already have been removed before the failure.

The Mac app cannot revoke its own Accessibility authorization. Remove or disable
Bean manually in **System Settings → Privacy & Security → Accessibility** if
desired. Full Reset also cannot uninstall the Chrome extension or erase its own
local settings and blocked-sites list; clear or remove the extension in the
browser separately.

## Project and security channels

- Reproducible bugs: [GitHub Issues](https://github.com/aneesio/bean/issues)
- Focused feature proposals: use the GitHub proposal form
- Privacy questions: `hello@anees.io`
- Security vulnerabilities: follow [SECURITY.md](SECURITY.md) and report them
  privately; do not open a public issue

Community support is best effort. No response time, compatibility guarantee, or
provider-billing reimbursement is promised.
