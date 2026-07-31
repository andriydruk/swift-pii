# Pure-Swift Presidio — revised verdict

**Your constraints:** Swift + vendored open-source C permitted · targets **Android, macOS, Windows** · NER must **match spaCy as closely as possible** · no Apple closed-source frameworks.

**Companion docs:** [presidio-pure-swift-architecture.md](presidio-pure-swift-architecture.md) (full design, ~91k chars) · [prototypes/](prototypes/) (working code from the analysis) · [PRESIDIO-SWIFT-FEASIBILITY.md](PRESIDIO-SWIFT-FEASIBILITY.md) (the earlier Apple-frameworks-allowed analysis, now superseded on NER).

---

## 1. Verdict: yes — and the constraint made it *better*

Banning Apple's frameworks removed the weakest part of the previous plan. NLTagger was the compromise; forcing it off the table pushed the analysis onto the spaCy-weights path, which doesn't approximate spaCy — **it reproduces it exactly.**

This was not estimated. It was built and I re-ran it myself:

> A **618-line pure-Swift port of spaCy v3's NER pipeline**, loading Explosion's MIT-licensed `en_core_web_lg` weights directly from thinc msgpack, over 2,000 sentences:
> **2,324 / 2,324 entities. 0 false positives. 0 false negatives.**
> Verified independently by me, not taken from the agent's report.

For comparison, the previously-measured Apple path (`NLTagger`) scored **F1 .737** against spaCy's **.977**. You asked to match spaCy as closely as possible; the answer is you can match it *bit-for-bit*, and run 1.6–1.8× faster than spaCy's own NER pipe while doing it.

Three other pieces were also built and measured, not guessed:

| Piece | Result |
|---|---|
| spaCy rule tokenizer port | 451,231 + 61,357 tokens, **0 divergences in text *and* character offsets** vs `spacy.blank("en")`; 2.0× spaCy's Cython |
| Pure-Swift regex engine (486 lines, zero Foundation) | Python-`regex`-table-exact on all 155 Presidio patterns |
| PCRE2 via SwiftPM | 155/155 patterns compile, 15% faster than NSRegularExpression |

The prototypes are in [prototypes/](prototypes/) — `spacy-ner-port.swift` is the one that matters.

---

## 2. Licensing: clear, and I verified it directly

The model wheels' own `METADATA` says `License: MIT`. The bundled `LICENSES_SOURCES` lists OntoNotes 5 as *"commercial (licensed by Explosion)"* — **Explosion bought the training-data licence and released the resulting weights under MIT.** That restriction is theirs, discharged; it does not propagate to you. Redistributing the weights inside your app is permitted.

Two conditions:
- **WordNet 3.0** appears in `LICENSES_SOURCES` and carries an attribution obligation — but only if you ship lemmatizer data. The design contradicts itself on whether it does (§4.2/§11.2 say no, §4.3/§9 say yes, 342 KB gz). Decide once; if you ship it, add the attribution.
- Presidio itself is MIT ("Presidio Contributors", not Microsoft). No trademark rights — don't name the product Presidio-anything.

---

## 3. The regex correction — read this before you commit

The design's "decisive fact" was that **PCRE2 needs no pattern rewriting**. That is **false**, and the adversarial verifier caught it.

PCRE2 with `PCRE2_UTF|PCRE2_UCP` defines `\w` as `\p{L}+\p{N}+\p{Mn}+\p{Pc}`; Python's `regex` uses the UTS#18 word set (Alphabetic + *all* `\p{M}` + Nd + Pc + Join_Control). Measured across all 1,114,112 codepoints: **915 PCRE2-only members** (No/Nl) and **613 Python-only** (Mc 443, So 130, Me 13, ZWJ/ZWNJ 2, Mn 2). Since 131/155 patterns use `\b`, this bites on **22 of the 155 patterns**:

```
"Employee SSN 078-05-1120²"   Python: 2 spans    PCRE2: 0 spans   ← complete SSN miss on a footnote marker
Devanagari + spacing vowel     Python: 0 spans    PCRE2: 12 spans  ← fabricated detections
```

The earlier "0 FN / 0 FP across 7 adversarial corpora" result was an artifact of corpus design — the generator used five `Cf` characters plus `U+0301`, exactly the classes where the two engines happen to agree. It never tested Mc, Me, No, or Join_Control.

**What this means for you:** the **pure-Swift engine is the Python-exact one**, not PCRE2. Under your reading-(B) permission you can still use PCRE2 for speed, but only if you mechanically substitute Python's `\w` table into every `\b` — the same class of transform as the `\b`→lookaround rewrite from the first analysis. Treat it as a named workstream with its own Unicode-class differential test, and make the CI corpus include Mc/Me/No/ZWJ or it will pass while being wrong.

**Swift Regex is disqualified outright** — on correctness, not taste:
- **19/155 patterns don't compile.** `lookbehind is not currently supported` (Swift 6.2.4). SE-0448 is accepted but unshipped.
- **`\d` is wrong**: 2,023 codepoints vs Python's 760. `\b\d{6,14}\b` matches `①②③④⑤⑥⑦⑧⑨⑩` and `½½½½½½½½½½`. Standing false-positive generator.
- **Blocking bug**: `.matchingSemantics(.unicodeScalar)` + `.wordBoundaryKind(.simple)` together break `\b` entirely — zero matches on plain ASCII `"abc 12345678901234 xyz"`. You need both options. Corpus-wide recall under that combination: **0.2869**.
- `Regex<AnyRegexOutput>` isn't `Sendable` under `-swift-version 6`.

---

## 4. Platform reality for Android + macOS + Windows

This is where I'd focus your risk budget. Nothing was executed on any of your non-Apple targets.

| Target | Status |
|---|---|
| **macOS** | ✅ Everything above was built and run here. |
| **Android** | ⚠️ **Officially supported as of Swift 6.3** (shipped 2026-03-24, first official Swift SDK for Android, plus `swift-java`/JNI for Kotlin interop). The agent's build failure was Swift 6.2.4 on this machine, not a dead end. But **nothing was verified** — you must confirm PCRE2 (or the pure-Swift engine), the msgpack weight loading, and `mmap`/`clock_gettime` behind `#if canImport(Bionic)` all work under the NDK. |
| **Windows** | 🔴 **Zero evidence of any kind** — not even a cross-compile attempt. Your largest unknown. |
| WASM | ✅ Verified working (Foundation, JSONEncoder, PCRE2, 155/155 patterns). But **Yams and swift-crypto's `_CryptoExtras` both fail to build** there — substitute if you ever want WASM. |
| Linux | Cross-compile + static link only, never executed. Comes essentially free and you'll want it for CI. |

**Foundation ruling:** `import Foundation` is the portable import — **not `FoundationEssentials`**. Measured: `canImport(FoundationEssentials)` is *false* on macOS with Swift 6.2.4, so importing it "for portability" makes your code fail to compile on Darwin. `NSRegularExpression` is absent from `swift-foundation` entirely, which is a second reason not to build on it.

**First thing to do:** a 9-platform CI matrix spike *before* committing to the design. That is not the 1.5 pw the roadmap allocates.

---

## 5. Other corrections worth carrying forward

**BLAS is not irrelevant.** The design claims the hand-written SIMD GEMM hits "52–70 GFLOP/s, ~96% of NEON-FMA peak" and that "BLAS buys nothing at these shapes." Measured: it achieves **25–44 GFLOP/s** at the actual tok2vec shapes (96–480 wide), which is ~55% of the 78–79 GFLOP/s an independent-FMA loop sustains on the same chip. Accelerate is **1.75×–8.8× faster** at exactly those shapes. And calling BLAS "Apple-only" is a category error — **OpenBLAS and BLIS are BSD-3 and portable, and BLIS is what thinc itself uses.** Under reading (B) you should evaluate them. The NER port still beats spaCy's pipe, but because Python/Cython overhead dominates, not because the kernel is optimal.

Throughput figures are also ~8–19% optimistic: `sm` reproduces at ~26.3k tok/s (claimed 28,574), `lg` at ~20.6k (claimed 25,446); speedup 1.79×/1.58×, not 1.9×.

**The NER parity has a real caveat.** It was measured with spaCy supplying *both* tokens and NORMs. The tokenizer port was validated separately and perfectly — but **the two have never been composed.** That integration is genuinely unvalidated work, not productionisation, and the schedule treats it as the latter. Compose them and re-run the 2,000-sentence parity check as your first milestone gate.

**Fidelity should be stated narrowly.** Not "full functional parity with Python Presidio for English" but **"parity with Python Presidio's default spaCy English configuration."** Dropped: 10 of 99 English-capable recognizers (Transformers, Stanza, GLiNER, HuggingFace/Medical NER, LangExtract ×3, Azure ×2), the `surrogate_ahds` operator, and the `BatchAnalyzerEngine`/`AnalyzerEngineProvider`/`RecognizerRegistryProvider` config path.

**Effort: treat 37 pw as a floor, not a central estimate.** The band (33–42 pw) is too tight against ~25 self-declared unverified items, an under-scoped phone port (8 regions, `PhoneNumberMatcher` only — missing ZA metadata, `region_code_for_number`, and `number_type` that three shipped recognizers need), and the composed-pipeline work above. Also, §6.2's exact-score conformance requirement is unachievable alongside §4.3's deliberate stemmer substitution — no milestone budgets that reconciliation.

---

## 6. What I'd do first

1. **Platform spike** — get the pure-Swift engine + a msgpack weight load running on Android (Swift 6.3 SDK) and Windows. Everything else is downstream of this answer, and Windows is unprobed.
2. **Compose tokenizer + NER** and re-run the 2,000-sentence parity check end-to-end without spaCy feeding norms. That converts the headline result from a component demo into a product claim.
3. **Pick the regex backend on evidence** — build the Unicode-class differential test with Mc/Me/No/ZWJ *first*, then decide pure-Swift vs PCRE2-plus-table-substitution.
4. Then the deterministic core (155 patterns + 55 checksum validators + the anonymizer), which is the mechanical, parallelizable, low-risk bulk.

The honest summary: **the hard research risk is retired** — exact spaCy parity in pure Swift is demonstrated, licensing is clean, and the regex dialect problem is understood and solvable. What remains is a platform-portability question on Android and Windows that nobody has actually tested yet, plus a substantial but ordinary amount of engineering.
