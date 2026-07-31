# Swift Presidio — Build Plan (macOS first)

**Strategy:** ship a correct, conformance-tested macOS build first; treat Android/Windows as a later port, not a parallel track.
**Constraints carried forward:** pure Swift + vendored open-source C permitted · no Apple closed-source frameworks · NER must match spaCy.

---

## 1. Does Presidio have tests? Yes — a lot, and they're the most valuable thing in the repo

| Package | Test files | Test LOC | Test fns | Concrete cases |
|---|---:|---:|---:|---:|
| presidio-analyzer | 137 | 23,645 | 1,058 | ~3,036 |
| presidio-anonymizer | 26 | 3,912 | 212 | ~321 |
| presidio-image-redactor | 14 | 4,551 | 121 | ~292 |
| e2e-tests | 5 | 1,599 | 52 | 52 |
| presidio-cli | 3 | 415 | 25 | 33 |
| presidio-structured | 3 | 414 | 29 | 29 |
| **Total** | **215** | **34,579** | **1,497** | **~3,763** |

Test:production LOC ratio is **1.09:1**. **98 of 99 recognizer classes** are covered by some test (only `TransformersRecognizer` isn't).

The critical property: **a large fraction is pure data-driven `@pytest.mark.parametrize`** — literal `(text, expected_len, expected_spans, expected_score_ranges)` tuples fed to a recognizer with no NLP model in the loop. An AST extractor run against this repo during analysis pulled **1,626 normalized recognizer cases** (959 positive / 667 negative) covering **83 of 99 recognizer classes**, ~430 KB of JSON, with 100% recognizer/entity attribution. 90% collapse into just 6 parametrize signatures, so one normalizer handles nearly all of them.

That extractor was a throwaway and **was not preserved** — rebuilding it (~600 LOC Python) is a real M0 task, not a done deal. But it is proven to work.

**This means you do not write your test corpus. You harvest it.**

### What can't be harvested

~1,256 analyzer cases plus the whole image-redactor suite are coupled to spaCy/stanza/transformers model downloads, `unittest.mock.patch` of module internals, or 92 MB of PNG/DICOM/npy goldens. Those need a **differential Python side-car** (run real Presidio, dump `RecognizerResult` JSON, diff against Swift), not static fixtures.

### Four landmines in the upstream suite — handle deliberately

1. **The e2e oracle is unsound.** `e2e-tests/common/assertions.py:19` — `equal_json_strings` returns `True` for both *extra* and *missing* entities because of `zip()` truncation. Replace with a strict multiset comparator before trusting a single e2e result.
2. **Every extracted span is a Python code-point offset.** The emoji rows in `test_mask.py` (😈) will expose an offset bug instantly — which is exactly what you want, early.
3. **Score assertions carry a `1e-5` epsilon and a sort-by-start normalization** (`assertions.py:1,25-27`). Reproduce both, or you'll chase phantom failures.
4. **`skip_by_engine` is an autouse fixture that silently skips model-dependent tests when models are absent.** A green run can mean "nothing ran." Assert the collected-test count in CI.

---

## 2. Test architecture

Five layers, cheapest signal first:

| Layer | What | Size | When |
|---|---|---|---|
| **L1 — Harvested fixtures** | 1,626 recognizer cases as language-neutral JSON, run by a single Swift table-driven test | ~430 KB | M0, gates every milestone after |
| **L2 — Differential side-car** | Docker Presidio as oracle; run both over a corpus, diff spans+scores. Covers the model/mock cases L1 can't | corpus-sized | M0 scaffold, grows each milestone |
| **L3 — Property tests** | Offset round-trip (every emitted span's substring must re-slice identically), span algebra invariants, Unicode fuzzing | — | M0, permanent |
| **L4 — Known-answer vectors** | Crypto (Python-generated fixed-IV KATs), checksum validators | small | M1–M2 |
| **L5 — Upstream e2e suite** | Point the existing 52 REST tests at the Swift server. Base URLs are env-overridable (`ANALYZER_BASE_URL` etc., `methods.py:16-20`) — **zero code changes needed** | 52 tests | when a server target exists |

Also reusable as-is: **27 YAML configs** in `presidio-analyzer/tests/conf/` (already language-neutral — use them to test the Swift config loader) and the **785-line OpenAPI 3.0.0 spec** at `docs/api-docs/api-docs.yml`, which gives the exact wire contract and `Codable` shapes.

**The NER parity gate** is separate and non-negotiable: the 2,000-sentence check that currently returns 2,324/2,324 · 0 FP · 0 FN must stay green in CI, and must be re-established **end-to-end** (Swift tokenizer feeding Swift NER) rather than with spaCy supplying tokens and norms.

---

## 3. Milestones

Person-weeks, one experienced Swift engineer, **testing included** in every number.

### M0 — Foundations + the conformance harness · 4 pw

- SwiftPM skeleton; target graph; `Package.swift` with macOS-only platform list for now.
- **`TextDocument` / offset model** — Python scalar offsets as the wire contract. Conversion layer + property tests. Do this before anything else touches a span.
- Rebuild the **fixture extractor** (~600 LOC Python) → versioned JSON, checked in.
- Swift table-driven runner for L1. Differential side-car scaffold (L2) against Docker Presidio.
- CI: macOS job + the guardrails in §4.

**Ships:** no features. The corpus and the offset layer. Everything downstream depends on this being right.

### M1 — Regex substrate + deterministic recognizers · 9 pw

- Decide the engine on evidence: build the **Unicode-class differential test first** (must include Mc / Me / No / Join_Control — the classes where PCRE2 and Python `regex` disagree on 22/155 patterns), then pick pure-Swift engine vs PCRE2-with-Python-`\w`-tables.
- Port the 155 patterns as **data** (`Resources/recognizers/*.json`), driven by one `PatternRecognizer` — not 85 hand-written Swift types. This is what makes tracking upstream releases a script.
- 55 checksum validators (7 Luhn variants, 2 Verhoeff, mod-97/23/11/10, base58, bech32/bech32m).
- IBAN's custom `analyze` (its 330-row test table is a complete conformance suite on its own).

**Gate:** ≥95% of the 1,626 L1 fixtures green, and 100% of the checksum KATs.

### M2 — Anonymizer · 3 pw

The easiest high-value target: 2,457 LOC, exactly one regex, no NLP.

- 8 anonymize + 2 deanonymize operators behind one protocol.
- AES-CBC/PKCS#7 via `swift-crypto`'s `CryptoExtras.AES._CBC` (**not** CryptoKit — it has no CBC mode). Goal is round-trip interop + byte-identical decrypt, not byte-identical encrypt (random IV).
- urlsafe-base64 alphabet translation (`-`/`_`), and Python's lenient decode vs Swift's strict `Data(base64Encoded:)`.
- The from-the-end span rewrite + 3-pass conflict resolver.

**Ships:** a genuinely demoable product — detect + anonymize, offline, no model.

### M3 — Tokenizer + NER, composed · 6 pw

The highest-value milestone and the one carrying real unvalidated risk.

- Port spaCy's rule tokenizer (prefix/suffix/infix + exceptions) with exact character offsets **and NORM generation**.
- Wire the 618-line NER port to consume the Swift tokenizer's output instead of spaCy's.
- thinc msgpack weight loading; SIMD GEMM.
- **Re-run the 2,000-sentence parity check end-to-end.** Target: 0 FP / 0 FN. Treat any divergence as a tokenizer bug until proven otherwise.
- Evaluate OpenBLAS/BLIS (BSD-3, portable, and what thinc itself uses) — 1.75×–8.8× faster than the hand-rolled kernel at these shapes.

**Ships:** PERSON / LOCATION / ORGANIZATION / NRP / DATE_TIME at spaCy fidelity.

### M4 — Engine, context, config · 5 pw

- `AnalyzerEngine` end-to-end; thresholds, allow/deny lists, ad-hoc recognizers.
- `LemmaContextAwareEnhancer` (+0.35, floor 0.4, cap 1.0, prefix window 5).
- Dedup + conflict resolution — and **normalize tie-breaks explicitly**, because Python's own ordering is nondeterministic (`list(set(...))` + `PYTHONHASHSEED`-randomized hash). Bit-exact ordering parity is not achievable; define your own total order and document it.
- Yams-backed YAML config + the factory registry replacing Python's `__subclasses__()` reflection. Reuse the 27 upstream YAML configs as tests.
- `phonenumbers` port — scope it properly: **not** just `PhoneNumberMatcher` for 8 regions. Three shipped recognizers need ZA metadata, `region_code_for_number`, and `number_type`.

### M5 — Hardening · 4 pw

Public API review, perf pass, `Sendable`/concurrency audit, docs, resource bundling, error taxonomy. Optionally the Hummingbird REST target — which unlocks L5 (the upstream e2e suite) at near-zero marginal cost.

### **macOS v1 total: ~31 pw ≈ 7 person-months**

### M6 — Platform expansion (later, per your sequencing) · 6–10 pw

Android (Swift 6.3+ SDK, shipped 2026-03-24, plus `swift-java`/JNI) and Windows. **Windows currently has zero evidence of any kind** — not even a cross-compile attempt — so scope it only after a spike.

---

## 4. Cheap guardrails so "macOS first" doesn't become "macOS only"

Building macOS-first is the right call — it removes the platform matrix from the critical path while the design is still moving. The only way it goes wrong is accidentally taking an Apple dependency. Three near-free checks prevent that:

1. **CI lint banning Apple-framework imports** (`NaturalLanguage`, `CoreML`, `Vision`, `CryptoKit`, `Accelerate`, `TabularData`, `CommonCrypto`). One grep step.
2. **`import Foundation`, never `FoundationEssentials`** — `canImport(FoundationEssentials)` is *false* on macOS with Swift 6.2.4, so the "portable" import is the one that breaks Darwin builds.
3. **A Linux cross-compile (or WASM) smoke build in CI from M0.** Not a supported target yet — just a canary. Catches portability drift the week it's introduced instead of at M6. Note Yams and swift-crypto's `_CryptoExtras` don't build for WASM, so use Linux cross-compile as the canary if you want a broader dependency set.

---

## 5. Decisions needed before M1

| # | Decision | Why now |
|---|---|---|
| 1 | **Regex backend**: pure-Swift (Python-exact, 5× slower) vs PCRE2 + Python `\w` table substitution (faster, needs a rewrite pass) | Determines the pattern-compile wrapper everything else builds on |
| 2 | **Which spaCy model** to ship: `en_core_web_sm` (12 MB) or `lg` (588 MB) | Binary size vs accuracy; both MIT, both verified at 0 FP/0 FN |
| 3 | **Ship the lemmatizer?** | If yes, WordNet 3.0 attribution applies. The architecture doc contradicts itself here (§4.2/§11.2 vs §4.3/§9) |
| 4 | **Fidelity claim wording** | Commit to "parity with Presidio's default spaCy English configuration" — 10 of 99 recognizers (Transformers, Stanza, GLiNER, HF/Medical NER, LangExtract ×3, Azure ×2), `surrogate_ahds`, and the batch/provider config path are out of scope |

---

## 6. What's not in scope

DICOM redaction (needs DCMTK via C++ bridge; no usable Swift DICOM library exists) · image redaction generally (no cross-platform OCR story) · presidio-structured · Stanza · GLiNER · LangExtract/LLM recognizers · Azure remote recognizers · the `surrogate_ahds` operator.

Two upstream bugs to **not** reproduce: `presidio-cli/presidio_cli/cli.py` always exits 0 (useless as a CI gate), and `config.py:103` validates the default threshold instead of the parsed YAML value.

---

## 7. Risks

| Risk | L | I | Mitigation |
|---|---|---|---|
| Tokenizer↔NER composition diverges (never tested together) | Med | High | M3 is scoped for it; parity check is the gate, not a smoke test |
| Regex backend picked before the Unicode differential test exists | Med | High | Build the test first — it's a day, and it's decision #1 |
| Offset model wrong → silently wrong spans leak PII | Med | Critical | M0, property-tested, emoji fixtures early |
| Fixture extractor rebuild underestimated | Low | Med | Proven approach, ~600 LOC, 6 signatures cover 90% |
| Effort estimate too tight | Med | Med | 31 pw is a floor; ~25 self-declared unverified items remain |
| Windows turns out hard at M6 | Med | Med | Spike before committing; Android is the safer of the two |

---

## 8. First week

1. Rebuild the fixture extractor; commit the 1,626-case JSON corpus.
2. Write the offset model + its property tests.
3. Build the Unicode-class differential test (Mc/Me/No/ZWJ) and settle decision #1.
4. Stand up CI: macOS build + fixture runner + the three guardrails.

Everything after that is gated on a green corpus, which is the point.
