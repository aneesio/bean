# Contributing to Bean

Thank you for helping make Bean safer and more reliable.

## Before starting

- Search existing issues before opening a new one.
- Use synthetic text in bug reports and tests. Never post API keys or private
  writing.
- Discuss large features, new providers, or architecture changes in an issue
  before implementation.
- Keep experimental behavior off by default and avoid background provider calls
  without an explicit, cost-aware opt-in.

## Local setup

Requirements are macOS 13 or newer and current Xcode or Apple Command Line
Tools.

```bash
swift test
node BrowserExtension/test/run-tests.js
./scripts/build_app.sh debug
```

The first app launch requires Accessibility permission. Run the app from a
stable path while testing permission persistence.

## Pull requests

1. Create a focused branch from `main`.
2. Add regression tests for behavior changes.
3. Run Swift, browser, build, and repository audits locally.
4. Update README, privacy, security, or support documentation when behavior or
   data flow changes.
5. Explain manual testing, especially the apps and macOS versions exercised.

Keep pull requests narrowly scoped. Avoid unrelated formatting or generated
release files. CI must pass before merge.

## Safety requirements

- Never log selected text, model prompts/responses, API keys, or clipboard data.
- Treat source text, browser page data, style examples, and context cards as
  untrusted data rather than instructions.
- Verify the live target before replacing text and preserve content outside the
  intended range.
- Restore the clipboard unless the user is explicitly told that a correction
  was left there as a fallback.
- Use the least browser and macOS permissions needed for current behavior.
- Keep provider requests bounded by time, input size, and output size.

## Style

Prefer straightforward Swift and platform APIs over new dependencies. Keep UI
copy honest about beta coverage and provider cost. Run `bash -n` on changed shell
scripts and avoid commands that depend on a newer shell than macOS provides.

Contributions are accepted under the repository's [MIT License](LICENSE.md).
