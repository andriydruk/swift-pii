# Can Presidio be reimplemented in Swift?

**Subject:** [data-privacy-stack/presidio](https://github.com/data-privacy-stack/presidio) (the community continuation of Microsoft Presidio) — MIT, ~27k LOC production Python across 5 packages, 99 predefined recognizers.
**Date:** 2026-07-31
**Method:** source-level analysis of the actual repo at commit `2bb88d2` + empirical benchmarking on macOS 26.5.2 / Swift 6.2.4 / Python 3.10.7. Every quantitative claim below was executed, not estimated. Four core claims were then handed to adversarial verifiers; all four came back with corrections, which are folded in here.

Companion document: [presidio-swift-architecture.md](presidio-swift-architecture.md) — full architecture, Swift protocol code, conformance strategy, roadmap, risk table.

---

## 1. Verdict

**Yes — as a "Presidio-compatible" library, not a "Presidio-identical" one.**

The split is clean and it falls in a lucky place:

- **~80% of Presidio is deterministic** (regex recognizers, checksum validators, span algebra, conflict resolution, scoring, the entire anonymizer). This ports at full fidelity and in places lands *better* in Swift than in Python.
- **~20% is the spaCy NLP layer.** This is unavoidably lossy on-device today. No amount of engineering fully closes it.

The single most feared risk — *"we'd have to hand-rewrite hundreds of regexes"* — **does not exist.** All 155 literal Presidio patterns and all 76 IBAN country regexes compile unmodified under `NSRegularExpression` and produce byte-identical match spans (and identical capture-group spans) against Python on a 3,942-document corpus drawn from Presidio's own tests: 6,946 matches vs 6,946, symmetric difference zero.

That is the load-bearing fact that makes this project sane. But it comes with a serious asterisk — see §3.

---

## 2. What ports cleanly (verified)

| Component | Evidence |
|---|---|
| **237 regexes** (155 literal + 6 assembled + 76 IBAN) | Feature census across all patterns: **0** named groups, **0** named backrefs, **0** atomic groups, **0** possessive quantifiers, **0** conditionals, **0** `\p{...}` property escapes, **0** variable-width lookbehinds, **0** `\B`. Riskiest constructs are 19 fixed-width single-char negative lookbehinds, 28 negative lookaheads, 2 numeric backrefs, 12 inline `(?i)`, 3 non-ASCII classes — all ICU-expressible. |
| **55 checksum validators** | Pure integer arithmetic: 7 Luhn variants, 2 Verhoeff, mod-97/23/11/10 weighted sums, ~5 date-plausibility checks, base58 + bech32/bech32m. Notably **`stdnum` is not used anywhere** — every national checksum is hand-rolled in-repo, so there's no vendored validation library to substitute. Only IBAN (mod-97 over ~34 digits) and Bitcoin (base58 accumulation) need BigInt-style handling. |
| **The entire anonymizer** (2,457 LOC) | Exactly **one** regex in the whole package (`^( )+$` at `anonymizer_engine.py:229`). Zero NLP. Zero Pydantic. One third-party dep (`cryptography`, 57 lines of AES-CBC). 8 anonymize + 2 deanonymize operators behind a 4-method ABC that maps 1:1 to a Swift protocol. This is the fastest, most demoable win in the project. |
| **Span algebra + the 3 overlap algorithms** | `intersects`/`contains`/`containedIn`/`hasConflict` (~40 lines), `remove_duplicates` (~20 lines), the anonymizer's 3-pass conflict resolver, the chunker's >50%-overlap dedup. All pure, small, mechanical. |
| **Scoring / thresholds / allow-lists / context boost** | Fixed constants (`+0.35`, floor `0.4`, cap `1.0`, prefix window 5, suffix 0). Straight-line arithmetic. |

**Licensing is clean.** MIT, "Copyright (c) Presidio Contributors." Verbatim copying of regex patterns, context word lists, score constants and entity names is unambiguously permitted. Two caveats: attribute to *Presidio Contributors*, not Microsoft (the project moved to the community `data-privacy-stack` org); and MIT grants no trademark rights, so don't name the product Presidio-anything. The 80KB `NOTICE` covers Presidio's *Python runtime dependencies* — none of which a Swift port ships — so you inherit zero obligations from it.

---

## 3. The three hard problems

### (a) Regex `\b` semantics — the trap hiding behind the good news

The clean-corpus parity result above is real but was measured on clean text. Under adversarial input it collapses.

ICU's `\b` **ignores combining marks and default-ignorable format characters**; Python's does not. **131 of 155 patterns (85%) use `\b`.** On a 9,558-document corpus with one invisible character spliced adjacent to each real PII span:

| Engine | Matches | False negatives |
|---|---:|---:|
| Presidio (Python `regex`) | 42,063 | — |
| `NSRegularExpression`, default | 12,343 | **30,029 (71.4%)** |
| `NSRegularExpression`, `.useUnicodeWordBoundaries` | 18,344 | 24,010 (57.1%) |
| `NSRegularExpression` + `\b`→lookaround rewrite | 42,063 | **0** (and 0 false positives) |

FN breakdown by character: soft hyphen 5,995 / ZWSP 5,995 / BOM 5,995 / LRM 5,995 / word-joiner 5,995 / combining acute 54.

A 71% miss rate **in the PII-leak direction** is not a footnote. The fix is a mechanical ~30-line transform in the compile wrapper that rewrites every `\b` into an explicit lookaround pair over ICU's `\w` set. It restores exact parity on both clean and dirty corpora at ~22% throughput cost. **Budget it as a named, tested workstream.**

Three more dialect findings:

- **Use `NSRegularExpression`, not Swift Regex.** Swift Regex defaults to UAX#29 word boundaries and silently returns **zero** matches for `\b\d{1,3}\b` on `"3.14"`, `"1,234"`, `"555.123.4567"` (4/23 divergences on plain ASCII). It needs an explicit `.wordBoundaryKind(.simple)` on every pattern, and runs ~30× slower. ICU is the right substrate; `NSRegularExpression` scored 0/23 divergences.
- **Validate against the `regex` module, not stdlib `re`.** Presidio does `import regex as re` in `pattern.py`, `pattern_recognizer.py`, `analyzer_engine.py` and `iban_recognizer.py`. The two disagree on 289 match sets over an adversarial corpus (`\w` matches U+0301 and ZWJ in `regex` only; matches ½ and U+0F33 in `re` only).
- **MULTILINE `$` differs.** Presidio sets `DOTALL | MULTILINE | IGNORECASE` globally (`pattern_recognizer.py:59`). ICU treats `\r`, `\v`, `\f`, U+0085, U+2028, U+2029 as line terminators; Python's `regex` only treats `\n` as one. `^\d{3}$` on `"078\r\n123\r\n456"` → Python `['456']`, ICU `['078','123','456']`. Diverges on 7/7 non-LF terminators.

### (b) NER without spaCy — the real, irreducible gap

`NLTagger` is a viable *baseline*, **not** an accuracy-comparable substitute. Measured head-to-head on an identical corpus using Presidio's own label mapping:

| Engine | Well-cased PER/LOC/ORG | Full corpus (incl. NRP, DATE_TIME, realistic casing) |
|---|---|---|
| spaCy `en_core_web_lg` 3.8.14 | P .955 / R 1.000 / **F1 .977** | P .974 / R .974 / **F1 .974** |
| `NLTagger(.nameType)` | P .824 / R .667 / **F1 .737** | P .727 / R .421 / **F1 .533** |

Worse, the failure mode is sharp rather than graceful: **on lowercase input spaCy recovered 6/6 entities, NLTagger recovered 0/6.** On NRP + DATE_TIME, spaCy 8/8, NLTagger 0/8 — those are 2 of the 5 entity types Presidio sources from spaCy, and `NLTagger` cannot produce them at all.

Coverage probed across 59 `NLLanguage` values: `.nameType` in **8** languages with exactly **3** tags (personalName/placeName/organizationName); `.lemma` in 10; `.lexicalClass` in 9 (Presidio doesn't use POS at all — grep-confirmed zero non-test hits).

There's a second-order problem: lemmatization returns nil on ~14% of tokens, and the nils include *"IBAN"* and *"NHS"* — which are themselves Presidio context words (`iban_recognizer.py:63`, `uk_nhs_recognizer.py:31`). So the context-score boost silently degrades unless you fall back to the lowercased surface form.

**Mitigation:** a layered `NerProvider` protocol with `NLTagger` as the zero-footprint floor (ships everywhere, ~10× faster, no binary cost) + a case-normalization pre-pass + `NLGazetteer` for NRP + `NSDataDetector` for DATE_TIME/address/phone + an optional CoreML transformer tier. A converted `dslim/bert-base-NER` scores ~91 F1 vs `en_core_web_lg`'s ~85 — it *exceeds* spaCy — but costs 110–215 MB and is a different model with different errors, so "same spans as Python" is unattainable on either path.

⚠️ **Highest-risk single item in the whole project:** `swift-transformers` has **no offset-mapping API** (grep-confirmed). You must hand-write subword→character alignment. Budget ~40% of the transformer phase for it, not 10%.

### (c) Crypto — CryptoKit cannot do this

Presidio's `aes_cipher.py` uses **AES-128/192/256-CBC + PKCS#7 + random 16-byte IV** prefixed to the ciphertext, urlsafe-base64 encoded.

**CryptoKit's `AES` enum exposes only `GCM` and `KeyWrap` — there is no CBC mode at all.** Use **`swift-crypto`'s `CryptoExtras.AES._CBC`** (≥ 4.5.1), which is BoringSSL-backed on *every* platform including Darwin — it does not forward to CryptoKit — so bytes match Python on macOS, iOS and Linux alike. (Darwin-only alternative: CommonCrypto's `CCCrypt` with `kCCOptionPKCS7Padding`.)

Also, "byte-compatible" is the wrong goal: `os.urandom(16)` per call means ciphertext isn't reproducible even Python→Python. The achievable property is **round-trip interop + byte-identical decrypt output**. Two subtle gotchas: Python's `urlsafe_b64encode` uses the `-`/`_` alphabet (Foundation's base64 APIs use the standard one and need manual translation), and Python's `urlsafe_b64decode` silently discards non-alphabet characters where `Data(base64Encoded:)` returns nil.

---

## 4. Two things that will bite you if you don't decide them on day one

**Offset representation.** Python offsets are Unicode *scalar* indices; `NSRegularExpression` returns UTF-16; Swift `String` is grapheme-indexed. These offsets are the wire contract with the anonymizer and every downstream consumer. Pick scalar offsets, build the conversion layer once, property-test that every emitted span's substring round-trips. Getting this wrong is a silent PII-leak class of bug.

**Ordering is nondeterministic in Python itself.** `analyzer_engine` does `list(set(results))` before a sort whose key `(-score, start, -(end-start))` omits `entity_type`, and `RecognizerResult.__hash__` uses `hash(str)`, which is `PYTHONHASHSEED`-randomized. Recognizer execution order is also `set`-derived. **A correct Swift port will legitimately differ on ties.** Bit-exact golden-file parity is impossible without normalizing tie-breaks on both sides.

---

## 5. Architecture: make it data-driven, not 99 Swift types

The highest-leverage decision available, and it costs nothing on day one: put recognizer patterns in `Resources/recognizers/*.json` and drive them through **one** `PatternRecognizer` struct + 55 free validator functions, rather than transliterating 99 Python classes into 99 Swift types.

| Design | `PresidioRecognizers` LOC | Total Swift LOC |
|---|---:|---:|
| Literal transliteration (1 type per Python class) | 14,000 | ~34,400 |
| **Data-driven (recommended)** | **7,300** | **~26,800** |

The LOC saving is not the point. The point is **upstream tracking**: regenerating JSON from a new Presidio release is a script; regenerating 85 hand-written Swift types is not. Both `pii-vault` (Rust/TS, MIT — its `spec/recognizers/*.json` are directly reusable as a bootstrap) and `clipscrub-core` (Swift, Apache-2.0) converged on this independently.

Swift protocol definitions, the YAML→factory-registry design that replaces Python's `__subclasses__()` + `inspect.signature` reflection, and the full target graph are in [presidio-swift-architecture.md §3](presidio-swift-architecture.md).

---

## 6. Alternatives — why a native rewrite wins

| Strategy | Verdict |
|---|---|
| **Swift-native "Presidio-compatible" rewrite** | ✅ **Winner.** Only option that is offline, on-device, iOS-shippable, and redistributable. |
| **Call Presidio's Docker REST API** | ⚠️ **Build it too — as a peer, not the primary.** ~1 day of URLSession + Codable. 100% fidelity for server-side Swift, *and* it becomes your differential-test oracle so fidelity is a measured number instead of a claim. But it ships PII off-device, which defeats the reason most people adopt Presidio on mobile. (It is upstream's own official recommendation for other languages.) |
| **Embed CPython + spaCy on iOS** | ❌ **The blocker isn't Python, it's spaCy.** PEP 730 landed iOS as tier-3 in CPython 3.13 and App Store 2.5.2 permits a bundled interpreter. But thinc/blis/cymem/preshed/murmurhash have no iOS wheels and no cross-compilation story; NumPy's iOS wheel support only merged 2026-07-17. Plus `en_core_web_lg` is ~560 MB and can't be downloaded at runtime. A permanent private-fork maintenance tax. |
| **Pyodide/WASM in a Swift host** | ❌ **Impossible.** Pyodide maintainer, verbatim: *"No. Pyodide is built by the Emscripten toolchain and can only run in a browser or Node.js."* WasmKit is WASI and can't host it. The CPython-WASI variant means interpreting an interpreter with no JIT — and still no spaCy. |

**Historical precedent worth knowing:** Presidio V1 had a Go orchestration layer (`presidio-api`, gRPC microservices). V2 deleted all of it in March 2021 and consolidated on Python. The lesson: the plumbing was never where the value lived. Rebuild the recognizers, not the transport.

**Prior art in Swift is essentially nonexistent** — `PII detection language:Swift stars:>1` returns exactly one result. Of the four attempts found, `clipscrub-core` (Apache-2.0) is the one to study: it independently converged on the recommended architecture layer for layer. `Desert-Ant-Labs/redact` is the most feature-complete but is source-available with commercial licensing required at scale; `swift-masker`'s model is likewise proprietary. Both are dead ends for a redistributable library.

---

## 7. Effort

The architecture doc's roadmap totals **26 pw (≈6 person-months) for v1.0** and **43 pw (≈10 pm)** for everything except DICOM. Two corrections to those numbers:

1. **They allocate zero weeks to testing**, despite upstream carrying a 1.09:1 test:prod ratio (34,444 test LOC vs 31,564 prod) and the design's own mandate for a differential harness, offset property tests and crypto KAT vectors. **A realistic full-port figure is 63–72+ pw.**
2. **They're mis-scoped for an iOS app.** ~23 of 60 pw (REST server, CLI, presidio-structured, image redaction, DICOM) is irrelevant to a mobile target — leaving **~31 pw implementation / ~40–47 pw with tests** for the iOS-relevant core.

**The MVP is genuinely useful early.** Phase 1 (~13 pw + tests) ships ~60+ entity types — every regex/checksum entity including credit card, IBAN, crypto, IP, MAC, UUID, URL, email plus all 68 country-specific types — with full anonymize/deanonymize, **zero model download, zero network, fully offline, no OS availability floor.** That isn't a toy: Presidio itself ships `NoOpNlpEngine` and `slim.yaml` for exactly this shape.

**Don't port:** DICOM redaction (10 pw, needs DCMTK via C++ bridge — no usable Swift DICOM library exists), Stanza, the LangExtract/LLM recognizers, the Azure AHDS surrogate operator, and the matplotlib overlay.

---

## 8. Bottom line

This is a **scoping risk, not a feasibility risk.**

Ship it as *Presidio-compatible*, wire the Docker API in as a differential oracle in CI, publish a per-entity fidelity table, and be loud in the README that the NER tier differs. Overclaiming parity on PERSON detection is the main reputational hazard — users notice a missed *name* far more than a missed Nigerian NIN.

Do these three things before writing feature code, and the rest is mechanical:
1. Decide the offset model and property-test it.
2. Write the `\b`→lookaround compile wrapper and its dirty-corpus test.
3. Stand up the fixture extractor + differential harness, so fidelity is a number from week one.
