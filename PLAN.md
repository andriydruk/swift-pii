# Swift Presidio — Build Plan (macOS first)

**Status:** M0–M4 shipped. M5 partly. M6 not started.

This was written before any code existed, as a forecast. Most of it has now
happened, so it is kept in two halves: what is left to do, and what the forecast
got wrong. The second half is the more useful one — the estimates were mostly
sound and the *risk register* was mostly not, which is a pattern worth carrying
into whatever comes next.

**Numbers live in [docs/presidio-parity.md](docs/presidio-parity.md), not here.**
This file once carried corpus sizes and a fidelity percentage; both went stale and
one of them (a 16,671-case total) survived several corpus changes before anyone
noticed it was the exact sum of a table that had since grown twice over. A plan that restates
measurements becomes a second place for them to rot.

**Constraints carried forward, all still holding:** pure Swift + vendored
open-source C permitted · no Apple closed-source frameworks · NER must match
spaCy.

---

## 1. Where this stands

| Milestone | Estimate | State |
|---|---|---|
| **M0** — foundations, conformance harness | 4 pw | **done.** Offset model, harvested corpus, table-driven runner, CI with the §4 guardrails. |
| **M1** — regex substrate, deterministic recognizers | 9 pw | **done.** Pure-Swift engine ([ADR 0001](docs/decisions/0001-regex-backend.md)), patterns as data, checksum validators, IBAN. |
| **M2** — anonymizer | 3 pw | **done.** Operators, AES-CBC via swift-crypto, span rewriting. |
| **M3** — tokenizer + NER, composed | 6 pw | **done, and then some.** Tokenizer, NER, tagger, attribute ruler, rule lemmatizer, edit-tree lemmatizer, dependency parser. Eight languages, every stage exact. |
| **M4** — engine, context, config | 5 pw | **done.** `AnalyzerEngine`, context enhancer, dedup with a documented total order, YAML config, phone matcher with full metadata. |
| **M5** — hardening | 4 pw | **done.** API review, error taxonomy, concurrency audit, docs, perf pass. |
| **M6** — Android, Windows | 6–10 pw | **not started.** A non-blocking Linux canary runs in CI. |

Three things landed that the plan did not ask for, because measurement kept
finding the next thing rather than the plan predicting it:

- **The dependency parser.** Nowhere in this document. It turned out to be the
  only thing standing between the port and exact NER — spaCy will not let an
  entity cross a sentence boundary, and that is where the boundaries come from.
- **The attribute ruler, properly.** M3 needed coarse POS for lemmas and got a
  flattened approximation that was good enough for lemmas and wrong for POS.
- **Seven more languages.** The plan scoped English only (§5 decision 4).

---

## 2. What the forecast got wrong

**The effort estimates were roughly right; the *shape* of the work was not.**
M3 was called "the highest-value milestone and the one carrying real unvalidated
risk", and that was correct — but the risk it named (tokenizer↔NER composition)
was not the one that bit. Composition was exact almost immediately. What cost
real time was three successive wrong explanations for a residual 4-in-2,592
divergence: float accumulation order, then "plausible spans", then finally
sentence boundaries. Each was plausible, each was recorded as fact, and none had
been tested.

**The risk register named six risks. The two that materialised were the ones
phrased as certainties, not as risks.**

| Predicted | What happened |
|---|---|
| Tokenizer↔NER composition diverges | No. Exact once composed. |
| Regex backend picked before the differential test exists | No — the test was built first, as planned. |
| Offset model wrong → silently wrong spans | No. The property tests held. |
| Fixture extractor rebuild underestimated | No. But its *shape* was too narrow: 44 tables sat behind "unsupported shape" while the docs called them infrastructure, and a third of them were not. |
| Effort estimate too tight | Unresolved — no one tracked actual effort against it. |
| Windows hard at M6 | Untested. |

The two that actually cost the most were unlisted: **explanations recorded
without being tested**, and **artifacts that describe their own coverage
inaccurately** — in both directions. The corpus once overstated what it covered;
a later artifact overstated the gap.

**The one prediction that paid off exactly as written** was the fourth landmine
in the original survey of upstream's suite: a green run can mean *nothing ran*. That has now been caught three separate times — the English NER
suite running nowhere for months, a sanitizer job passing with a real race
present, and CI steps that grepped for suite names when swift-testing prints the
name on a *skip*. Every measurement in CI is now grepped for by its printed value.

---

## 3. What is left

Two things, and one closed item kept for its negative result — those get
repeated when nobody writes them down.

### M5 — closed

Done: the API review (the README now says which products are surface and which
are machinery, and why the surface is larger than a PII library's needs to be),
the error taxonomy (three domains, distinguished by who can act on the failure),
both layering asymmetries, and a perf pass.

The perf pass is worth recording because it found nothing. The transition loop's
~2N heap allocations per document looked like the obvious target and hoisting
them out changed nothing measurable; one step is 6,784 multiply-accumulates
against two 64-float allocations. The change was reverted and the arithmetic is
written down in `presidio-bench` so the next person does not spend the afternoon
on it. The remaining lever in the engine is still `PhoneRecognizer`, at ~72% of
the pattern-only cost, and it is structural: one scan per configured region.

### Harvest: 32 upstream tables

Recorded with reasons in the corpus artifacts. Five are reachable by resolving a
pytest fixture to its constructor arguments; the rest is configuration, ONNX and
device selection, serialization round-trips, and recognizers this port does not
ship. Judgement so far has been that five tables do not justify a fixture
resolver.

### M6 — platform expansion

Unchanged from the original assessment, and the Linux canary has been green
throughout. **Windows still has zero evidence of any kind.** Android is the safer
of the two.

---

## 4. Cheap guardrails so "macOS first" doesn't become "macOS only"

All three are in CI and all three have caught something.

1. **CI lint banning Apple-framework imports** (`NaturalLanguage`, `CoreML`,
   `Vision`, `CryptoKit`, `TabularData`, `CommonCrypto`). `Accelerate` came off
   the flat ban and onto a different rule: allowed in
   `Sources/PresidioNLP/GEMM.swift` only, only under
   `#if PresidioAccelerate && canImport(Accelerate)`, with the portable kernel
   compiled unconditionally. The point was never the import — it was that macOS
   must not quietly become the only platform that runs the real code path. So the
   fast kernel is the default where it exists, and what the lint protects is the
   fallback, plus a Linux CI assertion that a default build there lands on it.
2. **`import Foundation`, never `FoundationEssentials`** — `canImport` is *false*
   on macOS with Swift 6.2.4, so the "portable" import is the one that breaks
   Darwin builds.
3. **A Linux smoke build in CI.** Not a supported target — a canary. Note Yams and
   swift-crypto's `_CryptoExtras` do not build for WASM, so Linux is the broader
   canary.

A fourth has since been added and belongs here: **every corpus derived from a
spaCy model or from upstream Presidio is re-derived in CI and compared.** Without
it the one fixture that had no generator would have gone stale silently, and it
is the fixture the headline number is measured against.

---

## 5. Decisions that were needed before M1

All four are settled; kept because the reasoning is still load-bearing.

| # | Decision | Outcome |
|---|---|---|
| 1 | Regex backend | Pure-Swift with generated Unicode tables — [ADR 0001](docs/decisions/0001-regex-backend.md). |
| 2 | Which spaCy model | `en_core_web_sm`, trimmed and bundled as its own product. |
| 3 | Ship the lemmatizer? | Yes, and exactly: tagger → attribute ruler → rule-mode. |
| 4 | Fidelity claim wording | "Parity with Presidio's default spaCy configuration", with the out-of-scope list in the parity doc. English-only was superseded — eight languages are exact. |

---

## 6. What's not in scope

DICOM redaction (needs DCMTK via a C++ bridge; no usable Swift DICOM library
exists) · image redaction generally (no cross-platform OCR story) ·
presidio-structured · Stanza · GLiNER · LangExtract/LLM recognizers · Azure remote
recognizers · the `surrogate_ahds` operator.

**And the REST server.** This document used to carry it as optional M5 work,
because a Hummingbird target would have unlocked upstream's 52 e2e tests at
near-zero marginal cost — their base URLs are environment-overridable, so no
upstream changes were needed. That is a genuine loss and it is being taken
deliberately: **this is a library, not a service.** A server target would add a
dependency, a deployment story and a wire contract to maintain, for the benefit of
a test layer rather than of any caller.

The consequence, stated rather than implied: of the five test layers this plan
opened with, four are built and **L5 will not be**. Those 52 tests exercise the
HTTP contract — request shapes, status codes, JSON encoding — over behaviour the
other four layers already cover directly and in more detail. What is genuinely
given up is end-to-end coverage of a surface this package does not have.

Two upstream bugs deliberately **not** reproduced: `presidio-cli/presidio_cli/cli.py`
always exits 0 (useless as a CI gate), and `config.py:103` validates the default
threshold instead of the parsed YAML value.

One upstream bug that **is** reproduced, deliberately: `map_del_arc` in spaCy's
parser only removes an arc when it is the last one for that head — its loop for
the other case assigns to a Cython value copy, so stale arcs survive into the
model's own features. Correcting it would change the answers.
