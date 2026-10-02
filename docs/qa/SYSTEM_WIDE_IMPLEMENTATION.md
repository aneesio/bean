# System-wide writing milestone

Authorized scope: the complete product/quality roadmap discussed October 2,
2026. Checkpoint before implementation: `e1f4a47`. Work branch:
`codex/systemwide-quality`. Writer expansion is outside this milestone.

## Completion record

| Requirement | Implementation and evidence | Status |
| --- | --- | --- |
| Precise proofreading and rich-document preservation | Bounded minimal span plan, guarded native edits, per-span and complete verification, batch/partial Undo; rich fixtures preserve formatting, attachments and exact caret affinity | Implemented; reference-app candidate journeys remain separate |
| One native/browser assistant experience | Quiet badge, explicit checking/basic/issues/unavailable states, click review, consistent actions/scope, keyboard focus retention; actual light/dark/narrow/short-window renders | Implemented; external browser/VoiceOver transport not certified |
| Writing judgment | Family-isolated 1,024-case synthetic benchmark, dialects, entity/negation/commitment safeguards; final precision 100%, recall 91.57%, preferred correction 98.52% | Implemented; strict heldout correction gate fails (92.5% vs 99%); human/provider review remains pending |
| Editor-family compatibility | AppKit/WebKit/DOM journeys, interruption/clipboard/caret/Undo/composition cases; 18 owned web-editor/overlay tests pass without skips | Implemented; five own-process AX web-area tests unavailable in this host; reference apps remain separate |
| Speed and attention | Bounded native/browser timings, cancellation, content-free CPU/RSS profiler; scan p95 20.35ms; synthetic browser pipeline distinguishes debounce from scan time | Implemented instrumentation; actual feedback/acceptance p95 goals remain unmeasured |
| Vocabulary and dismissal | GUI-owned persisted dictionary learning, acknowledged browser IPC, stable occurrence dismissal with Unicode word-boundary invalidation, shared dialect | Implemented and covered by fixture/IPC tests |
| Pause/resume | One-hour or indefinite app pause; website controls/expiry; permanent blocked-site content-free focus guard; five-second app status refresh | Implemented; explicit manual actions retained |
| Paragraph rewrite and Fix All | Exact captured paragraph scope, immutable explicit selection per open review, fresh scope on reopening; deterministic-only verified Fix All | Implemented and tested |
| Installation and rollback | Verified temporary bundle/artifact publication, prior-build preservation, exclusive locks, fault-injected signed install/build/package fixtures | Implemented; production candidate verification recorded separately |
| Developer ID signing/notarization | No valid identity; user has no Developer Program account | Explicitly postponed by user |

## Verification rules

Every claim needs a reproducible command, test, or recorded observation.
Skipped GUI/editor tests are not passes. Synthetic expected answers are not
human-reviewed correction evidence, and mock provider output does not establish
real AI judgment. Preserve exact UTF-16 text, surrounding rich content and new
user clipboard/caret changes. Record supported paths and safe refusals separately
when measuring edit success.

Development goals: at least 97% suggestion precision, 90% common spelling-error
recall, 99.5% verified edits on declared supported paths, local feedback p95 at
most 750 ms from committed input, simple acceptance p95 at most 500 ms, and zero
wrong-target/data-loss/critical-meaning cases in the release corpus. These are
goals rather than claims about current behavior.

No personal writing or paid provider requests are needed for the automated
work. Developer signing and notarization are deferred, so local candidates must
remain truthfully labelled ad hoc and unnotarized.

Final combined checks: `scripts/run_all_tests.sh` passed 566 Swift test cases
(559 passed, seven skipped), all 13 browser suites, standalone logic, shell
syntax, release metadata and repository audit. The skips are five unavailable
own-process AX web-area tests and two explicitly opt-in evaluations. The actual
macOS quality evaluation was run separately; the provider dry-run generated
36 review plans with zero requests. See [writing-quality evidence](WRITING_QUALITY_2026-10-02.md)
for provenance, exact counts and the failing strict quality gate. These results
do not certify universal editor support or Grammarly parity.

Build 13 was packaged and installed from `6d4acb3`; strict signatures, universal
architectures, matching installed/ZIP/DMG executables, checksum verification,
mounted DMG documents and all three private fault suites passed. See the
[candidate QA record](QA_RESULTS_1.7.0.md) for exact hashes, retained rollback
bundles, installed UI observations and outstanding validation.
