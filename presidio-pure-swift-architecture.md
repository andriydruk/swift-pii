# Pure‑Swift, Fully Cross‑Platform Presidio — Feasibility and Design

**Revision 2 — zero Apple closed‑source frameworks.**
Target: Swift 6.2. Platforms: Linux (primary), macOS, Windows, Android, WASM.
Upstream reference: `microsoft/presidio` @ `2bb88d2` (2026‑07‑29), read directly at `/private/tmp/claude-501/-Users-admin-presidio/8157ec96-e57a-4b4d-948a-2814bca19ad4/scratchpad/presidio`.

All numbers in this document come from sub‑agents that executed code on an Apple M4 Max (14 cores), macOS 26.x, Swift 6.2.4 (`swiftlang-6.2.4.1.4`), Python 3.10.7, `regex` 2.5.148, spaCy 3.7.5/3.8.14. Nothing was executed on Linux by any agent — see §11.

---

## 1. Verdict

**Yes. A pure‑Swift, fully cross‑platform Presidio is feasible, and under the no‑Apple‑frameworks constraint it comes out *better* than the Apple‑frameworks version on every axis that matters except one (regex throughput under the strictest reading).**

That is not a hedge. The three load‑bearing pieces were not estimated — they were built and measured:

| Piece | Status | Evidence |
|---|---|---|
| Regex engine with exact Python‑`regex` parity | **Built, twice** | PCRE2‑via‑SwiftPM: 155/155 patterns, 7,591/7,591 spans exact, 0 FN / 0 FP on 7 adversarial corpora. Pure‑Swift 486‑line engine: identical results, zero Foundation. |
| NER equal to spaCy | **Built** | 618‑line pure‑Swift spaCy‑v3 NER port. `en_core_web_sm`: 2592/2592 entities, 0 FP / 0 FN over 47,511 tokens. `en_core_web_lg`: 2324/2324. 1.9× faster than spaCy's own NER pipe. |
| spaCy tokenizer with exact offsets | **Built** | 451,231 + 61,357 tokens, 0 divergences in text *and* offsets vs `spacy.blank("en")`. 2.0× spaCy's Cython. |

### What changes versus the Apple‑frameworks plan

**The entire NER strategy is dead. Not degraded — dead.**

| Dead component | Why | Replacement | Accuracy delta |
|---|---|---|---|
| `NLTagger` (NER) | Apple‑only, closed | Pure‑Swift spaCy v3 NER port, loading Explosion's **MIT‑licensed** `en_core_web_sm` weights | **Massive improvement.** Prior measurement: spaCy `en_core_web_lg` F1 **.977** vs NLTagger **.737** on well‑cased PER/LOC/ORG. The Swift port is bit‑exact with spaCy. |
| `NLTokenizer` | Apple‑only, closed | Pure‑Swift port of spaCy's rule tokenizer (268 LOC + generated rules) | Exact parity with the Python pipeline, which `NLTokenizer` never had. |
| `NLGazetteer` | Apple‑only, closed | Own byte‑level Aho‑Corasick (161 LOC, zero imports) — 130 MB/s at 162k patterns | Neutral; you now control the data. |
| `CoreML` / `NLModel` | Apple‑only, closed | **Nothing needed.** The NER port runs the model directly from thinc msgpack weights with hand‑written SIMD GEMM. | No runtime, no conversion step, no `.mlmodelc`. |
| `NSDataDetector` | Apple‑only, closed, absent from swift‑corelibs‑foundation | **Nothing lost.** Presidio never used it: dates, phones, URLs and emails come from `DateRecognizer`, `PhoneRecognizer` (python‑`phonenumbers`), `UrlRecognizer`, `EmailRecognizer` (`tldextract`). | Neutral, but see §9 — `phonenumbers` is now an explicit port item. |
| `NSRegularExpression` as primary engine | Darwin implementation is closed; absent from `swift-foundation` entirely (grep: **zero hits**); loses 68% of PII on text containing one soft hyphen without a `\b` rewrite | **PCRE2** (reading B) or the **pure‑Swift engine** (reading A) | Improvement: PCRE2 needs **zero pattern rewriting** and is 15% faster (4.15 s vs 4.99 s over 155 patterns / 759 KB). |
| `Accelerate` / BLAS | Apple‑only | Hand‑written `SIMD8`/`SIMD16` register‑tiled GEMM: **52–70 GFLOP/s** single‑thread, ~96% of NEON‑FMA peak | The NER shapes are 96–480 wide; BLAS buys nothing there. Measured: Swift NER is 1.9× faster than spaCy's NER pipe *without* BLAS. |
| `CryptoKit` / `CommonCrypto` | Apple‑only | `swift-crypto` (B) or **CryptoSwift** (A) | **Zero cost.** Measured 33.5 MB/s vs 31.5 MB/s — noise. Both byte‑identical to Python `cryptography`. |

### The one genuine cost

Under the **strictest** reading, regex throughput. The pure‑Swift engine is currently **11.14 s** vs PCRE2's **2.21 s** on the 135‑pattern / 759,142‑scalar sweep — 5.0×. It is nevertheless **2.7× faster than Apple's own Swift Regex** (30.14 s), which cannot compile 19 of the 155 patterns anyway. Two cheap optimizations already took it from 42.8 s → 11.1 s; landing at 2–2.5× of PCRE2 is a reasonable expectation but is **extrapolation, not measurement**.

### Second verdict: don't use Swift Regex

`_StringProcessing` is disqualified on correctness, not taste:

- **19/155 patterns will not compile.** Hard error, Swift 6.2.4: `lookbehind is not currently supported` (patterns #23–29, 54–58, 63, 64, 144, 145, 147, 148, 152). SE‑0448 is Accepted but not shipped, and its own text says it "require[s] a new version of the standard library and runtime" — i.e. OS‑version gating on Darwin when it lands.
- **`\d` is wrong.** Swift stdlib `\d` = 2,023 codepoints vs Python's 760. `\b\d{6,14}\b` matches `①②③④⑤⑥⑦⑧⑨⑩` and `½½½½½½½½½½`. Python and PCRE2 match neither. With 131/155 Presidio patterns using `\b` and most using `\d`, that is a standing false‑positive generator.
- **`\w` is wrong the other way**: missing 1,897 Python word chars (950 combining marks, 640 Nd).
- **A blocking bug**: `.matchingSemantics(.unicodeScalar)` + `.wordBoundaryKind(.simple)` breaks `\b` entirely — `\b[0-9]{6,14}\b` returns **zero** matches on the ASCII string `"abc 12345678901234 xyz"`. Each option works alone. You need `.unicodeScalar` to escape grapheme semantics and `.simple` for correct `\b`, so you cannot have both. Corpus‑wide recall under that combination: **0.2869**.
- 11.5× slower than NSRegularExpression (this refutes the earlier "~30×" figure).
- Not `Sendable`: `Regex<AnyRegexOutput>` fails a `Sendable` constraint under `-swift-version 6`.

---

## 2. The Purity Ruling

### 2.1 Four tiers, not two

The (A)/(B) dichotomy is under‑specified once Foundation enters the picture. Use four tiers:

| Tier | Definition | Satisfies |
|---|---|---|
| **T0** | Swift stdlib only. No Foundation, no C, no platform conditionals. | (A) in its strictest form |
| **T1** | T0 + the Foundation *API surface* shipped with the toolchain | (A) under the "toolchain‑only" reading |
| **T2** | T1 + permissively‑licensed open‑source C/C++ vendored in‑package via SwiftPM | (B) |
| **T3** | Anything Apple‑only or closed | **Banned** |

### 2.2 The Foundation ruling

**Foundation is permitted; `NSRegularExpression` is permitted but must not be built on.** The reasoning:

1. **`import Foundation` is the portable import — not `FoundationEssentials`.** Measured: `canImport(FoundationEssentials)` is **FALSE** on macOS with Swift 6.2.4, and **TRUE** on `wasm32-unknown-wasip1`. Importing `FoundationEssentials` for "portability" makes your code *not compile on Darwin*. On non‑Darwin, swift‑corelibs‑foundation re‑exports it under `Foundation` anyway.
2. **Foundation is categorically unlike NaturalLanguage/CoreML/NSDataDetector.** Foundation has an open, Apache‑2.0 reference implementation (`swift-corelibs-foundation`, `swift-foundation`) that ships with the toolchain on Linux and Windows. Darwin's binary is a *different implementation of a public contract*. NaturalLanguage has no implementation outside Darwin at all. That is the line.
3. **`NSRegularExpression` is behaviourally identical across implementations — proven.** All 155 Presidio patterns were run over the 759,142‑scalar corpus on macOS (Apple's closed Foundation) and on `wasm32-unknown-wasip1` (corelibs‑foundation + vendored `swift-foundation-icu`): **155/155 compiled, 1,698 matches, identical per‑match offsets, identical FNV‑1a digest `f1b1e60b48e31c3c`**. Plus 14 hand‑built ICU‑sensitive edge cases (ZWSP, combining marks, soft hyphen, `\p{L}`, backrefs, non‑ASCII case folding, Greek `\b`) — all identical. The only measured divergence anywhere was `Locale.availableIdentifiers`: 1,062 (macOS) vs 1,001 (WASI), which is a CLDR inventory difference, not a regex one.
4. **But `NSRegularExpression` still loses on merit.** It does not exist in `swift-foundation` (zero source hits — it is legacy‑corelibs‑only), it needs the `\b`→lookaround rewrite (+55% throughput, measured, not the 22% previously estimated), it has no `MATCH_LIMIT` equivalent, and PCRE2 beats it on every axis. Depend on Foundation for `Data`, `JSONDecoder`, `URL`, file I/O. Do not depend on it for pattern matching.

**Corollary that must be stated plainly:** if (A) is read as "no C anywhere in the process", it is *unattainable*, because `import Foundation` on Linux statically links `libCoreFoundation.a` and `lib_FoundationICU.a` (79 MB of C/C++ ICU in the static SDK). Insisting on that reading does not merely cost you libraries; it costs you Foundation. That is why T1 exists.

### 2.3 Per‑dependency ruling

| Dependency | Purpose | Tier | Verdict |
|---|---|---|---|
| Swift stdlib (`SIMD`, `Unicode.Scalar.Properties`, `String` views) | Everything | **T0** | Required. Verified sufficient for GEMM, tokenizer, Unicode classification, offsets. |
| Foundation (umbrella import) | `Data`, JSON, file I/O, `URL` | **T1** | **Adopt.** Never `import FoundationEssentials`. |
| `NSRegularExpression` | — | T1 | **Permitted but rejected on merit.** See §3. |
| **PCRE2 10.47** (30 `.c` files, vendored) | Primary regex engine | **T2** | **Adopt as default.** BSD‑3. Builds via SwiftPM in 2.95 s from `config.h.generic` + `pcre2.h.generic` + `pcre2_chartables.c.dist`, zero source patches, JIT excluded. 406 KB static binary. |
| **Pure‑Swift regex engine** (486 LOC) | Strict backend + CI oracle | **T0** | **Adopt as second backend.** Compiles with `import Foundation` removed entirely. |
| **spaCy NER port** (618 LOC) | NER | **T0** | **Adopt.** No Foundation, no C, no regex. |
| **spaCy tokenizer port** (268 + 164 + tables) | Tokenization | **T0** | **Adopt** the hand‑coded `PureMatcher` variant. Measured **2.0× faster than NSRegularExpression** for affix matching and byte‑identical on 378,390 spans. Purity is a *speedup* here. |
| **Aho‑Corasick** (161 LOC) | Gazetteers | **T0** | Adopt. Zero imports. |
| **CryptoSwift 1.10.0** | AES‑128/192/256‑CBC | **T0** | **Adopt for (A).** MIT, 114 Swift files, 13,442 LOC, **0 C files**. Byte‑identical to Python `cryptography`. 31.5 MB/s. Caveat: table‑based, **not constant‑time**. |
| `swift-crypto` (`_CryptoExtras.AES._CBC`) | AES‑CBC | **T2** | Adopt for (B) if constant‑time matters. 33.5 MB/s — a 6% delta. Vendors 370 C/C++/asm files. **Fails to build for WASM** (`ThreadSpecific.swift`: `cannot find type ThreadOpsSystem`). |
| **Yams 5.4.0** | YAML config | **T2** | Adopt for (B). 6 C files. **Fails to build for WASM** (`DBL_DECIMAL_DIG`). Parsed 68/75 Presidio YAMLs in 0.022 s (the 7 "failures" are multi‑doc files needing `loadAll`). |
| Build‑time YAML→JSON + `JSONDecoder` | YAML config | **T1** | **Adopt for (A).** 0.3 pw. Works on WASM. Loses runtime hand‑editing of YAML unless you ship a converter. |
| `1amageek/swift-yaml` 1.0.1 | Pure YAML | T0 | **Reject.** 1 GitHub star, no `Codable`, no YAML 1.2 scalar typing (`0.0` stays a string), `Mapping.pairs` is private. 2.5 pw to make usable. |
| **Hummingbird 2.26** | REST API parity | **T2** | Adopt for (B). 25 transitive pins vs Vapor's 29; 65 MB vs 74 MB static musl binary. SwiftNIO carries 15 C files, swift‑nio‑ssl 400 (BoringSSL). |
| Vapor 4.122 | REST | T2 | Reject — heavier, no benefit for Presidio's small REST surface. |
| Swift Regex | — | T0 | **Reject.** See §1. |
| `swift-transformers` Tokenizers | HF tokenizers | T2 | **Reject.** `PreTokenizer` is `(String) -> [String]` end to end — **no offsets anywhere**, and `BertTokenizer` strips accents *before* tokenizing, so offsets are structurally unrecoverable. Also drags in swift‑nio, swift‑crypto, yyjson. |
| ONNX Runtime | ML runtime | T2 | Optional module only. See §4. |
| `swift-numerics` | — | T0 | **No value.** No matmul, no tensor type, no NN layers. |
| Swift for TensorFlow | — | — | **Dead.** `archived: true`, last push 2022‑01‑12. |
| MLX, MLTensor/CoreML | — | **T3** | Banned. |

### 2.4 Recommendation

**Adopt reading (B) as the shipping default and keep reading (A) as a first‑class, CI‑tested build configuration selected by a SwiftPM trait.**

The reason this is not fence‑sitting: the strict backend already exists at 486 lines and *agrees exactly* with PCRE2 on all eight corpora. Two independent implementations that agree bit‑for‑bit is the strongest correctness signal available for a PII detector, and running the pure engine as a differential oracle in CI turns the purity work into a QA asset rather than a tax.

### 2.5 What insisting on (A) actually costs

| Item | (B) | (A) | Delta |
|---|---|---|---|
| Regex engine | PCRE2, 1.5 pw | Pure‑Swift engine hardened, 8 pw | **+6.5 pw**; **5.0× slower today** (11.14 s vs 2.21 s), expected 2–2.5× after optimization (unmeasured) |
| Crypto | swift‑crypto | CryptoSwift | **+0 pw**, −6% throughput (noise). Lose constant‑time. |
| Config | Yams | build‑time YAML→JSON | **+0.3 pw**; lose runtime YAML editing |
| Foundation‑free core (own JSON, file I/O) | n/a | required if T0 rather than T1 | **+2.0 pw** |
| **REST API server** | Hummingbird | **impossible** — SwiftNIO cannot be made C‑free | **capability deleted** (≈3 pw of scope removed, and the product loses its HTTP surface) |
| Binary size | 65 MB static musl (Foundation + NSRE + crypto + Yams + Hummingbird) | 6–10 MB if fully T0; 52 MB the moment you touch `NSRegularExpression` | (A) is dramatically smaller |
| NER | identical | identical | **+0 pw** — the NER port is already T0 |
| Tokenizer | NSRegularExpression | hand‑coded matcher | **+1 pw**, and it runs **2× faster** |

**Net strict‑(A) premium: +8.8 person‑weeks, loss of the REST server, 5× regex slowdown today.** In exchange: a 6–10 MB binary, a real WASM/Android/embedded story, zero platform‑behaviour variance, and no CVE‑tracking obligation for vendored C.

---

## 3. Regex Substrate Decision

### 3.1 The decision

> **Default backend: PCRE2 10.47 vendored as a SwiftPM C target, with `PCRE2_UTF | PCRE2_UCP | PCRE2_CASELESS | PCRE2_MULTILINE | PCRE2_DOTALL` and explicit `MATCH_LIMIT` / `MATCH_LIMIT_DEPTH`.**
> **Strict backend: the pure‑Swift engine, behind the same `RegexBackend` protocol, run as a differential oracle on every CI job.**
> **Neither `NSRegularExpression` nor Swift Regex is a shipping engine.**

### 3.2 The measurements

**Correctness — 155 patterns vs Python `regex` on `corpus_clean.txt` (117,610 scalars, 3,856 literals AST‑extracted from Presidio's 140 test files; Python reference total = 7,591 spans):**

| Engine | Compile | Identical span‑sets | Recall | Precision |
|---|---|---|---|---|
| **PCRE2 (UTF\|UCP)** | 155 | **155/155** | 1.0000 | 1.0000 |
| **Pure‑Swift engine** | 155 | **155/155** | 1.0000 | 1.0000 |
| NSRegularExpression | 155 | 155/155 | 1.0000 | 1.0000 |
| Oniguruma (`ONIG_SYNTAX_RUBY`) | 155 | 154/155 | 0.9996 | 0.9903 |
| Oniguruma (`ONIG_SYNTAX_PYTHON`) | 146 | 145/155 | 0.9821 | 0.9902 |
| Swift Regex + `.simple` | 136 | 136/136 | 0.9117 | 1.0000 |
| Swift Regex default | 136 | 126/155 | 0.9082 | 0.9962 |
| Swift Regex `.simple` + `.unicodeScalar` | 136 | 21/155 | **0.2869** | 0.7277 |

Counter‑intuitively, Oniguruma's `ONIG_SYNTAX_PYTHON` is *worse* than its Ruby syntax: it rejects 9 patterns with `invalid pattern in look-behind` — every `(?<![\w-])` and `(?<![\w:])` — because it computes lookbehind width in **bytes** and Unicode `\w` is variable‑width in UTF‑8.

### 3.3 The `\b` problem

This is the single largest correctness risk in the whole port, and it is fully characterised.

ICU's `\b` ignores combining marks and default‑ignorable characters; Python's does not. On a dirty corpus (2,582 distinct PII tokens, each wrapped with exactly one invisible character on each side):

| Engine | clean | SHY | ZWSP | BOM | LRM | WJ | COMB (U+0301) |
|---|---|---|---|---|---|---|---|
| **PCRE2** | 100.0 | 100.0 | 100.0 | 100.0 | 100.0 | 100.0 | **100.0** (0 FP) |
| **Pure‑Swift** | 100.0 | 100.0 | 100.0 | 100.0 | 100.0 | 100.0 | **100.0** (0 FP) |
| NSRE + `\b` rewrite | 100.0 | 100.0 | 100.0 | 100.0 | 100.0 | 100.0 | 100.0 (0 FP) |
| **NSRE raw** | 100.0 | **32.0** | **32.0** | **32.0** | **32.0** | **32.0** | 96.4 (486 FP) |
| Swift Regex `.simple` | 92.3 | 92.3 | 92.3 | 92.3 | 92.3 | 92.3 | **36.8** (5,823 FP) |
| Swift Regex default | 92.3 | 24.4 | 92.2 | 24.4 | 24.4 | 24.4 | 36.7 (5,848 FP) |

**One soft hyphen adjacent to each PII span costs NSRegularExpression 68% of its matches.** The mechanical fix, applied outside character classes to 131/155 patterns:

```
\b  →  (?:(?<=\w)(?!\w)|(?<!\w)(?=\w))
```

restores 0 FN / 0 FP everywhere — at **+55% throughput** (7.71 s vs 4.99 s for 155 patterns), more than double the 22% previously estimated. Swift Regex cannot use it because it contains lookbehind.

**PCRE2 and the pure‑Swift engine need no rewrite at all.** That is the decisive fact: 131 patterns you never have to touch, and 131 places a rewrite bug cannot hide.

Why the rewrite works when it is needed: enumerating all 1,112,064 scalars showed Darwin ICU's `\w` is a strict **superset** of Python's — ICU 149,440 vs py‑`regex` 144,667, with **zero** Python‑only members and all 4,773 ICU extras at or above U+088F (all `Cn`/`Co` in Python's tables). `\d`: 770 vs 760, same direction. `\s`: 25 = 25, identical.

### 3.4 MULTILINE line terminators

NSRegularExpression and Swift Regex both treat `\n`, `\r`, `\r\n`, U+000B, U+000C, U+0085, U+2028, U+2029 as line terminators for `^`/`$`. Python (`re` and `regex`) honours **only** `\n`. That is an 8‑way divergence in principle.

**It is moot.** Grepping all 155 patterns: **zero** use `^` or `$` as anchors. The only two hits (#97, #154) are `^` and `$` *inside character classes*. `useUnixLineSeparators` changes nothing, confirmed by a full 155‑pattern sweep.

**Action:** add a lint that fails the build if a future pattern introduces an anchored `^` or `$`, so this stays moot.

### 3.5 The `regex`‑module vs ICU dialect question

Presidio imports the third‑party `regex` module, not stdlib `re` (`pattern.py:4`, `pattern_recognizer.py:6`, `analyzer_engine.py:8`, `iban_recognizer.py:6`). They disagree on 289 match sets over an adversarial corpus. **Validate against `regex`, never `re`.**

Class sizes across all four engines (full‑Unicode enumeration):

| | Swift stdlib | Darwin ICU | py‑`regex` | py‑`re` |
|---|---|---|---|---|
| `\w` | 147,467 | 149,440 | **144,667** | 133,023 |
| `\d` | 2,023 | 770 | **760** | 650 |
| `\s` | — | 25 | **25** | 29 |

The pure‑Swift engine achieves exact parity by **generating its tables from Python's own class membership**: 144,667 + 760 + 25 codepoints compress to 796 + 71 + 10 = **877 ranges, ~7 KB**. That is the whole trick — Python‑compatible semantics is a data problem, not an algorithm problem. PCRE2 carries its own Unicode tables under `PCRE2_UCP` and lands on the same answers for these 155 patterns.

Also relevant to the global flags: `pattern_recognizer.py:59` sets `DOTALL|MULTILINE|IGNORECASE` on **every** pattern, and there are 12 inline `(?i)` flags on top. Both backends must apply the global flags identically, and the harness must test that.

### 3.6 Cross‑platform ICU version skew

**Retired empirically, and in two independent ways.**

1. **Measured**: the full 155‑pattern sweep produced a byte‑identical output file on macOS (Apple's closed Foundation → `libicucore`) and on WASI (corelibs‑foundation → vendored `swift-foundation-icu`) — same match count (1,698), same offsets, same digest `f1b1e60b48e31c3c`.
2. **Structural**: `swift-corelibs-foundation/Package.swift:228` pulls `.product(name: "_FoundationICU", package: "swift-foundation-icu")` — ICU is **vendored and pinned**, not the system ICU. Linux, Windows, Android and WASI therefore all share one ICU build. The only skew axis was ever Darwin‑vs‑everything, and that axis is now measured as zero for this workload.

**And it becomes irrelevant under the recommendation anyway**: neither PCRE2 nor the pure‑Swift engine touches ICU. Both are byte‑deterministic across platforms by construction.

The residual unverified case is **glibc Linux distros that link system ICU** rather than the SDK's static `lib_FoundationICU.a`. That path was never exercised. It only matters if you ignore this recommendation and ship `NSRegularExpression`.

### 3.7 Performance

135 patterns (155 minus the 19 Swift Regex cannot compile, minus backtracking bomb #97) × 759,142 scalars, all producing 1,373 matches. Single‑threaded, precompiled, best of 2:

| Engine | Time | vs NSRE |
|---|---|---|
| Python `regex` module | 1.82 s | 0.70× |
| Oniguruma | 2.04 s | 0.78× |
| **PCRE2** | **2.21 s** | **0.85×** |
| NSRegularExpression | 2.61 s | 1.00× |
| **Pure‑Swift engine** | **11.14 s** | 4.27× |
| Swift Regex `.simple` | 30.14 s | 11.55× |

Full 155 patterns: Oniguruma 3.94 s, **PCRE2 4.15 s**, PCRE2‑through‑the‑SwiftPM‑wrapper **4.18 s** (Swift bridging is free), NSRE 4.99 s, NSRE + `\b` rewrite 7.71 s.

**Pattern skew dominates.** `\b((?=.*?[a-zA-Z])(?=.*?[0-9]{4})[\w@#$%^?~-]{10})\b` (#97) alone is **38.8%** of the NSRE sweep; the top 5 are 49.7%; the median pattern is 3.6 ms. Consequences:

- Parallelising **over patterns** has a measured ceiling of **2.30×** on 14 cores. Parallelise over **text chunks** instead.
- #97 is a backtracking bomb in every engine (1.9 s of PCRE2's 4.2 s; 16.5 s under Swift Regex). Whatever ships **must** have a match limit. PCRE2 has one; Swift Regex does not. Upstream Python relies on the `regex` module's `timeout=REGEX_TIMEOUT_SECONDS` and logs a warning on `TimeoutError` — mirror that behaviour, including the warning and the skip.
- Precompiling buys essentially nothing (155‑pattern compile = 0.006 s; recompile‑every‑time 4.55 s vs precompiled 4.57 s). Cache patterns for tidiness, not speed.

### 3.8 Migration and lint strategy

1. **Patterns move verbatim.** No rewriting, no surgery. Extract all 155 literals + 76 IBAN country regexes + 6 assembled patterns from Python into JSON at build time. Snapshot‑test the extraction against upstream.
2. **`PatternLint` build plugin** enforces the closed feature census so the strict backend never sees something it cannot compile. Fail the build on: named groups, named backrefs, atomic groups, possessive quantifiers, conditionals, `\p{...}`, variable‑width lookbehind, `\B`, and anchored `^`/`$`. Current counts are all **zero**; 19 fixed‑width single‑char negative lookbehinds, 28–29 negative lookaheads, 2 numeric backrefs, 12 inline `(?i)` are permitted.
3. **A `\b`‑rewrite pass exists but is not enabled** for PCRE2 or the pure engine. It is retained, tested, and switched on only for an `NSRegularExpression` fallback build, if you ever want one.
4. **Differential CI** on every job: PCRE2 vs pure‑Swift vs the Python `regex` golden fixtures, over all eight corpora.
5. **Offsets**: PCRE2 works in UTF‑8 bytes. Maintain a byte→scalar map in `TextDocument` (≈10 lines) so every offset crossing a module boundary is a Unicode scalar index, matching Python.
6. **You own PCRE2 CVE tracking.** Pin the version, subscribe to the PCRE2 announce list, add a quarterly bump task.

---

## 4. NER Strategy

### 4.1 Ranked options

**#1 — Port spaCy v3 NER inference to pure Swift and load Explosion's MIT weights. This is built and verified.**

| Metric | `en_core_web_sm` | `en_core_web_lg` |
|---|---|---|
| Entity parity vs spaCy 3.7.5 | **2592 / 2592**, 0 FP, 0 FN, P=1.000000 R=1.000000 | **2324 / 2324**, 0 FP, 0 FN |
| Mismatched sentences | 0 / 2000 | 0 / 2000 |
| Throughput (Swift, 1 thread) | **28,574 tok/s** | **25,446 tok/s** |
| spaCy `ner.pipe(batch=256)` | 14,964 tok/s | 13,355 tok/s |
| spaCy **full** pipeline (what Presidio runs) | 2,977 tok/s | 3,339 tok/s |
| Max RSS | — | **120 MB** (vs 979 MB for Python) |
| Load time | 5 ms | 71 ms |
| Shipped NER assets | **~6.2 MB** | **~630 MB** (`vocab/vectors` alone is 616,988,528 B) |
| OntoNotes dev `ents_f` | 0.8456 | 0.8543 |

Per‑label F1 (`sm` / `lg`): PERSON 0.877 / 0.896, ORG 0.809 / 0.824, GPE 0.904 / 0.916, LOC 0.697 / 0.650, DATE 0.872 / 0.876.

The engine is **618 lines** (560 non‑blank/non‑comment), **no `import Foundation`**, no C: minimal msgpack decoder (66 LOC), MurmurHash64A + MurmurHash3_x86_128_uint64 (40), lexical attrs (16), SIMD GEMM (52), graph loading (176), forward + greedy BILUO transition decoder (166). GEMM: `SIMD8<Float>.addProduct` register‑tiled 4×2 hits **52–58 GFLOP/s** at the tok2vec shapes — 14–15× naive scalar loops, no BLAS.

Critical implementation detail that cost a full debugging cycle: spaCy's `StringStore` id is `MurmurHash64A(utf8, seed=1)` **except** for 457 reserved symbols in `spacy.symbols.IDS` (ids 0–456), which include ordinary words (`number`, `det`, `num`, `root`, `obj`, `aux`, `conj`, `dep`, `mark`, `meta`, `neg`, `poss`, `prep`, `punct`, …). Before the fix: P=0.97493, R=0.99035, 49/2000 sentences wrong. After: exact.

Also confirmed empirically: the NER pipe carries its **own** `spacy.Tok2Vec.v2`, not a `Tok2VecListener` — `spacy.load(..., exclude=['tagger','parser','lemmatizer','attribute_ruler','senter','tok2vec'])` yields `pipe_names == ['ner']` and still produces entities. So tagger, parser, lemmatizer, senter and attribute_ruler are all droppable.

**#2 — ONNX Runtime as an optional module** for teams that want a transformer. ORT 1.28 BERT‑base seq=128, 1 thread: **47.5 ms**. Swift‑to‑ORT‑C‑API binding overhead measured at **2–8%** vs an identical C program. But: Microsoft's `onnxruntime-swift-package-manager` is **Objective‑C over an Apple xcframework**, declares `platforms: [.iOS(.v15), .macOS(.v14)]`, and pins ORT 1.24.2 against upstream 1.28.0 — unusable. You would write and maintain your own SE‑0482 artifactbundle over the official per‑platform tarballs (linux‑x64, linux‑aarch64, osx‑arm64, win‑x64, win‑arm64; Android needs the Maven AAR repackaged; **WASM has no path at all**). 39.3 MB of `.dylib` per platform slice. ~4 pw.

**#3 — Pure‑Swift transformer inference.** Works, but costs 9.0×: BERT‑base seq=128 measured at **428.5 ms** single‑thread / 75.1 ms on 14 threads vs ORT's 47.5 ms, interleaved under identical load. Note the x86 trap: `SIMD16.addProduct` lowers to **64 `callq fmaf@PLT` libm calls** per inner loop on the default baseline x86‑64 target. `-Xswiftc -Xllvm -Xswiftc -mcpu=haswell` fixes it (8 `vfmadd`, 110 `%ymm`) at the cost of an AVX2 deployment baseline.

**#4 — Zero‑model fallback (regex + checksums + context + gazetteers).** Stronger than expected and worth shipping first: of **94 distinct entity types** across 99 predefined recognizer classes, exactly **7 are NER‑only** (PERSON, LOCATION, ORGANIZATION, NRP, AGE, ID, and EMAIL as a transformers‑label alias of regex‑covered EMAIL_ADDRESS). DATE_TIME and PHONE_NUMBER are dual‑sourced. **87/94 = 92.6% of entity types survive with no statistical model.** What you lose is PERSON/LOCATION/ORGANIZATION/NRP — few types, but the dominant share of free‑text PII by span count.

**#5 — Train from scratch (10 pw) or CRF+gazetteers (12 pw).** Both strictly dominated. The blocker is data licensing, not modelling: CoNLL‑2003 needs Reuters RCV1 from NIST with separate commercial verification; OntoNotes is LDC‑licensed; WikiANN is silver‑standard. Do not go here unless legal vetoes the MIT weights.

### 4.2 The licensing answer, plainly

**`en_core_web_sm` / `md` / `lg` v3.7.1 are MIT, weights included.** Evidence read from the downloaded wheels:

- The full MIT text ships **inside the model package** next to `ner/model`: `en_core_web_sm-3.7.1/LICENSE`, "Copyright 2021 ExplosionAI GmbH". Same for `lg`.
- `meta.json`: `license = "MIT"` for both.
- HuggingFace model card `spacy/en_core_web_lg`: `license: MIT`.
- OntoNotes 5 appears only in `LICENSES_SOURCES` as `"commercial (licensed by Explosion)"` — i.e. Explosion bought the LDC license and released the derived weights under MIT. That is **their** obligation, discharged, not yours.
- `lg` static vectors: CC0.
- The lemmatizer's `lookups.bin` carries **WordNet 3.0** (permissive, attribution required) — but you are not shipping the lemmatizer (§4.3).

**English is licence‑clean. Other languages are not uniformly so.** Measured from `meta.json` of the 3.7.0 `_sm` wheels: `de`, `zh`, `ru`, `xx_ent_wiki` are **MIT**; `es` is **GPL‑3.0**; `fr` is **LGPL‑LR**; `it` is **CC BY‑NC‑SA 3.0 (non‑commercial)**; `nl` and `pt` are **CC BY‑SA 4.0**. If the product ships Italian or Spanish, that is a hard legal problem with nothing to do with Swift.

Caveat to record for counsel: whether an LDC‑derived model's weights can be MIT‑relicensed is a legal question the sub‑agent could not settle. The package labels itself MIT unambiguously; that is as far as engineering can take it.

### 4.3 The lemma disagreement — resolved

Two sub‑agents disagreed. The NER agent said Presidio consumes lemmas, so exact parity requires porting the shared tok2vec + tagger + attribute_ruler + rule lemmatizer (+2–3 pw, plus the WordNet obligation). The NLP agent **measured** what lemmas are actually worth.

Over 333,448 real tokens with spaCy's actual lemmatizer:

- `surface != lemma` on **13.38%** of tokens.
- Presidio's context‑word verdict differs on only **1.0262%**.
- Dropping lemmatization **loses 142 matches, of which only 5 are semantically real** (`saving`→`save` ×3, `securities`→`security` ×1, `elucidating`→`date` ×1). The other 137 are substring accidents (`found` ⊃ `"fin"` ×116).
- Dropping lemmatization **removes 3,322 spurious matches** (`said` ⊃ `"id"` ×845, `did` ⊃ `"id"` ×387, `combining` ⊃ `"nin"` ×303, `us` ⊃ `"us"` ×214).

**Lemmatization's real job in Presidio is accidental false‑positive suppression, at a 23:1 ratio over recall.** A 10‑rule suffix stemmer + the WordNet index gets 91.8% exact lemma agreement, **99.27%** substring‑verdict agreement, and 99.85% of whole‑word context hits.

Exact parity is unattainable anyway: `en_core_web_*` runs the lemmatizer in `mode="rule"`, keyed off `token.pos_`. A POS‑free variant recovers only 13/16 affected forms (12.7% of probability mass) because `dating`/`saving` are legitimate nouns.

**Ruling: the NLP agent's measurement wins. Ship the stemmer; do not port the tagger. Saves 2–3 pw.** Simultaneously change two defaults, which buys far more than lemmatization ever did: set `context_matching_mode = "whole_word"` and drop context words shorter than 4 characters.

### 4.4 Deployment shape

Ship `<model>/ner/model` (6.15 MB), `<model>/ner/moves` (1 KB), `<model>/vocab/lookups.bin` (70 KB), and a generated 457‑entry symbol table (6.8 KB). **Prefer `sm`** — 6.2 MB vs 630 MB for +0.9 F1. If you do ship `lg`, mmap the `.npy` (that is why `lg` RSS is 120 MB rather than ~750 MB).

---

## 5. Proposed Architecture

### 5.1 SwiftPM target graph

```
Package: swift-presidio                      Swift 6.2, traits: [PCRE2 (default), Server (default), StrictPure]

products
├── Presidio              (library, umbrella)
├── PresidioAnalyzer      (library)
├── PresidioAnonymizer    (library)
├── presidio-cli          (executable)
└── presidio-server       (executable)        [trait: Server; excluded on wasm]

targets                                        tier   notes
├── PresidioCore                                T0    TextDocument, offsets, RecognizerResult,
│                                                     EntityRecognizer, AnalysisExplanation. No Foundation.
├── PresidioRegexAPI                            T0    RegexBackend / CompiledPattern protocols, MatchLimits
├── CPCRE2                                      T2    30 PCRE2 .c + config.h.generic + pcre2.h.generic
│                                                     + pcre2_chartables.c.dist + umbrella + modulemap.
│                                                     JIT EXCLUDED (no runtime codegen → iOS/Android/WASM safe).
│                                                     [trait: PCRE2]
├── PresidioRegexPCRE2                          T2    Swift wrapper; byte↔scalar offset mapping  [trait: PCRE2]
├── PresidioUnicodeTables                       T0    generated: 877 ranges (\w 796, \d 71, \s 10), ~7 KB
├── PresidioRegexPure                           T0    486-LOC backtracking engine + first-scalar prefilter
│                                                     + 128-bit ASCII class bitmap
├── PresidioTokenizer                           T0    spaCy rule tokenizer: PureMatcher (164 LOC, zero
│                                                     imports) + Sets.swift (20 KB) + Rules.swift (84 KB)
├── PresidioNLP                                 T0    NLPEngine/NLPArtifacts, stemmer, stopwords, chunker
├── PresidioNER                                 T0    msgpack decoder, MurmurHash, MultiHashEmbed, Maxout,
│                                                     LayerNorm, SIMD GEMM, greedy BILUO decoder
├── PresidioModelEN                             --    resource-only: ner/model, moves, lookups.bin, symbols
│                                                     (separate package `swift-presidio-models-en`)
├── PresidioGazetteer                           T0    byte-level Aho-Corasick, CSR-packed goto
├── PresidioValidators                          T0    55 checksum validators
├── PresidioPhone                                T0    libphonenumber subset, 8 default regions  (see §9)
├── PresidioRecognizers                         T0    99 recognizers; JSON specs + generated factory table
├── PresidioAnalyzerCore                        T1    AnalyzerEngine, RecognizerRegistry, context enhancer
├── PresidioCrypto                              T0/T2 CryptoSwift (StrictPure) | swift-crypto (default)
├── PresidioAnonymizerCore                      T1    11 operators, AES-CBC, batch + deanonymize engines
├── PresidioServer                              T2    Hummingbird 2.x   [trait: Server; #if !os(WASI)]
├── PresidioCLI                                 T1
└── PresidioConformance                         T1    differential harness (test-support product)

plugins
├── RecognizerCodeGen   (build tool)  recognizers/*.json  → GeneratedRecognizers.swift
├── PatternLint         (build tool)  enforce the closed regex feature census
└── UnicodeTableGen     (command)     regenerate \w/\d/\s ranges from Python `regex`

test targets mirror each source target, plus PresidioConformanceTests (golden-fixture driven).
```

Platform gating: `PresidioServer` is excluded on WASI (SwiftNIO needs sockets and threads). `PresidioCrypto` selects CryptoSwift on WASI regardless of trait (`_CryptoExtras` does not build there). Everything else is unconditional.

> Package traits (SE‑0450) are the mechanism for the (A)/(B) switch. No sub‑agent built a traits‑based package; treat the exact manifest syntax as design intent to be validated on day one.

### 5.2 `TextDocument` and the offset model

Every index that crosses a module boundary is a **Unicode scalar index**, identical to Python's `str` index space. UTF‑16 offsets never escape a component. This matters: `"A😀B"` is 3 scalars but 4 UTF‑16 units.

```swift
public typealias ScalarRange = Range<Int>

/// Immutable, precomputed view of a document. Built once per analysis request.
/// Scalar indices are the canonical offset space and match Python's `str` indices exactly.
public struct TextDocument: Sendable {
    public let text: String
    public let scalars: [Unicode.Scalar]
    /// UTF-8 bytes, for byte-oriented backends (PCRE2, Aho-Corasick).
    public let utf8: [UInt8]
    /// True when every scalar is < U+0080, enabling the identity offset fast path.
    public let isASCII: Bool

    // Materialised only when !isASCII. Int32 caps documents at 2 GiB — documented limit.
    @usableFromInline internal let byteToScalarMap: [Int32]   // count == utf8.count + 1
    @usableFromInline internal let scalarToByteMap: [Int32]   // count == scalars.count + 1

    public init(_ text: String) {
        var scalars: [Unicode.Scalar] = []
        var bytes: [UInt8] = []
        var b2s: [Int32] = []
        var s2b: [Int32] = []
        scalars.reserveCapacity(text.unicodeScalars.count)
        bytes.reserveCapacity(text.utf8.count)

        var ascii = true
        for scalar in text.unicodeScalars {
            let scalarIndex = Int32(scalars.count)
            s2b.append(Int32(bytes.count))
            if scalar.value > 0x7F { ascii = false }
            UTF8.encode(scalar) { byte in
                bytes.append(byte)
                b2s.append(scalarIndex)
            }
            scalars.append(scalar)
        }
        b2s.append(Int32(scalars.count))
        s2b.append(Int32(bytes.count))

        self.text = text
        self.scalars = scalars
        self.utf8 = bytes
        self.isASCII = ascii
        self.byteToScalarMap = ascii ? [] : b2s
        self.scalarToByteMap = ascii ? [] : s2b
    }

    @inlinable public func scalarIndex(utf8Offset o: Int) -> Int {
        isASCII ? o : Int(byteToScalarMap[o])
    }
    @inlinable public func utf8Offset(scalarIndex i: Int) -> Int {
        isASCII ? i : Int(scalarToByteMap[i])
    }
    @inlinable public func scalarRange(utf8 r: Range<Int>) -> ScalarRange {
        scalarIndex(utf8Offset: r.lowerBound) ..< scalarIndex(utf8Offset: r.upperBound)
    }
    public func slice(_ r: ScalarRange) -> String {
        var s = String.UnicodeScalarView()
        s.reserveCapacity(r.count)
        for i in r { s.append(scalars[i]) }
        return String(s)
    }
}
```

### 5.3 `RecognizerResult`

Ordering deserves a precise statement. Python's `remove_duplicates` does `list(set(results))` then `sorted(key=lambda x: (-score, start, -(end-start)))`. The sort is deterministic; the *only* nondeterminism is ties on all three keys with differing `entity_type`, where the stable sort preserves `PYTHONHASHSEED`‑randomised set order. So: extend the key to a **total** order, and compare as a multiset in the harness.

```swift
public struct RecognitionMetadata: Sendable, Hashable, Codable {
    public var recognizerName: String
    public var recognizerIdentifier: String
    public var isScoreEnhancedByContext: Bool = false
}

public struct RecognizerResult: Sendable, Hashable, Codable {
    public var entityType: String
    public var start: Int          // scalar index, inclusive
    public var end: Int            // scalar index, exclusive
    public var score: Double
    public var explanation: AnalysisExplanation?
    public var metadata: RecognitionMetadata

    // Parity note: Python's __eq__/__hash__ use only (start, end, score, entity_type).
    public static func == (a: Self, b: Self) -> Bool {
        a.start == b.start && a.end == b.end && a.score == b.score && a.entityType == b.entityType
    }
    public func hash(into h: inout Hasher) {
        h.combine(start); h.combine(end); h.combine(score); h.combine(entityType)
    }

    @inlinable public var length: Int { end - start }
    @inlinable public func intersects(_ o: Self) -> Int {
        (end < o.start || o.end < start) ? 0 : Swift.min(end, o.end) - Swift.max(start, o.start)
    }
    @inlinable public func contained(in o: Self) -> Bool { start >= o.start && end <= o.end }
    @inlinable public func contains(_ o: Self) -> Bool { start <= o.start && end >= o.end }
    @inlinable public func hasEqualIndices(_ o: Self) -> Bool { start == o.start && end == o.end }

    /// Python: `sorted(key=(-score, start, -(end - start)))`, with (entityType,
    /// recognizerIdentifier) appended to make the order total where Python's is
    /// PYTHONHASHSEED-dependent.
    public static func presidioOrder(_ a: Self, _ b: Self) -> Bool {
        if a.score != b.score { return a.score > b.score }
        if a.start != b.start { return a.start < b.start }
        if a.length != b.length { return a.length > b.length }
        if a.entityType != b.entityType { return a.entityType < b.entityType }
        return a.metadata.recognizerIdentifier < b.metadata.recognizerIdentifier
    }
}
```

### 5.4 Regex backend protocol

Two backends, one protocol. PCRE2 compiled code is safe to share across threads provided each match uses its own `pcre2_match_data`; that invariant is what `@unchecked Sendable` documents.

```swift
public struct PatternOptions: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let caseInsensitive  = PatternOptions(rawValue: 1 << 0)
    public static let multiline        = PatternOptions(rawValue: 1 << 1)
    public static let dotMatchesNewline = PatternOptions(rawValue: 1 << 2)
    /// Presidio's global flags: pattern_recognizer.py:59 sets DOTALL|MULTILINE|IGNORECASE.
    public static let presidioDefault: PatternOptions = [.caseInsensitive, .multiline, .dotMatchesNewline]
}

public struct MatchLimits: Sendable {
    public var matchLimit: UInt32 = 1_000_000
    public var depthLimit: UInt32 = 10_000
    public init() {}
}

public struct PatternMatch: Sendable {
    public let range: ScalarRange
    public let groups: [ScalarRange?]   // Presidio consumes only `range`; groups exist for backrefs/debug
}

public enum RegexError: Error, Sendable {
    case compilationFailed(pattern: String, message: String)
    case unsupportedConstruct(pattern: String, construct: String)
    case matchLimitExceeded(pattern: String)
}

public protocol CompiledPattern: Sendable {
    var source: String { get }
    /// Must return matches in ascending start order, non-overlapping, leftmost-longest
    /// per the engine's backtracking semantics — i.e. Python `finditer` order.
    func matches(in doc: TextDocument, limits: MatchLimits) throws -> [PatternMatch]
}

public protocol RegexBackend: Sendable {
    static var identifier: String { get }          // "pcre2-10.47" | "pure-swift-1"
    func compile(_ source: String, options: PatternOptions) throws -> any CompiledPattern
}
```

`PresidioRegexPCRE2.PCRE2Pattern` is a `final class ... @unchecked Sendable` wrapping `pcre2_code *`, allocating a fresh `pcre2_match_data` per `matches(in:)` call and translating `PCRE2_ERROR_MATCHLIMIT` into `.matchLimitExceeded` — which the caller logs and skips, mirroring Python's `TimeoutError` branch. `PresidioRegexPure.PureProgram` is a `struct` of value‑type instructions and is naturally `Sendable`.

### 5.5 `EntityRecognizer` and `PatternRecognizer`

Python's lazy `load()` / mutable `is_loaded` is replaced by construction‑time loading. Recognizers become immutable `Sendable` values; the only expensive artefact (the NER model) lives in `NLPEngine`, not in a recognizer. That removes all mutable state from the hot path.

```swift
public enum Validation: Sendable {
    case notApplicable    // Python: validate_result returned None
    case valid            // → score = 1.0
    case invalid          // → score = 0.0
}

public protocol EntityRecognizer: Sendable {
    var identifier: String { get }
    var name: String { get }
    var version: String { get }
    var supportedEntities: [String] { get }
    var supportedLanguage: String { get }
    var context: [String] { get }
    var countryCode: String? { get }
    var defaultScoreThreshold: Double { get }

    func analyze(_ doc: TextDocument,
                 entities: Set<String>,
                 artifacts: NLPArtifacts?) throws -> [RecognizerResult]
}

public extension EntityRecognizer {
    var version: String { "0.0.1" }
    var countryCode: String? { nil }
    var context: [String] { [] }
    var defaultScoreThreshold: Double { 0.0 }
}

/// Score constants mirror EntityRecognizer.MIN_SCORE = 0 / MAX_SCORE = 1.0.
public enum Score {
    public static let min = 0.0
    public static let max = 1.0
}

public struct PatternRecognizer: EntityRecognizer {
    public struct CompiledSpec: Sendable {
        public let name: String
        public let score: Double
        public let compiled: any CompiledPattern
        public let source: String
    }

    public let identifier: String
    public let name: String
    public let version: String
    public let supportedLanguage: String
    public let supportedEntity: String
    public let context: [String]
    public let countryCode: String?
    public let defaultScoreThreshold: Double

    public var supportedEntities: [String] { [supportedEntity] }

    private let patterns: [CompiledSpec]
    private let limits: MatchLimits
    private let validate: (@Sendable (String) -> Validation)?
    private let invalidate: (@Sendable (String) -> Bool)?

    public func analyze(_ doc: TextDocument,
                        entities: Set<String>,
                        artifacts: NLPArtifacts?) throws -> [RecognizerResult] {
        guard entities.contains(supportedEntity) else { return [] }
        var out: [RecognizerResult] = []

        for spec in patterns {
            let matches: [PatternMatch]
            do {
                matches = try spec.compiled.matches(in: doc, limits: limits)
            } catch RegexError.matchLimitExceeded {
                // Parity with pattern_recognizer.py: log and skip this pattern only.
                Diagnostics.warn("pattern '\(spec.name)' exceeded match limit; skipping")
                continue
            }

            for m in matches where !m.range.isEmpty {
                let text = doc.slice(m.range)
                var score = spec.score
                var validation: Validation = .notApplicable

                if let validate {
                    validation = validate(text)
                    switch validation {
                    case .valid:   score = Score.max
                    case .invalid: score = Score.min
                    case .notApplicable: break
                    }
                }
                if let invalidate, invalidate(text) { score = Score.min }
                guard score > Score.min else { continue }

                out.append(RecognizerResult(
                    entityType: supportedEntity,
                    start: m.range.lowerBound,
                    end: m.range.upperBound,
                    score: score,
                    explanation: AnalysisExplanation(
                        recognizer: name, originalScore: spec.score, score: score,
                        patternName: spec.name, pattern: spec.source,
                        validationResult: validation),
                    metadata: RecognitionMetadata(recognizerName: name,
                                                  recognizerIdentifier: identifier)))
            }
        }
        return RecognizerResult.removeDuplicates(out)
    }
}
```

`removeDuplicates` is a direct transcription of `entity_recognizer.py:275`:

```swift
public extension RecognizerResult {
    /// Port of EntityRecognizer.remove_duplicates.
    static func removeDuplicates(_ results: [RecognizerResult]) -> [RecognizerResult] {
        let unique = Array(Set(results)).sorted(by: RecognizerResult.presidioOrder)
        var kept: [RecognizerResult] = []
        for r in unique {
            if r.score == Score.min { continue }
            var keep = !kept.contains(r)
            if keep {
                for f in kept where r.contained(in: f) && r.entityType == f.entityType {
                    keep = false; break
                }
            }
            if keep { kept.append(r) }
        }
        return kept
    }
}
```

### 5.6 `NLPEngine` and `NLPArtifacts`

Python carries `tokens` and `tokens_indices` as parallel arrays; fold them into `Token`. `keywords` is derived exactly per `nlp_artifacts.set_keywords`.

```swift
public struct Token: Sendable, Hashable {
    public let text: String
    public let range: ScalarRange
    public let lemma: String
    public let isStopWord: Bool
    public let isPunctuation: Bool
}

public struct NLPEntity: Sendable, Hashable {
    public let label: String          // PERSON | LOC | ORG | GPE | DATE | ...
    public let range: ScalarRange
    public let score: Double          // spaCy has no per-entity score; Presidio defaults to 0.85
}

public struct NLPArtifacts: Sendable {
    public let language: String
    public let tokens: [Token]
    public let entities: [NLPEntity]
    public let keywords: [String]

    public var lemmas: [String] { tokens.map(\.lemma) }
    public var tokenIndices: [Int] { tokens.map { $0.range.lowerBound } }

    /// Port of NlpArtifacts.set_keywords: lowercased lemmas, minus stopwords and
    /// punctuation, minus "-PRON-" and "be", then split on ":" and flattened.
    public static func keywords(from tokens: [Token]) -> [String] {
        tokens.lazy
            .filter { !$0.isStopWord && !$0.isPunctuation }
            .map { $0.lemma.lowercased() }
            .filter { $0 != "-pron-" && $0 != "be" }
            .flatMap { $0.split(separator: ":", omittingEmptySubsequences: false).map(String.init) }
    }
}

public protocol NLPEngine: Sendable {
    var identifier: String { get }
    var supportedLanguages: [String] { get }
    var supportedEntities: [String] { get }
    func process(_ doc: TextDocument, language: String) throws -> NLPArtifacts
    func processBatch(_ docs: [TextDocument], language: String) throws -> [NLPArtifacts]
    func isStopWord(_ word: String, language: String) -> Bool
    func isPunctuation(_ word: String, language: String) -> Bool
}
```

Three implementations: `SpacyNLPEngine` (tokenizer + NER port), `SlimNLPEngine` (tokenizer + stemmer, no NER), `NoOpNLPEngine` (parity with `conf/no_op.yaml`; returns empty tokens/lemmas/entities).

### 5.7 Data‑driven recognizers and the factory registry (replacing Python reflection)

Python discovers recognizers via `__subclasses__`/`importlib` in `recognizers_loader_utils.py` (833 LOC). Swift has no equivalent, and that is a feature: replace it with an explicit, generated table. Each of the 99 recognizers becomes a JSON spec; only the ~55 with checksum validators need any Swift.

```json
{
  "id": "UsSsnRecognizer",
  "name": "US SSN Recognizer",
  "version": "0.0.1",
  "entity": "US_SSN",
  "language": "en",
  "countryCode": "US",
  "patterns": [
    { "name": "SSN (very weak)",  "regex": "\\b(([0-9]{5})-([0-9]{4})|([0-9]{3})-([0-9]{6}))\\b", "score": 0.05 },
    { "name": "SSN (weak)",       "regex": "\\b[0-9]{9}\\b",                                        "score": 0.3  },
    { "name": "SSN (medium)",     "regex": "\\b([0-9]{3})-([0-9]{2})-([0-9]{4})\\b",                "score": 0.5  }
  ],
  "context": ["social", "security", "ssn", "ssns", "ssn#", "ss#", "ssid"],
  "denyList": null,
  "denyListScore": 1.0,
  "validator": null,
  "invalidator": "us_ssn_repeated_groups",
  "defaultScoreThreshold": 0.0
}
```

```swift
public struct RecognizerSpec: Sendable, Codable {
    public var id: String
    public var name: String
    public var version: String
    public var entity: String
    public var language: String
    public var countryCode: String?
    public var patterns: [PatternSpec]
    public var context: [String]
    public var denyList: [String]?
    public var denyListScore: Double
    public var validator: String?        // key into ValidatorTable
    public var invalidator: String?
    public var defaultScoreThreshold: Double
}

public struct PatternSpec: Sendable, Codable, Hashable {
    public var name: String
    public var regex: String
    public var score: Double
}

/// Named, side-effect-free checksum validators. 55 of these; all hand-rolled
/// upstream (stdnum is NOT used): 7 Luhn variants, 2 Verhoeff, mod-97/23/11/10,
/// base58, bech32/bech32m.
public enum ValidatorTable {
    public static let validators: [String: @Sendable (String) -> Validation] = [
        "luhn":            { Checksums.luhn($0) ? .valid : .invalid },
        "luhn_no_check":   { Checksums.luhnNoCheckDigit($0) ? .valid : .invalid },
        "verhoeff":        { Checksums.verhoeff($0) ? .valid : .invalid },
        "mod97":           { Checksums.mod97($0) ? .valid : .invalid },
        "iban":            { Checksums.iban($0) ? .valid : .invalid },
        "bech32":          { Checksums.bech32($0) != nil ? .valid : .invalid },
        "base58":          { Checksums.base58Check($0) ? .valid : .invalid },
        // ... 48 more
    ]
    public static let invalidators: [String: @Sendable (String) -> Bool] = [
        "us_ssn_repeated_groups": Invalidators.usSSNRepeatedGroups,
        // ...
    ]
}

/// Replaces Python reflection. `builtins` is emitted by the RecognizerCodeGen plugin
/// from recognizers/*.json; bespoke recognizers register a closure explicitly.
public struct RecognizerFactory: Sendable {
    public typealias Builder =
        @Sendable (RecognizerSpec, RecognizerBuildContext) throws -> any EntityRecognizer

    private var builders: [String: Builder]

    public static func standard() -> RecognizerFactory {
        var f = RecognizerFactory(builders: [:])
        for spec in GeneratedRecognizers.specs {                 // generated, 99 entries
            f.builders[spec.id] = { spec, ctx in
                try PatternRecognizer(spec: spec, backend: ctx.regexBackend)
            }
        }
        // Recognizers that are not pure pattern matchers:
        f.builders["PhoneRecognizer"]  = { _, ctx in PhoneRecognizer(regions: ctx.phoneRegions) }
        f.builders["IpRecognizer"]     = { s, ctx in try IpRecognizer(spec: s, backend: ctx.regexBackend) }
        f.builders["EmailRecognizer"]  = { s, ctx in try EmailRecognizer(spec: s, backend: ctx.regexBackend,
                                                                          suffixList: ctx.publicSuffixList) }
        f.builders["SpacyRecognizer"]  = { _, ctx in SpacyRecognizer(labelMap: ctx.nerLabelMap) }
        return f
    }

    public func make(_ spec: RecognizerSpec, _ ctx: RecognizerBuildContext) throws -> any EntityRecognizer {
        guard let b = builders[spec.id] else { throw PresidioError.unknownRecognizer(spec.id) }
        return try b(spec, ctx)
    }
}

public struct RecognizerRegistry: Sendable {
    private let byLanguage: [String: [any EntityRecognizer]]

    public init(recognizers: [any EntityRecognizer]) {
        self.byLanguage = Dictionary(grouping: recognizers, by: \.supportedLanguage)
    }

    public func recognizers(language: String,
                            entities: Set<String>?,
                            adHoc: [any EntityRecognizer] = []) -> [any EntityRecognizer] {
        let base = byLanguage[language] ?? []
        let all = base + adHoc.filter { $0.supportedLanguage == language }
        guard let entities else { return all }
        return all.filter { !Set($0.supportedEntities).isDisjoint(with: entities) }
    }

    public func supportedEntities(language: String) -> Set<String> {
        Set((byLanguage[language] ?? []).flatMap(\.supportedEntities))
    }
}
```

### 5.8 `AnalyzerEngine`

Pipeline order is a direct transcription of `analyzer_engine.py:169–288`: resolve recognizers → NLP artifacts → run recognizers → context enhancement → remove low scores → dedupe → allow‑list → strip decision process.

```swift
public struct AnalysisRequest: Sendable {
    public var text: String
    public var language: String = "en"
    public var entities: Set<String>? = nil          // nil == all
    public var scoreThreshold: Double? = nil
    public var returnDecisionProcess: Bool = false
    public var context: [String] = []
    public var allowList: [String] = []
    public var allowListMatch: AllowListMatch = .exact
    public var adHocRecognizers: [any EntityRecognizer] = []
}

public struct AnalyzerEngine: Sendable {
    public let registry: RecognizerRegistry
    public let nlpEngine: any NLPEngine
    public let contextEnhancer: any ContextAwareEnhancer
    public let defaultScoreThreshold: Double
    public let regexBackend: any RegexBackend

    public func analyze(_ req: AnalysisRequest) throws -> [RecognizerResult] {
        let doc = TextDocument(req.text)
        let recognizers = registry.recognizers(language: req.language,
                                               entities: req.entities,
                                               adHoc: req.adHocRecognizers)
        let entities = req.entities ?? registry.supportedEntities(language: req.language)
        let artifacts = try nlpEngine.process(doc, language: req.language)

        var results: [RecognizerResult] = []
        for r in recognizers {
            results.append(contentsOf: try r.analyze(doc, entities: entities, artifacts: artifacts))
        }

        results = contextEnhancer.enhance(results: results, doc: doc,
                                          artifacts: artifacts, recognizers: recognizers,
                                          externalContext: req.context)
        results = removeLowScores(results, threshold: req.scoreThreshold, recognizers: recognizers)
        results = RecognizerResult.removeDuplicates(results)
        if !req.allowList.isEmpty {
            results = try removeAllowList(results, doc: doc,
                                          allowList: req.allowList, match: req.allowListMatch)
        }
        if !req.returnDecisionProcess {
            for i in results.indices { results[i].explanation = nil }
        }
        return results.sorted(by: RecognizerResult.presidioOrder)
    }

    /// Chunk-parallel variant. Parallelising over PATTERNS has a measured ceiling of
    /// 2.30x on 14 cores because one pattern is 38.8% of runtime; chunking the text
    /// avoids that skew. Chunk boundaries mirror CharacterBasedTextChunker
    /// (size 250, overlap 50, extend to the next " " or "\n").
    public func analyzeConcurrently(_ req: AnalysisRequest,
                                    chunking: ChunkPolicy) async throws -> [RecognizerResult] {
        let chunks = chunking.chunks(of: req.text)
        var merged: [RecognizerResult] = []
        try await withThrowingTaskGroup(of: [RecognizerResult].self) { group in
            for chunk in chunks {
                group.addTask {
                    var sub = req; sub.text = chunk.text
                    return try analyze(sub).map { $0.shifted(by: chunk.offset) }
                }
            }
            for try await part in group { merged.append(contentsOf: part) }
        }
        return RecognizerResult.removeDuplicates(merged).sorted(by: RecognizerResult.presidioOrder)
    }
}
```

### 5.9 Operators and `AnonymizerEngine`

`presidio-anonymizer` is 2,457 LOC with exactly one regex (`^( )+$`) and no NLP — the cheapest part of the port.

```swift
public enum OperatorKind: Sendable { case anonymize, deanonymize }

public enum OperatorValue: Sendable, Codable, Hashable {
    case string(String), int(Int), double(Double), bool(Bool), bytes([UInt8])
}
public typealias OperatorParams = [String: OperatorValue]

public protocol AnonymizerOperator: Sendable {
    static var operatorName: String { get }
    static var kind: OperatorKind { get }
    func validate(_ params: OperatorParams) throws
    func operate(text: String, params: OperatorParams) throws -> String
}

public struct OperatorConfig: Sendable {
    public var operatorName: String
    public var params: OperatorParams
}

public struct OperatorResult: Sendable, Codable, Hashable {
    public var start: Int, end: Int          // offsets in the ANONYMIZED text
    public var entityType: String
    public var text: String
    public var `operator`: String
}

public struct AnonymizerEngine: Sendable {
    private let operators: [String: any AnonymizerOperator]

    public static func standard(crypto: any AESProvider) -> AnonymizerEngine {
        AnonymizerEngine(operators: [
            "replace": ReplaceOperator(), "redact": RedactOperator(),
            "mask": MaskOperator(),       "hash":   HashOperator(),
            "keep": KeepOperator(),       "custom": CustomOperator(),
            "encrypt": EncryptOperator(crypto: crypto),
            "decrypt": DecryptOperator(crypto: crypto),
        ])
    }

    /// Applies operators in DESCENDING start order so earlier offsets stay valid,
    /// mirroring TextReplaceBuilder, and reports offsets in the OUTPUT text.
    public func anonymize(text: String,
                          results: [RecognizerResult],
                          config: [String: OperatorConfig]) throws -> (text: String, items: [OperatorResult]) {
        let doc = TextDocument(text)
        let ordered = results.sorted { $0.start > $1.start }
        var scalars = doc.scalars
        var items: [OperatorResult] = []

        for r in ordered {
            let cfg = config[r.entityType] ?? config["DEFAULT"]
                    ?? OperatorConfig(operatorName: "replace", params: [:])
            guard let op = operators[cfg.operatorName] else {
                throw PresidioError.unknownOperator(cfg.operatorName)
            }
            try op.validate(cfg.params)
            let replacement = try op.operate(text: doc.slice(r.start ..< r.end), params: cfg.params)
            scalars.replaceSubrange(r.start ..< r.end, with: Array(replacement.unicodeScalars))
            items.append(OperatorResult(start: r.start, end: r.start + replacement.unicodeScalars.count,
                                        entityType: r.entityType, text: replacement,
                                        operator: cfg.operatorName))
        }
        // Later (higher-offset) entities were replaced first, so their recorded offsets
        // are already correct; earlier ones shift only entities after them, which are done.
        return (String(String.UnicodeScalarView(scalars)), items.reversed())
    }
}

/// AES-128/192/256-CBC + PKCS#7, random 16-byte IV prefixed to the ciphertext,
/// urlsafe-base64 (aes_cipher.py). Backed by CryptoSwift (T0) or swift-crypto (T2).
/// Byte-reproducible ENCRYPT is impossible by design; the conformance goal is
/// round-trip interop with Python.
public protocol AESProvider: Sendable {
    func encryptCBC(key: [UInt8], iv: [UInt8], plaintext: [UInt8]) throws -> [UInt8]
    func decryptCBC(key: [UInt8], iv: [UInt8], ciphertext: [UInt8]) throws -> [UInt8]
    func randomBytes(_ count: Int) -> [UInt8]
}
```

### 5.10 Sendable / concurrency choices, and why

| Decision | Rationale |
|---|---|
| Every protocol refines `Sendable`; `any EntityRecognizer` therefore crosses task boundaries freely | Enables `TaskGroup` chunking with no `@unchecked` anywhere in user‑facing code |
| Recognizers are immutable, built eagerly at registry construction | Removes Python's mutable `is_loaded`/`load()` entirely. The only expensive artefact is the NER model, which lives in `NLPEngine`. |
| `AnalyzerEngine` is a `struct`, not an `actor` | Analysis is a pure function of immutable state. An actor would serialise it for nothing. |
| `PCRE2Pattern` is `final class` + `@unchecked Sendable` | PCRE2's compiled code is read‑only during matching; per‑call `pcre2_match_data` upholds the invariant. This is the **only** `@unchecked` in the design and it is documented at the declaration. |
| Never store `NSTextCheckingResult` | Its `Sendable` conformance is explicitly *unavailable* (`@_nonSendable(_assumed)`). If an ICU fallback ever exists, convert to `PatternMatch` immediately. |
| Never store `Regex<AnyRegexOutput>` | Not `Sendable` — hard compile error under `-swift-version 6`. |
| Parallelise over **chunks**, not patterns | Measured: pattern‑parallel ceiling is 2.30× on 14 cores; one pattern is 38.8% of runtime. |
| `-strict-concurrency=complete` from commit one | Verified achievable: a shared `NSRegularExpression` captured in `TaskGroup` child tasks compiles with zero errors under Swift 6 mode. The same holds for the value‑type backends. |

---

## 6. Conformance Strategy

Given no Apple frameworks, conformance is against **Python Presidio**, not against any Apple behaviour. Three oracles.

### 6.1 Fixture corpora

| Corpus | Contents | Size | Purpose |
|---|---|---|---|
| `corpus_clean` | Every unique 2–400‑char string literal AST‑extracted from Presidio's 140 test files, plus `tests/data` | 3,856 literals, **117,610 scalars** | Regex + full‑engine parity. Python reference: 7,591 spans |
| `d_{NONE,SHY,ZWSP,BOM,LRM,WJ,COMB}` | 2,582 distinct PII tokens as `record N value <C>TOKEN<C> end`, one invisible char each side | 7 variants | The `\b` trap. Reference: 13,471 clean / 13,421 invisible / 4,211 combining |
| `corpus_throughput` | Mixed real text | **759,142 scalars** | Perf regression gate. Reference: 1,698 matches, digest `f1b1e60b48e31c3c` |
| `corpus_ner` | 2,000 sentences from Presidio `.md`/`.py` | **47,511 tokens** | NER parity. Reference: 2,592 (`sm`) / 2,324 (`lg`) entities |
| `corpus_tok` | *Pride & Prejudice* + *Moby‑Dick*, LF‑normalised | 1,986,446 scalars / **451,231 tokens** | Tokenizer text + offset parity |
| `corpus_tok_pii` | Synthetic adversarial: phone/email/URL/IPv4/IPv6/IBAN/card/SSN, emoji incl. ZWJ flags, U+200B, U+0301, CJK, Windows paths | 255,949 scalars / **61,357 tokens** | Tokenizer edge cases |
| `vectors_checksum` | Per‑validator KAT sets (Luhn ×7, Verhoeff ×2, mod‑97/23/11/10, base58, bech32/bech32m) | — | 55 validators |
| `vectors_aes` | Fixed key/IV/plaintext triples + Python‑produced ciphertexts | — | Crypto interop |

### 6.2 The differential harness

A pinned Python side‑car (`presidio-analyzer`/`presidio-anonymizer` @ `2bb88d2`, `regex` 2.5.148, spaCy 3.7.5 + `en_core_web_sm` 3.7.1) emits JSONL golden files, checked into a separate `presidio-fixtures` repo with a manifest hash. **The Python side‑car never runs in CI** — only its output does. Regenerating fixtures is an explicit, reviewed operation.

Per record:

```jsonc
{ "id": "clean/0412", "text": "...", "language": "en",
  "artifacts": { "tokens": [...], "tokenIndices": [...], "lemmas": [...],
                 "keywords": [...], "entities": [...], "scores": [...] },
  "perPattern": { "UsSsnRecognizer#SSN (medium)": [[12,23], ...] },
  "raw":   [ {"entityType":"US_SSN","start":12,"end":23,"score":0.5}, ... ],
  "final": [ ... ],
  "anonymized": { "config": {...}, "text": "...", "items": [...] } }
```

Comparison rules:

- Results compare as a **multiset** of `(entityType, start, end, round(score, 9))`. Python's list order is only tie‑ambiguous, but a multiset comparison removes the question entirely. A separate assertion checks the total order under `presidioOrder`.
- Scores compare **exactly**: they originate as JSON literals and are only multiplied by the context‑enhancement factor. No epsilon.
- NER compares **entity spans and labels**, never activations. Float accumulation order differs from BLAS (measured 2.6e‑06–3.0e‑06 max abs diff on the numpy path, **zero** entity divergences over 47,511 tokens), so an argmax tie could in principle flip a label. A differential fuzzer is the mitigation.
- Encryption compares **round‑trip only** (random IV). Decryption of Python‑produced ciphertext compares byte‑exact.
- The regex layer runs **three ways** on every job — PCRE2, pure‑Swift, and golden — and requires three‑way agreement.

### 6.3 CI matrix

| Job | Toolchain | Regex backends | NER | Server | Status today |
|---|---|---|---|---|---|
| macOS arm64 | Xcode 6.2.x | PCRE2 + pure | yes | yes | **All prototypes verified here** |
| Linux x86_64 glibc (ubuntu‑24.04) | swift.org 6.2.x | PCRE2 + pure | yes | yes | **UNVERIFIED — must be job #1** |
| Linux aarch64 glibc | swift.org 6.2.x | PCRE2 + pure | yes | yes | **UNVERIFIED** |
| Linux x86_64 musl static | static SDK | PCRE2 + pure | yes | yes | Cross‑**compiles and links** to static ELF; never executed |
| Linux aarch64 musl static | static SDK | PCRE2 + pure | yes | yes | Same |
| Windows x86_64 | swift.org 6.2.x | PCRE2 + pure | yes | yes | **UNVERIFIED, zero evidence** |
| wasm32‑wasip1 | wasm SDK | pure only (PCRE2 to be proven) | yes (mmap → read) | **no** | Foundation + `NSRegularExpression` + CryptoSwift **executed** under `node:wasi` |
| Android aarch64 | Swift 6.3 Android SDK | PCRE2 + pure | yes | yes | **UNVERIFIED**; official SDK only shipped with 6.3 |
| Strict‑(A) build (any host) | `--traits StrictPure` | pure only | yes | **no** | Design |

Additional gates on every job: `-strict-concurrency=complete` clean; the `PatternLint` plugin; a throughput regression gate on `corpus_throughput` (fail at >15% regression); binary‑size gate.

**The x86‑64 codegen trap must be a CI assertion, not a comment.** `SIMD16.addProduct` lowers to **64 `callq fmaf@PLT`** per inner loop on the default baseline x86‑64 target. Either build with `-Xswiftc -Xllvm -Xswiftc -mcpu=haswell` (verified: 8 `vfmadd`, 110 `%ymm`) and accept an AVX2 baseline, or write `acc = acc + SIMD16(repeating: a) * b` (verified: 16 `mulps` + 16 `addps` on SSE2) and accept **−44% on arm64** (38.6 vs 68.6 GFLOP/s). Assert on the emitted assembly in CI; there is no function multiversioning in Swift.

---

## 7. Phased Roadmap

Test effort is broken out separately because upstream carries a heavy test burden: measured over `presidio-analyzer` + `presidio-anonymizer`, **18,221 prod SLOC vs 21,130 test SLOC = 1.16:1** (non‑blank, non‑comment; 1.22:1 on raw lines). Budget for it.

| # | Milestone | Impl | Test | Total | **What genuinely ships** |
|---|---|---|---|---|---|
| **M0** | Scaffolding + conformance harness | 1.5 | 1.5 | **3.0** | SwiftPM graph with traits; `TextDocument`, `RecognizerResult`, protocols; Python fixture exporter; JSONL harness; CI matrix green on macOS + **Linux**. *Nothing user‑facing; this is the de‑risking milestone and Linux must be proven here.* |
| **M1** | Regex substrate | 1.5 | 1.0 | **2.5** | `CPCRE2` + `PresidioRegexPCRE2` + `RegexBackend`; byte↔scalar offsets; `MATCH_LIMIT`; `PatternLint`. **Ships:** a Swift library that runs all 155 Presidio patterns with proven parity. |
| **M2** | Pattern recognizers + validators + registry | 3.5 | 3.5 | **7.0** | 99 recognizer JSON specs, 155 + 76 + 6 patterns, 55 checksum validators, `RecognizerFactory`, `RecognizerRegistry`, codegen plugin. **Ships:** all 87 non‑NER entity types detectable. |
| **M3** | Analyzer engine | 1.5 | 1.5 | **3.0** | `AnalyzerEngine`, score thresholds, allow‑list (exact + regex), dedupe, `LemmaContextAwareEnhancer` (whole‑word default), chunker. **Ships:** *a working analyzer with the zero‑model configuration — 92.6% of entity types, no model, no download.* This is the first genuinely useful release. |
| **M4** | Anonymizer | 1.5 | 1.5 | **3.0** | 11 operators, AES‑CBC via `AESProvider`, batch + deanonymize engines. **Ships:** full analyze→anonymize round trip, Python‑interoperable decryption. |
| **M5** | Tokenizer + NLP support | 2.0 | 2.0 | **4.0** | Productionise the verified tokenizer + `PureMatcher`; hand‑code `url_match`; stopwords; stemmer; `SlimNLPEngine`. **Ships:** real lemma/keyword context enhancement, so regex confidence scores match Python. |
| **M6** | NER engine + model packaging | 2.5 | 2.0 | **4.5** | Productionise the 618‑LOC engine; `swift-presidio-models-en`; `SpacyNLPEngine`; NER↔tokenizer integration; SIMD tuning + x86 codegen gate. **Ships:** **PERSON / LOCATION / ORGANIZATION / NRP at spaCy parity — full functional parity with Python Presidio for English.** |
| **M7** | Non‑regex recognizers | 2.5 | 1.5 | **4.0** | `PresidioPhone` (libphonenumber subset, 8 regions, leniency VALID), Public Suffix List for email, IP parsing, `PresidioGazetteer`. **Ships:** the last recognizers that are not pure patterns. |
| **M8** | Server, CLI, distribution | 2.0 | 1.0 | **3.0** | Hummingbird REST parity, CLI, artifact bundles, Docker images, docs. **Ships:** drop‑in replacement for the `presidio-analyzer`/`presidio-anonymizer` containers. |
| **M9** | Hardening | 2.0 | 1.0 | **3.0** | Differential fuzzing (regex + NER), perf work, `MATCH_LIMIT` tuning, memory profiling, security review of AES paths. **Ships:** 1.0. |
| | **Total (reading B)** | **20.5** | **16.5** | **37.0** | |
| **A+** | Strict‑(A) premium | | | **+8.8** | Pure‑Swift regex to production (+6.5), Foundation‑free core (+2.0), YAML→JSON (+0.3). **Loses the REST server.** |

Sequencing note: **M3 is the first shippable release** and it needs no model at all. Ship it, then add NER as an optional module. That also avoids bundling a model in the base package.

---

## 8. Effort Summary

| Configuration | Person‑weeks | Calendar (1 engineer) | Calendar (2 engineers) |
|---|---|---|---|
| **Reading (B), English only, PCRE2 + spaCy NER + REST** | **37** (range 33–42) | ~9 months | ~4.5 months |
| **Reading (A) strict**, same scope minus REST | **45.8** (range 40–52) | ~11 months | ~5.5 months |
| **Reading (B), zero‑model only** (M0–M4, M7, M8) | **25.5** | ~6 months | ~3 months |

**Assumptions, stated:**

1. One experienced Swift engineer, 5‑day weeks, no meetings tax. Scale accordingly.
2. **English only.** Each additional language costs ~1 pw for tokenizer rules + differential runs, plus whatever the model licence permits (Italian and Spanish are legally blocked for commercial use — §4.2).
3. Upstream Presidio does not churn during the port. It is actively developed; budget maintenance separately.
4. The three prototypes (486‑LOC regex, 618‑LOC NER, 432‑LOC tokenizer) are usable as starting points, not rewritten. They are, respectively, a 3‑hour prototype, a working engine with exact parity, and a verified port.
5. Test effort assumed at ~0.8:1 against Swift impl LOC, versus upstream's 1.16:1 against Python, on the grounds that generated recognizer specs and the golden‑fixture harness carry a lot of the test weight without hand‑written test code.
6. Estimates from the sub‑agents (PCRE2 1.5, pure regex 8, NER 2, tokenizer 3, gazetteer 2, ORT 4) are **implementation only** and are folded into the Impl column above.
7. **Linux CI works in M0.** If it does not — see §11 — every number here is provisional.

**Strict‑(A) premium: +8.8 pw and the REST API server.** That is the honest price. It is small because the two most expensive strict components (NER, tokenizer) are *already* pure Swift with no compromise.

---

## 9. What NOT to Port

| Item | Why not |
|---|---|
| **`presidio-image-redactor`** (3,200 prod / 4,551 test LOC) | Needs Tesseract OCR + PIL/DICOM. No pure‑Swift path; the OCR dependency alone dwarfs the rest of the project. Out of scope. |
| **`presidio-structured`** (841 LOC) | Built on pandas DataFrames. Port later against a Swift tabular type, or expose the analyzer and let callers drive it. |
| **POS tags / dependency parse / `tagger` / `parser` / `attribute_ruler`** | Consumed **nowhere** in `presidio-analyzer` — grep‑confirmed zero non‑adapter hits for `.pos_`, `.tag_`, `.dep_`, `noun_chunks`. |
| **Sentence splitting** | `NlpArtifacts` has no sentence field. The only `.sents` hits are 6 lines in `stanza_nlp_engine.py:423–443` that *set* `is_sent_start` and never read it. Build the 120‑LOC `CharacterBasedTextChunker` (size 250, overlap 50, extend to next `" "`/`"\n"`) instead. |
| **spaCy's rule lemmatizer (exact parity)** | Requires a POS tagger you otherwise do not need. Measured worth: ~5 real matches per 333k tokens, against 3,322 spurious matches it *creates* via substring context. Ship a 10‑rule stemmer + WordNet index (342 KB gz). See §4.3. |
| **Transformers / GLiNER / Stanza / LangExtract / LLM recognizers** | Each drags in a runtime (ORT/PyTorch) or a network dependency. GLiNER additionally needs DeBERTa‑v3 disentangled attention and a 250k‑vocab SentencePiece Unigram tokenizer. Offer ONNX as an optional module (§4.1 #2) if a customer asks. |
| **Azure AI Language recognizer, AHDS surrogate operator** | Cloud‑service clients. Trivial to re‑add as a `RemoteRecognizer` over `URLSession`/Hummingbird client; not core. |
| **`app_tracer` / decision‑process logging as a global** | Reimplement as a structured `Diagnostics` facility. Do not port the mutable global. |
| **Python's reflection‑based recognizer loading** (`recognizers_loader_utils.py`, 833 LOC) | Replaced by the JSON specs + generated factory table (§5.7). This is a straight simplification. |
| **`is_loaded` / lazy `load()`** | Eliminated by construction‑time loading. Removes all mutable recognizer state. |
| **Full `phonenumbers`** | Port only what `PhoneRecognizer` uses: `PhoneNumberMatcher` at `leniency=1` (VALID) over `DEFAULT_SUPPORTED_REGIONS = ("US","GB","DE","FR","IL","IN","CA","BR")`. Full libphonenumber is ~250 regions of metadata. Evaluate `PhoneNumberKit` (MIT, pure Swift) first, but note it depends on Foundation/`NSRegularExpression` and its matcher semantics differ from libphonenumber's. **This is the single largest un‑researched item in the plan.** |
| **Full `tldextract`** | Only `result.fqdn != ""` is used. Ship the Mozilla Public Suffix List (MPL‑2.0) as a static table plus ~50 LOC. |
| **Swift Regex, `NSRegularExpression`, `NSDataDetector`, RE2, Hyperscan/Vectorscan, Oniguruma** | §1 and §3. RE2 and Hyperscan are *structurally* impossible: 33/155 patterns (21.3%) use lookaround or backreferences, which neither supports by design. Oniguruma is 154/155 with 74 false positives on pattern #97 and has no SwiftPM packaging. |
| **`swift-numerics`, MLX, MLTensor, Swift for TensorFlow** | No value, banned, banned, and archived since 2022 respectively. |
| **Byte‑reproducible encryption** | `aes_cipher.py` prefixes a random 16‑byte IV. Round‑trip interop is the achievable goal; byte‑reproducible encrypt is not. |

---

## 10. Risks

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| R1 | **Nothing was executed on Linux by any sub‑agent** (Docker never started, 4/4 agents). A runtime surprise in corelibs‑Foundation, ICU data loading, or `Bundle.module` invalidates schedule assumptions. | Medium | High | **Make a real Linux CI job the very first deliverable of M0**, before any porting. Use GitHub Actions `swift:6.2` containers, not local Docker. The chosen stack (PCRE2 + pure‑Swift NER/tokenizer) touches almost no Foundation, which caps the blast radius. |
| R2 | **Pattern #97** (`\b((?=.*?[a-zA-Z])(?=.*?[0-9]{4})[\w@#$%^?~-]{10})\b`) is a backtracking bomb in every engine: 1.9 s of PCRE2's 4.2 s, 38.8% of the NSRE sweep, 16.5 s under Swift Regex. | **Certain** | Medium | `MATCH_LIMIT` / `MATCH_LIMIT_DEPTH` on PCRE2 and a step budget in the pure engine, both wired to the Python `TimeoutError` log‑and‑skip behaviour. Add a perf gate. Consider a literal prefilter for this pattern specifically. |
| R3 | **PCRE2 on Windows** is unverified. macOS only. | Medium | Medium | Confidence is reasonable (only `.generic` config files, zero source patches, JIT excluded), but put a Windows job in M0/M1 rather than M8. The pure‑Swift backend is the fallback and needs no C at all. |
| R4 | **The pure‑Swift regex engine is a 3‑hour prototype.** No step budget, no memoization, capture‑restore lightly exercised, no full Unicode case folding. The 8 pw estimate could run over. | Medium | Medium (High under strict‑A) | It is not on the critical path under reading (B) — it is the CI oracle. Harden it incrementally. If it slips, reading (A) slips; reading (B) does not. |
| R5 | **`phonenumbers` port is un‑researched.** No sub‑agent looked at it. `PhoneNumberMatcher` at leniency VALID over 8 regions is a real chunk of work. | Medium | Medium | Spike it in M0 (2 days): evaluate `PhoneNumberKit` vs porting libphonenumber's metadata subset. Worst case, ship PHONE_NUMBER as regex‑only initially — it is dual‑sourced, so the entity type does not disappear. |
| R6 | **Upstream Presidio churns.** 99 recognizers, 155 patterns, active development. | High | Low–Medium | Patterns and contexts are extracted from Python as **data**, so a rebase is a regeneration plus a differential run, not a code merge. Keep the extractor and the harness in CI. |
| R7 | **Float accumulation order** in the SIMD GEMM differs from BLAS; an argmax tie could flip a NER label. | Low | Medium | Measured: 3e‑06 max abs diff, **zero** entity divergences over 47,511 tokens. Mitigate with a differential fuzzer against Python spaCy in M9. |
| R8 | **Swift stdlib Unicode drift.** `String.lowercased()`, `Character.isLetter/isUppercase/isNumber` are used for NORM and SHAPE. Cross‑platform/cross‑version determinism was never verified. | Low | Medium | If it drifts, vendor ~50 KB of Unicode tables for exactly the four predicates Python uses. The regex tables are already vendored, so the pattern is established. |
| R9 | **Model licensing challenged.** The MIT relicensing of OntoNotes‑derived weights is an engineering reading, not a legal opinion. | Low | High | Get counsel to review the shipped `LICENSE` + `LICENSES_SOURCES` + HuggingFace metadata before M6. Fallback: ship the zero‑model configuration (92.6% of entity types) and let customers supply their own model. |
| R10 | **Multi‑language licensing.** `it` is CC BY‑NC‑SA 3.0 (non‑commercial); `es` is GPL‑3.0; `fr` is LGPL‑LR; `nl`/`pt` are CC BY‑SA 4.0. | High **if** multi‑language is in scope | High | Ship English (MIT) plus `de`/`zh`/`ru`/`xx_ent_wiki` (MIT) only. Treat the rest as blocked pending legal. |
| R11 | **PCRE2 CVE exposure.** Vendoring 30 C files means you own the tracking. | Medium | Medium | Pin the version, subscribe to announcements, quarterly bump task, keep the pure‑Swift backend as a switchable escape hatch. |
| R12 | **CryptoSwift is not constant‑time** (table‑based AES). | Low for Presidio's threat model | Medium in a hosted multi‑tenant service | Default to `swift-crypto`/BoringSSL under reading (B). Document the strict‑(A) tradeoff explicitly. Never claim side‑channel resistance for the strict build. |
| R13 | **Binary size.** Anything touching `NSRegularExpression` is 52 MB static musl minimum (`lib_FoundationICU.a` is 79 MB in the SDK). | Certain if Foundation is used broadly | Medium | The recommended stack avoids `NSRegularExpression`; keep `PresidioCore`/`PresidioNER`/`PresidioTokenizer` Foundation‑free so a 6–10 MB embedded build stays possible. Add a size gate. |
| R14 | **Android is unverified** and the official Swift Android SDK only landed with Swift 6.3. | Medium | Low–Medium | Defer Android to post‑1.0. Nothing in the design is Android‑hostile (no JIT, no codegen, no Foundation in the hot path). |
| R15 | **Package traits (SE‑0450) never exercised** by any sub‑agent. The (A)/(B) switch depends on them. | Low | Low | Validate the manifest on day one of M0. Fallback: two packages sharing source directories, or a compile‑time flag. |

---

## 11. Where the Evidence Is Thin, and Where Sub‑Agents Disagreed

### 11.1 The big one: no Linux execution, anywhere

**All four sub‑agents failed to start Docker**, independently, with different symptoms:

- `open -a Docker` + 5‑minute poll → down; `docker desktop start` → `Failed to start Docker Desktop: context canceled`.
- `com.docker.backend` spawns then exits; `~/.docker/run/docker.sock` never appears.
- VM logs show boot then `control: gracefully shutting down` and `virtio-net.eth0: DHCPv4 failure`; host log repeats `com.docker.backend returning error: unmarshaling start request: unexpected EOF`.
- No colima, podman or lima on the machine. Cumulative retry time across agents: ~30 minutes.

**Consequently: every Linux, Windows and Android claim in this document is source inspection, cross‑compilation, or documentation — never execution.**

What *was* achieved as a substitute:

- **Cross‑compilation and static linking verified** to `x86_64-swift-linux-musl` and `aarch64-swift-linux-musl` ELF binaries for the NER engine, the GEMM kernel, and a full Foundation + swift‑crypto + Yams + Hummingbird package (`Build complete! (143.00 s)`).
- **WASM execution is a genuine non‑Darwin proof point.** The full 155‑pattern sweep, 14 ICU edge cases, `JSONDecoder`, `URL`, `Bundle.module`, SHA‑256 and CryptoSwift AES all **ran** under `node:wasi` on corelibs‑foundation + vendored `swift-foundation-icu`, producing byte‑identical results to macOS. That is stronger evidence than cross‑compilation, but it is not Linux.
- Note one toolchain gotcha discovered the hard way: **Xcode's Swift toolchain cannot use Swift SDKs** (`compiled module was created by a different version of the compiler ''`). You need the swift.org open‑source toolchain, and the Xcode toolchain also lacks `swift-autolink-extract` for Linux links.

### 11.2 Sub‑agent disagreements, and how each is resolved

| # | Disagreement | Resolution |
|---|---|---|
| **D1** | **Is `NSRegularExpression` viable?** The infra agent recommends it as the reading‑(B) engine (having *proven* cross‑platform behavioural identity). The regex agent bans it (Darwin = closed framework; 68% FN without the `\b` rewrite; absent from `swift-foundation`). | **Regex agent wins, on merit rather than purity.** Even granting the infra agent's Foundation ruling (which this document adopts), PCRE2 needs **zero** pattern rewriting, is 15% faster, and has match limits. Use Foundation; do not use it for matching. |
| **D2** | **Are lemmas needed?** NER agent: yes, port tagger + attribute_ruler + rule lemmatizer (+2–3 pw + WordNet obligation). NLP agent: measured them at 1.03% verdict change and net‑negative for precision. | **NLP agent wins — it measured, the other estimated.** Ship the stemmer. Saves 2–3 pw and the WordNet attribution. |
| **D3** | **Swift Regex slowdown.** Prior analysis: ~30×. Regex agent: **11.5×** (or 10.3× including pattern #97). | Regex agent's figure supersedes; both were on the same machine, the newer one with a shared 136‑pattern subset. Moot anyway — Swift Regex is rejected on correctness. |
| **D4** | **`\b`‑rewrite cost.** Prior analysis: ~22%. Regex agent: **+55%** measured (7.71 s vs 4.99 s). | Measured figure wins. Also moot under the recommendation, since neither shipping backend needs the rewrite. |
| **D5** | **ICU skew.** Regex agent flagged it as a live, unbounded risk. Infra agent retired it empirically (identical digest on macOS vs WASI). | **Infra agent wins for the axis it tested** (Darwin closed Foundation vs corelibs + vendored ICU). Residual: **glibc Linux distros that link system ICU** were never tested. Irrelevant under the recommendation, since neither backend touches ICU. |
| **D6** | **Is strict (A) achievable at all?** NER/NLP agents demonstrated Foundation‑free code. Infra agent argued (A) is unattainable because Foundation itself is C. | Both are right about different scopes. Resolved by the **four‑tier model** in §2.1: T0 is achievable for core, regex, tokenizer, NER and gazetteer; T1 is where JSON/file‑I/O live; the HTTP server is T2‑only, full stop. |
| **D7** | **spaCy version skew across agents.** The NER port was verified against **spaCy 3.7.5 / models 3.7.1**; the tokenizer port against **spaCy 3.8.14** `spacy.blank("en")`. | **Unresolved and must be resolved in M5/M6.** Pin one spaCy version and one model version, then re‑run *both* differential harnesses against it. The shipped model config pins `spacy_version ">=3.7.2,<3.8.0"`, so 3.7.x is the likely target — which means the tokenizer parity result needs re‑verification. |

### 11.3 Explicitly UNVERIFIED claims

**Platform:**
- Linux runtime behaviour of *anything*. Cross‑compilation only.
- Windows: **zero evidence.** No host, no build, no run, for any component.
- Android: SDK version‑mismatched (`readdle-swift-6.2.1` vs a 6.2.4 compiler); never built to completion. The official Swift Android SDK shipped with 6.3.
- PCRE2 via SwiftPM on Linux, Windows, Android or WASM. macOS arm64 only.
- WASM: the NER engine would need an `mmap` alternative for `lg` vectors; `Bundle.module` on WASI resolved via node's host‑root preopen, so browser/virtual‑FS behaviour is unknown.

**Regex:**
- Oniguruma was built with autotools, never packaged for SwiftPM.
- RE2 and Hyperscan/Vectorscan were **never built** — ruled out purely on the measured 33/155 expressiveness count.
- SE‑0448 (lookbehind) shipping version: confirmed Accepted, no release named.
- The Swift 6.2.4 `.unicodeScalar` + `.simple` bug was reproduced reliably but never checked against 6.3/main, and no existing bug report was searched for.
- `swift-foundation-icu` pins ICU 74: read from a README matrix via WebFetch, not from a lockfile. The exact ICU in the Swift 6.2 Linux toolchain is unverified.

**NER / ML:**
- Tokenizer↔NER integration parity: **never measured together.** The NER port was fed spaCy‑produced tokens and NORMs specifically to isolate the model. The tokenizer was verified against `spacy.blank("en")`, i.e. without the model's NORM exceptions. Joining them is real, unvalidated work.
- Cross‑platform determinism of `String.lowercased()`, `Character.isLetter/isUppercase/isNumber` — used for NORM and SHAPE. Never compared across platforms.
- The legal conclusion on MIT relicensing of OntoNotes‑derived weights: engineering reading, not counsel.
- `md`/`lg` licences for non‑English languages: read from `_sm` wheels' `meta.json` only.
- Multi‑threaded Swift NER throughput: all numbers single‑threaded.
- llama.cpp/ggml: never built or benchmarked. All claims from reading `include/llama.h` and PR #5423.
- int8 NER accuracy impact: size and latency measured, **accuracy never evaluated**.
- Pure‑Swift BERT at ~250 tok/s: extrapolated from the 52–58 GFLOP/s ceiling, never run.
- That the 9× pure‑Swift‑vs‑ORT gap narrows on Linux x86‑64: plausible (ORT's Apple advantage is AMX/SME), entirely unmeasured.

**Tokenizer / NLP:**
- The pure‑Swift affix matcher is verified for **English only**. French elision (a 372 KB exception list) and Dutch's 4,651 exceptions are untested.
- The naive‑stemmer figures (91.8% / 99.27%) were measured on literary + synthetic text, not enterprise text (logs, forms, medical notes). The *direction* of the conclusion is corpus‑independent because it follows from the structure of the context lists.
- Aho‑Corasick throughput on non‑Apple memory hierarchies. The 631 MB automaton figure is memory‑latency‑bound and will differ materially.

**Infrastructure:**
- ThreadSanitizer **could not run** (`swiftc -sanitize=thread` SIGSEGVs on hello‑world on this macOS 26 arm64 host). "No data race" is unproven; only "no observable incorrect result over 20,480 concurrent operations".
- `swift-crypto`'s 31–33 MB/s AES‑CBC is far below AES‑NI/ARMv8 hardware rates despite `aesv8-armv8-apple.S` being present (56 hardware‑AES symbols in the binary). Never root‑caused.
- Hummingbird/Vapor: only *linked*, never started; no request was served on any platform.
- Package traits (SE‑0450) never exercised.
- All person‑week estimates are judgement, not measurement — including the ones in this document.

### 11.4 The single most important next action

**Get a Linux CI job running and re‑execute the three harnesses on it before writing production code.** Specifically: the 155‑pattern regex sweep (expect digest `f1b1e60b48e31c3c` and 1,698 matches on the 759 KB corpus), the NER parity run (expect 2592/2592 on `en_core_web_sm`), and the tokenizer diff (expect 0 lines). Every schedule number in §7 and §8 is conditional on those three passing unchanged.