# Writing quality benchmark — 2026-10-02

This measures local rules and the actual macOS dictionaries on macOS 26.6.2 (25G83). It does not certify Grammarly parity, real-provider output, meaning preservation, or any host application's editing behavior.

## Fixture and provenance

`Tests/Fixtures/WritingQuality/corpus-v1.jsonl` contains 1,024 synthetic cases expanded from 128 agent-curated annotated seed families, including 400 clean controls and 664 error occurrences. It covers email/chat/prose, Canadian/US/UK spelling, names and saved terms, links/code, repeated words, Unicode, multiline structure, and a few short non-English controls. It contains no personal writing or provider responses. The independently reproducible generator is `scripts/generate_quality_corpus.py`.

SHA256: `b7c518c742d844794cbef69ba740e30afae8588997d3b01fbb2dff9957a647c2`.

Development: 824 cases/320 clean controls/536 annotations. Heldout: 200 cases/80 clean controls/128 annotations. Every fifth entire seed family is held out; variants never cross splits. Context variants are correlated, and some error patterns recur across families. The heldout split is a regression holdout, not independent evidence of broad generalization. The corpus has not been human reviewed.

A development investigation found the generator had wrapped intentional indentation/trailing Markdown spaces inline and thereby manufactured unlabeled errors. That expansion was corrected before freezing this hash. Both comparison runs below use the corrected identical fixture. Old preliminary scores from the superseded fixture are excluded.

Checkpoint `e1f4a47` was archived into an isolated temporary checkout/build. Only the evaluator, frozen fixture, dialect enum, and a mechanical dialect argument passed to the old macOS checker were added; its checker rules, ranking, and mapping remained unchanged. No shared working-tree build or live app data was involved. The tuned code was evaluated on the same Mac. See JSON evidence under `docs/qa/quality/` for exact counts and failure IDs.

## Results

Precision means returned findings matching an annotated error. Recall includes all annotated types, including grammar the local checker cannot address. Correction accuracy means its preferred suggestion exactly matches an accepted annotation; this is stricter than merely detecting the word or offering an acceptable alternative. Clean retention is the fraction of clean cases producing zero findings.

| Engine / split | Precision | Recall | Preferred correction accuracy | Clean retention |
| --- | ---: | ---: | ---: | ---: |
| Checkpoint local + macOS, overall | 88.97% | 77.71% | 95.35% | 88.00% |
| Tuned local + macOS, overall | 100.00% | 91.57% | 98.52% | 100.00% |
| Checkpoint development | 92.08% | 75.93% | 95.33% | 90.94% |
| Tuned development | 100.00% | 91.04% | 100.00% | 100.00% |
| Checkpoint heldout | 78.99% | 85.16% | 95.41% | 76.25% |
| Tuned heldout | 100.00% | 93.75% | 92.50% | 100.00% |
| Tuned deterministic rules only, overall | 100.00% | 59.04% | 100.00% | 100.00% |

Tuned returned 608 true findings, zero false alarms, 56 misses and nine incorrectly preferred spelling suggestions. Heldout preferred correction accuracy decreased; that regression is retained in the report rather than tuned away after seeing heldout results. Actual provider evaluation and language review must resolve it before a quality certification.

| Tuned error type | Precision | Recall | Preferred correction accuracy |
| --- | ---: | ---: | ---: |
| Spelling | 100.00% | 100.00% | 97.50% |
| Basic grammar | 100.00% | 70.83% | 100.00% |
| Capitalization | 100.00% | 100.00% | 100.00% |
| Punctuation | 100.00% | 100.00% | 100.00% |
| Spacing | 100.00% | 100.00% | 100.00% |

Deterministic rules contributed 392 findings, all correct in this fixture. The macOS checker contributed 216 findings with 95.83% preferred correction accuracy. Source recall is undefined because a missed annotation has no returned source; the persisted report uses null rather than a fabricated 100% source recall.

Scan-only latency: checkpoint p50 1.99ms / p95 15.46ms / max 37.17ms; tuned p50 4.42ms / p95 20.35ms / max 40.18ms. These timings exclude debounce, accessibility/DOM capture, UI rendering, provider calls, and replacement. They are specific to the measured Mac, not a user-visible latency guarantee.

Synthetic candidate replay now safely mapped 615/664 annotated edits (92.62%) with zero incorrect edits. The old mapper replayed 485/664 (73.04%). This only tests exact range/whole-token/context mapping, never model judgment. Ambiguous/unsafe candidates can still be intentionally refused.

## Changes measured

The tuned checker preserves valid regional spelling by consulting the installed English dictionaries, resolves AppKit's American-English `en` service alias, avoids forcing confidently detected non-English writing through English rules, preserves Markdown marker indentation, and adds bounded clause-opening pronoun agreement. Ranking adjusts generic edit costs for vowel errors; no corpus-specific typo entries were added. Repeated model candidates require uniquely verified adjacent context instead of untrusted model offsets.

A full-suite regression exposed inflated language confidence from repeating a short typo-heavy fragment. Switching away from the requested spelling convention now requires agreeing strong evidence from the original text and its distinct lexical tokens. This restores the existing repeated-typo correction test while retaining strongly identified short/repeated French writing. It recovered two development findings; the frozen corpus and heldout behavior are unchanged. The focused language/quality suite passed 51 tests with one expected opt-in system benchmark skip.

Concrete proofreading/rewrite safeguards preserve literal links, code, numbers, saved terms, narrowly recognizable names/dates, negation and commitment markers. These bounded checks can miss semantic changes and can reject valid uncommon paraphrases. They do not establish meaning preservation. Tests include accepted idioms and contractions to reduce obvious false blocks, plus explicit harmful edits.

Local scan coverage is separate from linguistic recall. Service unavailability, invalid responses, and bounded finding/sentence scans are exposed as partial coverage. A completed scan with no findings means only that these checks found no issues.

## Release gates and next evidence

Run `scripts/run_quality_benchmark.sh --enforce [report-directory]` on the release Mac (set `BEAN_DISABLE_SWIFTPM_SANDBOX=1` only when the test environment requires it). It fails when the required spelling service is unavailable, or either split is below precision 97%, recall 85%, preferred correction accuracy 99%, clean retention 99%, or overall scan p95 exceeds 750ms. The current strict gate **fails** heldout preferred correction accuracy; gates were not lowered to fit these results.

The final actual macOS run passed 4/4 tests (`build/quality-final`). The enforced rerun produced exactly one failure, heldout correction 92.5% below 99% (`build/quality-final-gate`). Both scripts were exercised with Apple's Bash 3.2 and the sandbox override unset; their argument arrays are nonempty under `set -u`.

Before certifying writing quality: independently human-review these labels and add a separately licensed, human-reviewed external corpus; evaluate each real provider/model in its actual production prompts with consented/synthetic inputs and a fixed cost budget; score correction correctness, false alarms, unnecessary edits, meaning changes and dialect retention blind to model identity; separately measure native/browser replacement success and undo on owned fixtures and unsent app drafts. No paid calls were made for this work.

## Browser dictionary and coverage backend

`DictionaryLearningService` runs a bounded local CFMessagePort endpoint in the GUI process. Browser Learn word requests use one validated spelling token (96-character ceiling), an acknowledged GUI `UserContentStore.upsert`, and an injectable test learner. The native host never writes a competing user-content snapshot. A missing GUI, invalid word, or persistence failure returns an honest error; there is no secondary file fallback. This prevents later GUI personalization edits from overwriting a just-learned word.

Offline browser checks expose exact UTF-16 protected spans, spelling/grammar scan completeness, and unavailable/bounded/invalid scan reasons separately from findings. `getStatus` exposes the authenticated calling browser's per-app pause. Paused browsers reject automatic local checks and automatic provider messages before work; manual native shortcuts and explicit provider actions retain their separate scope. Browser frontend requests still require its trusted-activation and exact-document/snapshot authorization checks.

Focused backend and prompt/meaning integrity tests passed 44/44, including an actual local GUI IPC round trip to an isolated store, duplicate learning, subsequent GUI edits retaining the learned term, failed-write rollback, missing endpoint, bounded term validation, exact UTF-16 protected spans, isolated pause timestamps, and protocol responses. Complete protected spans are merged into an exact union rather than truncated; a 300-span regression verifies that a saved word after those spans remains protected. Source relevance is selected across the bounded 5,000-term dictionary before prompt/guard inclusion caps, with after-200 and Unicode regressions. No live dictionary or personal writing was edited. The production installed-extension/app interaction remains a separate integration check.

An additional meaning regression rejects moving a negative marker between aligned proofreading statements even when its overall count stays equal (`I do not want delays. We can ship today.` → `I do want delays. We cannot ship today.`). Rewrite sentence reordering is outside that narrow aligned-statement check.

## Opt-in provider evaluation tooling

`scripts/run_provider_quality_evaluation.sh --dry-run [new-output-directory]` constructs the production issue/transform prompts for a deterministic round-robin sample of unique synthetic families and writes reviewable plans. The executed dry run passed 5/5 policy/harness tests, selected 12 families across both splits and chat/email/prose, produced 36 planned detection/proofreading/clearer-rewrite records, and made zero API calls. Evidence: `/private/tmp/bean-provider-evaluation-dry-run-final`; a final default-environment Bash 3.2 rerun also passed 5/5 in `/private/tmp/bean-provider-evaluation-bash32-default`. Normal CI skips the external harness before configuration/key access.

A paid run uses `--paid` only after explicit authorization and requires all of: `BEAN_EVAL_ALLOW_PAID=YES`, `BEAN_EVAL_MAX_REQUESTS` (1–40), `BEAN_EVAL_MAX_ESTIMATED_USD` (positive, at most 5), `BEAN_EVAL_INPUT_USD_PER_MILLION`, `BEAN_EVAL_OUTPUT_USD_PER_MILLION`, and `BEAN_EVAL_PRICING_REFERENCE` describing the current independently verified official pricing source. Supply `BEAN_EVAL_PROVIDER`, `BEAN_EVAL_MODEL`, and `BEAN_EVAL_API_KEY` through the environment, or set `BEAN_EVAL_USE_VERIFIED_BEAN_PROVIDER=YES` to use Bean's verified selected pair. That option accesses settings/Keychain only after paid authorization/budget validation and revalidates the captured pair before each attempt. Dry-run ignores it and never reads settings or keys. No key is serialized, echoed or logged. `BEAN_EVAL_MAX_CASES` defaults to 12 (ceiling 100); the independent request/budget caps still win.

The per-request estimate reserves one input token per request UTF-8 byte plus 2,048 framing tokens and the production output-token ceiling at the supplied rates. Failed calls retain that reserved estimate because billing can occur without returned usage. There is no retry; the run stops on its request/cost envelope, changed verified configuration, two provider failures, accounting failure or unexpectedly high returned usage. The cost envelope is an explicitly configured estimate, not a billing guarantee or live pricing lookup.

Actual attempts, successful/failed settlements and provider-reported/estimated tokens are recorded through Bean's manual reservation/usage accounting in an isolated QA store. Evaluation never writes user histories or personalization. `run-metadata.json` holds model identity, prices, provenance and measured usage; keep it separate from reviewers. `blind-review.jsonl` contains only synthetic source text, annotations, actual raw/sanitized provider output, exact mapped findings/safety decisions, and empty human-rating fields. Existing output directories are refused to protect earlier human ratings. Exact annotation matches and deterministic safety decisions supplement independent language/meaning/dialect ratings; they do not replace those ratings.

No paid/provider run has been performed. The runner makes that external gate executable and reviewable; it does not establish provider quality by itself.
