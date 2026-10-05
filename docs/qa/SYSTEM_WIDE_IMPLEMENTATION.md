# System-wide writing milestone

Authorized scope: the complete product/quality roadmap discussed October 2,
2026. Checkpoint before implementation: `e1f4a47`. Work branch:
`codex/systemwide-quality`. Writer expansion is outside this milestone.

## Completion record

| Requirement | Implementation and evidence | Status |
| --- | --- | --- |
| Precise proofreading and rich-document preservation | Bounded minimal span plan, guarded native edits, per-span and complete verification, batch/partial Undo; rich fixtures preserve formatting, attachments and exact caret affinity | Implemented; reference-app candidate journeys remain separate |
| One native/browser assistant experience | Tiny status dot, full-target safe placement or hiding, explicit checking/basic/issues/unavailable details, click review, consistent actions/scope, keyboard focus retention; actual light/dark/narrow/short-window renders | Implemented; external browser/VoiceOver transport not certified |
| Writing judgment | Family-isolated 1,024-case synthetic benchmark, dialects, entity/negation/commitment safeguards; final precision 100%, recall 91.57%, preferred correction 98.52% | Implemented; strict heldout correction gate fails (92.5% vs 99%); human/provider review remains pending |
| Editor-family compatibility | AppKit/WebKit/DOM journeys, interruption/clipboard/caret/Undo/composition cases; 23 owned web-editor/overlay tests pass without skips | Implemented; five own-process AX web-area tests unavailable in this host; reference apps remain separate |
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

Latest build 16 combined checks: `scripts/run_all_tests.sh` passed 610 Swift
test cases (602 passed, eight skipped), all 13 browser suites, standalone logic,
shell syntax, release metadata and repository audit. The skips are five
unavailable own-process AX web-area fixtures, one SwiftUI descendant fixture
whose plain Button baseline also lacks AX descendants, and two opt-in
evaluations. Native replacement and Undo recovery additionally pass 95 focused tests,
including owned rich AppKit selected-text edits and native Undo. The actual
macOS quality evaluation was run separately; the provider dry run generated
36 review plans with zero requests. See [writing-quality evidence](WRITING_QUALITY_2026-10-02.md)
for provenance, exact counts and the failing strict quality gate. These results
do not certify universal editor support or Grammarly parity.

Build 13 was packaged and installed from `6d4acb3`; strict signatures, universal
architectures, matching installed/ZIP/DMG executables, checksum verification,
mounted DMG documents and all three private fault suites passed. See the
[candidate QA record](QA_RESULTS_1.7.0.md) for exact hashes, retained rollback
bundles, installed UI observations and outstanding validation.

The live build 13 TextEdit replacement failed and damaged a synthetic word; the
source fixture was restored. Build 14 adds capability-based selected-text edits,
settled selection proof, captured-process fallback commands and no retry after
unconfirmed delivery. The [candidate QA record](QA_RESULTS_1.7.0.md) distinguishes
owned regression passes from the required installed-app retest.

Build 14 repair source `f52e35d` was packaged and installed; actual Settings
shows 1.7.0 (14). Universal payload, strict signatures, ZIP/DMG byte identity,
checksums, staged support documents and three private fault suites pass. The
prior installed build 13 is retained for rollback. The user completed the
physical Touch ID/Accessibility refresh and actual General reports ready. The
required installed TextEdit replacement/Undo result follows separately from
owned automated tests.

Actual build 14 hardware Quick Fix corrected both synthetic TextEdit typos;
unchanged bold text, emoji/date/time/email, original caret, native Undo/Redo and
Bean one-action Undo all pass by direct AX/pixel observation. The reported
TextEdit corruption is resolved for that journey. A final recovery review found
additional uncertain-delivery/Undo retry boundaries. Build 15 fixes those
boundaries, serializes Undo ownership and prevents a browser queued-handler
duplicate fallback. Independent source reviews and the combined checks pass.
Build 15 packaging and installed-path evidence are recorded separately; the
strict writing-quality gate and broader real-app certification remain open.


Final build 15 source `dcb3b2f` was packaged. Universal payload, strict signatures,
ZIP/DMG byte identity, checksums, all 30 extension files and eight mounted DMG
support documents pass. Build 15 is now installed and verified; the previous build 14 is retained for
rollback. See the candidate record for exact hashes and live-test status.


Build 15 also passed all three private fault suites without changing its
candidate bundle. Actual build 15 General reports Accessibility ready after the user refreshed
the existing grant. Direct AX/pixel observation confirms both TextEdit typos
corrected, rich content and caret preserved, and Bean one-action Undo restoring
the complete original. The owned fixture was saved/closed; AI Proofread and
Deeper AI on were restored. The user reports extension reload/page refresh; no
independent Chrome 0.8.1 transport pass is claimed.


The accepted milestone's feature implementations are present; quality outcomes
are not all complete. The known strict heldout preferred-correction failure
requires principled ranking work and fresh independent evaluation. Development
suggestions are already 488/488 correct, so changing weights to fit known
heldout failures is not justified. Real provider/human evaluation, broader
candidate app/VoiceOver journeys, live latency and edit reliability remain open.
Historical roadmap items outside this accepted milestone are not claimed done.

Build 16 addresses the October 5 field-control obstruction feedback in both the
native app and extension 0.8.2. A 10-point/pixel gray/amber dot retains a clear
28-point/pixel target. Exact bounded field/window/viewport and nearby-control
geometry must prove the entire target fits outside the editor; otherwise it
hides without guessed anchors. Native legacy drag and launcher ownership follow
the same rule. Independent review, native geometry/refresh/paint regressions and
real owned WebKit crowded-composer/corner hit tests pass. This evidence does not
certify third-party AX placement or physical Chrome delivery. See the candidate
record for the final verification and activation state.
