# Reimplementing Presidio in Swift — Design and Feasibility Verdict

**Date:** 2026-07-31
**Scope:** microsoft/presidio (now `data-privacy-stack/presidio`), MIT, ~27,000 LOC production Python across 5 packages + ~34,600 LOC of tests.
**Audience:** implementing engineer. Numbers are aggregated from source-level subsystem analyses and empirical Swift/ICU benchmarking, not estimated from documentation.

---

## 0. TL;DR

**Yes, and it is worth doing — but only if you scope it as "Presidio-compatible," not "Presidio-identical," and you decide up front which of the three lossy boundaries you accept.**

The deterministic ~80% of Presidio (regex recognizers, national checksums, span algebra, conflict resolution, scoring, the entire anonymizer) ports at essentially full fidelity, and in several respects lands *better* in Swift than in Python. The single most feared risk — "we'll have to hand-rewrite ~240 regexes" — **does not exist**: all 155 literal Presidio patterns compile unmodified under `NSRegularExpression` and were verified to produce byte-identical match sets to Python `re` over a 759 KB corpus (1,563 matches, 155/155 patterns agreeing, zero disagreements), at ~1.2× Python's speed serially.

The lossy ~20% is entirely the NLP layer (spaCy), and it is unavoidably lossy on-device today. Everything else that looks hard (crypto byte-compat, YAML-driven dynamic class instantiation, HTTP, config) is solved infrastructure.

**Three things to decide before writing a line of code:**

1. **Offset representation.** Python offsets are Unicode *scalar* indices; `NSRegularExpression` returns UTF-16; Swift `String` is grapheme-indexed. These offsets are the wire contract with the anonymizer and with any downstream consumer. Pick scalar offsets, build the conversion layer once, and property-test it. Getting this wrong is a silent PII-leak class of bug.
2. **NER backend policy.** `NLTagger` gives you 3 entity types in 8 languages with a catastrophic lowercase-input failure mode. A CoreML transformer closes the gap but costs 110–215 MB and requires you to hand-write subword→character offset alignment (`swift-transformers` has **no** offset-mapping API — grep-confirmed).
3. **Ordering determinism.** Python's result and recognizer ordering is derived from `set` iteration and is nondeterministic across processes. A correct Swift port will *legitimately differ* on ties. Bit-exact golden-file parity is impossible without normalizing tie-breaks on both sides.

---

## 1. Verdict by tier

### Tier 1 — 1:1 portable (identical behavior achievable, verified)

| Subsystem | Evidence |
|---|---|
| **Regex corpus** (155 literal + 6 assembled patterns + 76 IBAN country regexes ≈ 237 regexes) | Feature census over all patterns: **0** named groups `(?P<>)`, **0** named backrefs, **0** atomic groups, **0** possessive quantifiers, **0** conditionals, **0** `\p{...}` property escapes, **0** variable-width lookbehinds, **0** `\B`. Riskiest constructs are 19 fixed-width single-char negative lookbehinds, 28 negative lookaheads, 2 numeric backrefs, 12 inline `(?i)`, 3 non-ASCII classes — all ICU-expressible. Empirically: 155/155 compile unmodified, byte-identical output vs Python `re`. |
| **55 checksum validators** | Pure deterministic integer arithmetic: 7 Luhn variants, 2 Verhoeff, mod-97/23/11/10 weighted sums, ~5 date-plausibility checks, base58+bech32/bech32m. `stdnum` is **not** used anywhere — every national checksum is hand-rolled in-repo, so there is no vendored validation library to substitute. Only two need BigInt-style handling (IBAN mod-97 over a ~34-digit decimal, Bitcoin base58 accumulation). |
| **Entire anonymizer** (2,457 LOC, of which 371 is the optional Azure AHDS operator) | Exactly **one** regex in the whole package (`^( )+$`). Zero NLP. Zero Pydantic. One hard third-party dep (`cryptography`, 57 lines of AES-CBC). 8 anonymize + 2 deanonymize operators behind a clean 4-method ABC that maps 1:1 to a Swift protocol. |
| **Span algebra & the three overlap algorithms** | `RecognizerResult.intersects/contains/containedIn/equalIndices/hasConflict` (~40 lines); `EntityRecognizer.remove_duplicates` (~20 lines); the anonymizer's 3-pass conflict resolver; the chunker's >50%-overlap dedup. All pure, all small, all mechanical. |
| **AES encrypt/decrypt byte compatibility** | `swift-crypto` ≥ 4.5.1 `CryptoExtras.AES._CBC` is BoringSSL-backed on **every** platform including Darwin (it does *not* forward to CryptoKit), so bytes are identical to Python `cryptography` on macOS, iOS, and Linux. See §4c. |
| **Scoring, thresholding, allow-lists, context boost arithmetic** | Fixed constants (`+0.35`, floor `0.4`, cap `1.0`, prefix window 5, suffix 0), straight-line list arithmetic. |

### Tier 2 — Needs substitution (near-fidelity, measurable divergence, mitigable)

| Subsystem | Substitution | Divergence |
|---|---|---|
| **spaCy tokenizer + lemmatizer** | `NLTokenizer` + `NLTagger(.lemma)` on Apple (verified dictionary-quality: children→child, were→be, better→good); Snowball stem + vendored stopword lists on Linux | Different tokenization ⇒ different `tokens_indices` ⇒ different 5-word context window ⇒ **different context-boost scores for every regex recognizer**. Bounded but real. |
| **`phonenumbers` (libphonenumber)** | `PhoneNumberKit` 4.3.0 (MIT, 5.4k★, active) | Explicitly *not* a port — reuses Google's metadata, reimplements the logic with a smaller feature set. Needs differential testing. 366 KB metadata bundle. `PhoneNumberType` exists, so the 3 ZA phone classes are portable. |
| **`tldextract`** (email validator) | Vendored Public Suffix List snapshot | `tldextract` downloads the PSL over the network at first use — unacceptable in a sandboxed library. Vendoring means version drift. |
| **Pydantic YAML validation + `__subclasses__()` + `inspect.signature` kwarg reshaping** (833 + 659 LOC) | Explicit `[String: RecognizerFactory]` table + Codable specs | `extra='allow'` pass-through of arbitrary unvalidated keys **cannot** be reproduced. Signature-introspection quirks (plural→singular renaming, silent key drops) will behave differently for exotic YAML. See §3.6. |
| **Tesseract OCR** | Vision `VNRecognizeTextRequest` on Apple; hand-written `libtesseract` C binding on Linux | Vision returns normalized bottom-left per-*line* boxes; Presidio expects pixel top-left per-*word*. Conversion shim required; redaction rectangles will not be pixel-identical. Byte-equality golden test must be dropped. |
| **pandas** (presidio-structured) | `TabularData` on Apple behind your own narrow `TabularSource` protocol; CSV/array backend on Linux | `df.sample(random_state=123)` cannot be reproduced without NumPy's Mersenne Twister ⇒ sampled-column detection will not match row-for-row. In-place `data.at[]` mutation becomes return-a-new-table. |

### Tier 3 — Effectively impossible to match exactly

| Item | Why |
|---|---|
| **spaCy `en_core_web_lg` NER quality** | PERSON/LOCATION/ORGANIZATION/NRP/DATE_TIME all come from a CNN model. NLTagger gives 3 classes, no NRP, no DATE_TIME, and returns **zero entities** on lowercase input where spaCy degrades gracefully. A CoreML BERT (dslim/bert-base-NER ~91 F1 vs en_core_web_lg ~85) *exceeds* spaCy but is a different model with different errors — parity in the sense of "same spans" is not attainable either way. |
| **Result ordering on ties** | Python: `list(set(results))` before a sort whose key `(-score, start, -(end-start))` omits `entity_type`; `RecognizerResult.__hash__` uses `hash(str)` which is `PYTHONHASHSEED`-randomized. Recognizer execution order is also `set`-derived. Ties are nondeterministic *in Python*. |
| **Regex per-match wall-clock timeout** | `regex.finditer(text, timeout=60)` is a `regex`-module-only API. No equivalent in ICU, Swift Regex, RE2, or NSRegularExpression. Only partially mitigable (§4b). |
| **Recognizer identity (`id`)** | `f"{self.name}_{id(self)}"` — a CPython object address. Not serializable, not stable across runs. A Swift port must invent a deterministic scheme; anything referencing the Python IDs is unreproducible by construction. |
| **matplotlib verification overlay** | Rasterizes a matplotlib `Figure` (default fonts, DPI, axes, `boxstyle="round4"`) and resizes it back. Visual parity with Core Graphics is unattainable. It is a debug tool — drop it. |
| **DICOM redaction** | No usable Swift/ObjC DICOM library exists. Best candidate `DcmSwift`: 15★, last push 2022-11-08, Swift 5.3, self-disclaimed as "partial, work in progress" and "not a medical imaging library". Alternatives are 2–6★ weeks-old single-author repos. Only real paths are vendoring DCMTK via C++ interop or writing a Part-10 parser. See §8. |
| **`Custom` operator (arbitrary stateful Python lambda in a JSON config)** | No Swift analogue for "config containing a callable". Already forbidden over HTTP by upstream, so a closure-based Swift API is a faithful substitute for the in-process case. |

---

## 2. Component-by-component portability table

Effort in person-weeks (pw), one experienced Swift engineer. Fidelity: **identical** = byte-for-byte given same input; **near** = same results modulo documented tie-break/offset normalization; **approximate** = different algorithm, measurable quality delta.

| Python component | LOC | What it does | Swift approach | Fidelity | Effort |
|---|---:|---|---|---|---:|
| `recognizer_result.py` span algebra | ~190 | `intersects/contains/containedIn/equalIndices/hasConflict`, `__gt__`, `__hash__` | `struct RecognizerResult: Sendable, Hashable` + `Comparable` with `entityType` added as final tiebreak | near (tie order defined) | 0.3 |
| `pattern.py`, `pattern_recognizer.py` | ~330 | Regex + deny-list detection, compile cache, tri-state validate/invalidate gate | One concrete `struct PatternRecognizer` + `@Sendable` validator closures. Compile eagerly in `init`, store `let` | identical | 1.5 |
| `analysis_explanation.py` | ~70 | Decision-process record | `struct AnalysisExplanation: Sendable, Codable` | identical | 0.2 |
| `entity_recognizer.py` `remove_duplicates` | ~35 | Dedup algorithm #1: same-entity-type containment suppression, drops score==0 | Direct port; input pre-sorted deterministically | near | 0.3 |
| `analyzer_engine.py` `analyze()` | ~120 | 11-step orchestration (order-sensitive: threshold **before** dedup) | `struct AnalyzerEngine: Sendable`, `async throws` | identical | 1.5 |
| `analyzer_engine.py` thresholds | ~60 | 5-level precedence resolution, `>=` comparison | Direct port | identical | 0.4 |
| `analyzer_engine.py` allow lists | ~55 | `exact` (case-sensitive whole-span) vs `regex` (alternation + `search`, not `fullmatch`) | Direct port; timeout branch keeps the result | identical | 0.3 |
| `lemma_context_aware_enhancer.py` | 370 | +0.35 boost, floor 0.4, cap 1.0; 5 *content*-word backward window (stopwords don't decrement the budget) | Direct port over `[Token]` | near (depends on tokenizer/lemmatizer) | 1.5 |
| `recognizer_registry/` (1,509 LOC, 833 in loader) | 1,509 | `__subclasses__()` class lookup + `inspect.signature` kwarg reshaping + language/country expansion | Explicit factory table, Codable specs, per-recognizer accepted-param metadata | approximate (see §3.6) | 3.0 |
| `input_validation/` Pydantic models | 858 | 8-model hierarchy, `CONFIG_MODEL_MAP` dispatch, `extra='allow'` | Discriminated-union `Codable` + explicit cross-field validators | approximate (no `extra=allow`) | 2.0 |
| `chunkers/` | 550 | Char/tokenizer chunking, offset rebasing, dedup algorithm #3 (>50% of shorter span) | Pure offset arithmetic; tokenizer chunker only needed on the transformer path | identical (char) / n/a (tokenizer) | 1.0 |
| `batch_analyzer_engine.py` | ~160 | Lazy generators over lists and recursive dicts, exact-type dispatch | `indirect enum AnalyzableValue` + `AsyncStream` | near | 0.8 |
| **85 pattern/checksum recognizers** (`generic/` 10, `country_specific/` 75) | 9,001 | 161 `Pattern()` + 602 context words + 55 validators across 18 countries | Data-driven: `Resources/recognizers/*.json` + one `PatternRecognizer` type + 55 validator functions | identical | 9.0 |
| `generic/iban_recognizer.py` | 141 + 76 regexes | Only `PatternRecognizer` overriding `analyze()`; reverse capture-group walk; mod-97 over 34 digits | Custom `analyze`; chunked modular arithmetic (no BigInt needed) | identical | 0.8 |
| `generic/phone_recognizer.py` + 3 ZA classes | ~200 | libphonenumber matcher, region loop, `PhoneNumberType` filtering | `PhoneNumberKit` | near | 0.8 |
| `generic/email_recognizer.py` validator | ~60 | `tldextract.extract().fqdn != ""` | Vendored PSL snapshot | near | 0.4 |
| `nlp_engine/` (5 engines) | 1,913 | spaCy/stanza/transformers/slim/no-op → `NlpArtifacts` | `protocol NLPEngine` + `NoOpNLPEngine` + `AppleNLPEngine` | approximate | 2.5 |
| `nlp_engine_recognizers/` (3 classes) | 206 | Repackage `NlpArtifacts.entities` → `RecognizerResult` | Trivial; ~60 Swift LOC | identical (given artifacts) | 0.3 |
| `ner/` (GLiNER, HF, Medical) | 777 | Direct model inference + chunking + label remap | CoreML / ONNX backend; **rewrite, not port** | approximate | 6.0 |
| `NerModelConfiguration` + label mapping | 128 + 9 YAMLs | Ignore-list → mapping → ignore again → 0.4 low-score multiplier | Codable struct + table | identical | 0.5 |
| `anonymizer_engine.py` conflict resolution | ~85 | Dedup algorithm #2: 3-pass (same-type union merge → `has_conflict` drop → optional `REMOVE_INTERSECTIONS` O(n² log n) fixpoint) | Index-based mutation (Python mutates shared refs via `list.remove` on `__eq__`) | identical | 1.0 |
| `core/engine_base.py` + `text_replace_builder.py` | ~140 | Back-to-front rewrite, `lastReplacementIndex` clipping, from-the-end index anchors normalized at the end | Direct port | identical | 0.8 |
| 10 operators + `aes_cipher.py` | ~400 | replace/redact/mask/hash/encrypt/decrypt/keep/custom | `protocol Operator` + concrete types; `AES._CBC` | identical | 1.5 |
| `deanonymize_engine.py` | ~60 | Mirror of `_operate`; **no** DEFAULT injection, **no** sorting pre-pass | Direct port; document the `AttributeError`→typed-error change | near | 0.3 |
| `batch_anonymizer_engine.py` / `batch_deanonymize_engine.py` | ~180 | Recursive dict/list walk | `indirect enum` | near | 0.5 |
| 3 Flask apps (9 routes) | 398 | REST | Hummingbird 2.x + `swift-openapi-generator` against upstream's 785-line OpenAPI spec | identical | 2.0 |
| `presidio-cli` | 582 | argparse + YAML config + `pathspec` gitignore semantics | `swift-argument-parser` + Yams | near (2 upstream bugs to *not* reproduce) | 1.5 |
| `presidio-structured` | 841 | Per-column entity detection, 3 selection strategies, cell-wise anonymize | `TabularSource` protocol | approximate (RNG) | 2.5 |
| `presidio-image-redactor` non-DICOM | 1,686 | OCR → analyze → span→bbox map → draw rects | Vision + `BboxProcessor` port (190 LOC, zero deps) | approximate | 5.0 |
| `dicom_image_redactor_engine.py` + verify | 1,439 | DICOM PHI harvest by element *display name*, VOI-LUT, RLE recompress | **Do not port** | — | 10.0 (deferred) |
| `third_party/` (Azure, LangExtract) | 969 | Remote recognizers | Optional `URLSession` targets or drop | approximate | 2.0 (optional) |
| `stanza_nlp_engine.py` | 517 | 70% vendored `spacy-stanza` glue | **Do not port** | — | — |

---

## 3. Proposed Swift architecture

### 3.1 SwiftPM target layout

```
PresidioSwift/
├── Sources/
│   ├── PresidioCore/            // value types, offsets, span algebra, errors. No deps.
│   ├── PresidioRegex/           // NSRegularExpression wrapper, Python-flag translation,
│   │                            //   pattern lint, python-compatible escape, deny-list builder
│   ├── PresidioAnalyzer/        // EntityRecognizer, PatternRecognizer, AnalyzerEngine,
│   │                            //   RecognizerRegistry, ContextAwareEnhancer, chunkers
│   ├── PresidioRecognizers/     // 85 pattern/checksum recognizers
│   │   └── Resources/recognizers/*.json     <- single source of truth, regenerable
│   ├── PresidioNLP/             // NLPEngine protocol, NLPArtifacts, label mapping, NoOpNLPEngine
│   ├── PresidioNLPApple/        // NLTokenizer/NLTagger/NLGazetteer + NSDataDetector recognizer
│   ├── PresidioNLPCoreML/       // optional: CoreML transformer NER + offset alignment + BIO decode
│   ├── PresidioNLPONNX/         // optional: ONNX Runtime backend (cross-platform parity)
│   ├── PresidioAnonymizer/      // Operator, operators, AnonymizerEngine, DeanonymizeEngine
│   ├── PresidioConfig/          // Yams-backed YAML/JSON, factory registry wiring, validation
│   ├── PresidioPhone/           // optional: PhoneNumberKit-backed PHONE_NUMBER + ZA variants
│   ├── PresidioStructured/      // TabularSource protocol + TabularData/CSV backends
│   ├── PresidioImage/           // optional: OCR protocol + Vision backend + redaction
│   ├── PresidioServer/          // Hummingbird REST, OpenAPI-generated
│   └── presidio-cli/            // executable
└── Tests/
    ├── PresidioConformance/     // fixture decoding + differential harness
    └── Fixtures/                // ~430 KB extracted JSON + 27 upstream YAML configs
```

**Dependency policy:** `PresidioCore`, `PresidioRegex`, `PresidioAnalyzer`, `PresidioRecognizers`, `PresidioAnonymizer` depend on **Foundation only**. Everything Apple-specific (`NaturalLanguage`, `Vision`, `TabularData`, `CoreML`) lives behind a protocol in a separate target so the Linux build degrades cleanly to the pure-regex path.

**Committed third-party set** (all MIT/Apache-2.0, all Darwin+Linux): Yams · swift-crypto ≥ 4.5.1 · Hummingbird 2.x · swift-argument-parser · swift-openapi-generator · swift-log. Optional: PhoneNumberKit.

### 3.2 `PresidioCore` — offsets and results

The offset decision is load-bearing. Presidio's start/end are **Unicode scalar** offsets; `NSRegularExpression` speaks UTF-16; Swift `String` is grapheme-indexed. Model it explicitly, with a fast path for the (overwhelmingly common) all-BMP case.

```swift
import Foundation

/// A Presidio character offset: a Unicode *scalar* index, matching Python `str` indexing.
/// This is the wire contract with the anonymizer and with Python Presidio.
public typealias ScalarOffset = Int

/// Text plus the index tables needed to move between Presidio (scalar) offsets and
/// NSRegularExpression (UTF-16) offsets without repeated O(n) walks.
public struct TextDocument: Sendable {
    public let text: String
    public let nsString: NSString          // retained so NSRange work is O(1)
    public let scalarCount: Int
    public let utf16Count: Int

    /// nil when every scalar is BMP, i.e. utf16 offset == scalar offset. The common case.
    @usableFromInline let scalarForUTF16: [Int32]?
    @usableFromInline let utf16ForScalar: [Int32]?

    public init(_ text: String) {
        self.text = text
        self.nsString = text as NSString
        self.scalarCount = text.unicodeScalars.count
        self.utf16Count = self.nsString.length

        if scalarCount == utf16Count {          // all-BMP fast path, no tables
            self.scalarForUTF16 = nil
            self.utf16ForScalar = nil
        } else {
            var s2u = [Int32](); s2u.reserveCapacity(scalarCount + 1)
            var u2s = [Int32](repeating: 0, count: utf16Count + 1)
            var u = 0
            for (si, scalar) in text.unicodeScalars.enumerated() {
                s2u.append(Int32(u))
                let width = UTF16.width(scalar)
                for k in 0..<width { u2s[u + k] = Int32(si) }
                u += width
            }
            s2u.append(Int32(u)); u2s[utf16Count] = Int32(scalarCount)
            self.utf16ForScalar = s2u
            self.scalarForUTF16 = u2s
        }
    }

    @inlinable public func scalarOffset(utf16 o: Int) -> ScalarOffset {
        scalarForUTF16.map { Int($0[o]) } ?? o
    }
    @inlinable public func utf16Offset(scalar o: ScalarOffset) -> Int {
        utf16ForScalar.map { Int($0[o]) } ?? o
    }

    /// The substring for a Presidio span. Never use String subscripting with raw Ints.
    public func substring(_ start: ScalarOffset, _ end: ScalarOffset) -> String {
        let r = NSRange(location: utf16Offset(scalar: start),
                        length: utf16Offset(scalar: end) - utf16Offset(scalar: start))
        return nsString.substring(with: r)
    }

    public func span(from range: NSRange) -> (start: ScalarOffset, end: ScalarOffset) {
        (scalarOffset(utf16: range.location),
         scalarOffset(utf16: range.location + range.length))
    }
}
```

```swift
public struct RecognizerID: Hashable, Sendable, RawRepresentable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    /// Deterministic replacement for Python's `f"{name}_{id(self)}"`.
    /// Collisions across same-named instances are an error at registry-build time.
    public init(name: String, language: String, entities: [String]) {
        self.rawValue = "\(name)|\(language)|\(entities.sorted().joined(separator: ","))"
    }
}

public struct RecognitionMetadata: Sendable, Hashable, Codable {
    public var recognizerName: String?
    public var recognizerIdentifier: RecognizerID?
    public var isScoreEnhancedByContext: Bool = false
    public var originalEntityType: String?
    public var extra: [String: String] = [:]
    public init() {}
}

public struct RecognizerResult: Sendable, Codable {
    public var entityType: String
    public var start: ScalarOffset
    public var end: ScalarOffset            // exclusive
    public var score: Double
    public var analysisExplanation: AnalysisExplanation?
    public var recognitionMetadata: RecognitionMetadata

    public static let minScore = 0.0
    public static let maxScore = 1.0
}

// Python: __eq__/__hash__ consider ONLY (entity_type, start, end, score).
// Explanation and metadata are deliberately excluded. Mirror that exactly.
extension RecognizerResult: Hashable {
    public static func == (a: Self, b: Self) -> Bool {
        a.entityType == b.entityType && a.start == b.start && a.end == b.end && a.score == b.score
    }
    public func hash(into h: inout Hasher) {
        h.combine(entityType); h.combine(start); h.combine(end); h.combine(score)
    }
}

// Python's sort key is (-score, start, -(end - start)) and OMITS entity_type, so ties are
// nondeterministic there. We add entityType as a final tiebreak to make Swift deterministic
// and document the divergence. Conformance normalizes both sides before comparing.
extension RecognizerResult: Comparable {
    public static func < (a: Self, b: Self) -> Bool {
        if a.score != b.score { return a.score > b.score }
        if a.start != b.start { return a.start < b.start }
        let la = a.end - a.start, lb = b.end - b.start
        if la != lb { return la > lb }
        return a.entityType < b.entityType     // <-- Swift-only, deterministic
    }
}

extension RecognizerResult {
    /// Overlap length, 0 if disjoint. NOTE: touching spans (a.end == b.start) return 0
    /// and are therefore NOT merged by the anonymizer's pass 1.
    public func intersects(_ o: Self) -> Int {
        if start == o.start && end == o.end { return max(end - start, o.end - o.start) }
        return max(0, min(end, o.end) - max(start, o.start))
    }
    public func containedIn(_ o: Self) -> Bool { start >= o.start && end <= o.end }
    public func contains(_ o: Self) -> Bool { o.start >= start && o.end <= end }
    public func equalIndices(_ o: Self) -> Bool { start == o.start && end == o.end }
    /// Python semantics: equal indices AND self.score <= other.score, OR other contains self.
    /// Note the `<=` — equal-score equal-span pairs are mutually conflicting.
    public func hasConflict(_ o: Self) -> Bool {
        (equalIndices(o) && score <= o.score) || o.contains(self)
    }
}
```

### 3.3 `PresidioRegex` — the ICU layer

```swift
import Foundation

/// Python `re` flag bitmask, persisted as the literal integer 26 in Presidio's YAML.
/// 26 = IGNORECASE(2) | MULTILINE(8) | DOTALL(16).
public struct PythonRegexFlags: OptionSet, Sendable, Codable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let ignoreCase = Self(rawValue: 2)
    public static let multiline  = Self(rawValue: 8)
    public static let dotAll     = Self(rawValue: 16)
    public static let unicode    = Self(rawValue: 32)   // default for str patterns; no-op here
    public static let verbose    = Self(rawValue: 64)
    public static let presidioDefault: Self = [.ignoreCase, .multiline, .dotAll]   // == 26

    var icuOptions: NSRegularExpression.Options {
        var o: NSRegularExpression.Options = []
        if contains(.ignoreCase) { o.insert(.caseInsensitive) }
        if contains(.multiline)  { o.insert(.anchorsMatchLines) }
        if contains(.dotAll)     { o.insert(.dotMatchesLineSeparators) }
        if contains(.verbose)    { o.insert(.allowCommentsAndWhitespace) }
        // DELIBERATELY NOT SET: .useUnicodeWordBoundaries.
        // ICU's default \b is the *simple* rule, which is what makes output byte-identical
        // to Python. Swift Regex defaults to UAX#29 and therefore diverges.
        return o
    }
}

/// NSRegularExpression is documented immutable and thread-safe for matching; the compile
/// cache Python keeps on the mutable Pattern object is replaced by eager compilation here.
public struct CompiledPattern: @unchecked Sendable {
    public let pattern: Pattern
    public let flags: PythonRegexFlags
    @usableFromInline let regex: NSRegularExpression

    public init(_ pattern: Pattern, flags: PythonRegexFlags) throws {
        try PatternLint.validate(pattern.regex)
        self.pattern = pattern
        self.flags = flags
        self.regex = try NSRegularExpression(pattern: pattern.regex, options: flags.icuOptions)
    }

    /// Deadline-bounded enumeration. This catches the many-matches blowup; it CANNOT
    /// interrupt a single catastrophic backtrack (see §4b).
    public func matches(in doc: TextDocument, deadline: ContinuousClock.Instant)
        -> (spans: [(NSRange, ScalarOffset, ScalarOffset)], timedOut: Bool)
    {
        var out: [(NSRange, ScalarOffset, ScalarOffset)] = []
        var timedOut = false
        let full = NSRange(location: 0, length: doc.utf16Count)
        regex.enumerateMatches(in: doc.text, options: [], range: full) { m, _, stop in
            guard let m, m.range.length > 0 else { return }         // Python skips empty matches
            if ContinuousClock.now > deadline { timedOut = true; stop.pointee = true; return }
            let (s, e) = doc.span(from: m.range)
            out.append((m.range, s, e))
        }
        return (out, timedOut)
    }
}

public enum PatternLint {
    /// ICU silently treats \K as a literal 'K' and rejects Python named groups. Fail loudly
    /// at load time so an upstream pattern change can never silently misbehave.
    static let forbidden = ["\\K", "(?P<", "(?P=", "(?R)", "(?1)", "(?("]
    public static func validate(_ p: String) throws {
        for f in forbidden where p.contains(f) {
            throw PresidioError.unsupportedRegexConstruct(construct: f, pattern: p)
        }
    }
}

public enum PythonRegex {
    /// Port of CPython's `re.escape` (3.7+), which escapes EXACTLY this set.
    /// NSRegularExpression.escapedPattern(for:) escapes a *different* set, so deny-list
    /// alternations built with it are not byte-equivalent to Presidio's.
    private static let specials = Set("()[]{}?*+-|^$\\.&~# \t\n\r\u{0b}\u{0c}")
    public static func escape(_ s: String) -> String {
        String(s.flatMap { specials.contains($0) ? ["\\", $0] : [$0] })
    }
    /// Presidio's deny-list construction, verbatim: pattern_recognizer.py:132-134
    public static func denyListPattern(_ terms: [String]) -> String {
        "(?:^|(?<=\\W))(" + terms.map(escape).joined(separator: "|") + ")(?:(?=\\W)|$)"
    }
}
```

### 3.4 `PresidioAnalyzer` — recognizers

**Existentials vs generics.** The registry is inherently heterogeneous, so `any EntityRecognizer` is unavoidable at the registry boundary. Crucially, the existential dispatch happens **once per recognizer per document** (~100 calls), not per match — and because ~85 of 99 recognizers collapse into a single concrete `PatternRecognizer` type parameterized by data, the inner loop stays monomorphic. Do not chase generic specialization here; it buys nothing and makes the registry unrepresentable.

**Why `async`.** Local recognizers do sync CPU work and gain nothing from `async`. But making the requirement `async throws` buys three things worth the negligible overhead at ~100 calls/document: (1) model-backed recognizers can be `actor`s (an actor satisfies an `async` protocol requirement, which is how you get lazy model loading without shared mutable state); (2) remote recognizers (Azure, LLM) need it; (3) `TaskGroup` gives you parallel recognizer execution and cooperative cancellation, which is part of the timeout story.

```swift
public protocol EntityRecognizer: Sendable {
    var id: RecognizerID { get }
    var name: String { get }
    var version: String { get }
    var supportedEntities: [String] { get }
    var supportedLanguage: String { get }
    var contextWords: [String] { get }
    var countryCode: String? { get }
    var scoreThresholds: [String: Double] { get }   // special key "default"

    /// Python's load()/is_loaded lazy-load. Default: no-op. Actors override this.
    func prepare() async throws

    func analyze(_ doc: TextDocument,
                 entities: Set<String>,
                 artifacts: NLPArtifacts?,
                 options: AnalyzeOptions) async throws -> [RecognizerResult]

    /// Per-recognizer context enhancement (phase 1 of _enhance_using_context).
    /// Receives its OWN results and everyone else's, enabling related-entity boosting.
    func enhanceUsingContext(_ doc: TextDocument,
                             own: [RecognizerResult],
                             others: [RecognizerResult],
                             artifacts: NLPArtifacts?,
                             requestContext: [String]) -> [RecognizerResult]
}

public extension EntityRecognizer {
    func prepare() async throws {}
    func enhanceUsingContext(_ doc: TextDocument, own: [RecognizerResult],
                             others: [RecognizerResult], artifacts: NLPArtifacts?,
                             requestContext: [String]) -> [RecognizerResult] { own }
    var countryCode: String? { nil }
    var scoreThresholds: [String: Double] { [:] }
    var version: String { "0.0.1" }
}
```

```swift
public struct Pattern: Sendable, Hashable, Codable {
    public let name: String
    public let regex: String
    public let score: Double            // validated 0...1 at init
}

/// Python's Optional[bool] tri-state, made explicit. True -> force 1.0, False -> force 0.0
/// (dropped), None -> keep the pattern score.
public enum PatternValidation: Sendable {
    case valid, invalid, inconclusive
}
public typealias PatternValidator = @Sendable (String) -> PatternValidation
public typealias PatternInvalidator = @Sendable (String) -> Bool

/// ONE concrete type covers 85 of 99 predefined recognizers. Behavior is data
/// (patterns + context + deny list) plus at most two closures (the checksum hooks).
public struct PatternRecognizer: EntityRecognizer {
    public let id: RecognizerID
    public let name: String
    public let version: String
    public let supportedEntities: [String]
    public let supportedLanguage: String
    public let contextWords: [String]
    public let countryCode: String?
    public let scoreThresholds: [String: Double]

    let compiled: [CompiledPattern]
    let validate: PatternValidator?
    let invalidate: PatternInvalidator?

    public init(entity: String, name: String? = nil, language: String = "en",
                patterns: [Pattern] = [], denyList: [String] = [],
                denyListScore: Double = 0.3,        // SEE §10: upstream default is disputed
                context: [String] = [], countryCode: String? = nil,
                scoreThresholds: [String: Double] = [:],
                flags: PythonRegexFlags = .presidioDefault,
                validate: PatternValidator? = nil,
                invalidate: PatternInvalidator? = nil) throws {
        var all = patterns
        if !denyList.isEmpty {
            all.append(Pattern(name: "deny_list",
                               regex: PythonRegex.denyListPattern(denyList),
                               score: denyListScore))
        }
        self.compiled = try all.map { try CompiledPattern($0, flags: flags) }
        self.name = name ?? "\(entity)Recognizer"
        self.supportedEntities = [entity]
        self.supportedLanguage = language
        self.contextWords = context
        self.countryCode = countryCode
        self.scoreThresholds = scoreThresholds
        self.version = "0.0.1"
        self.validate = validate
        self.invalidate = invalidate
        self.id = RecognizerID(name: self.name, language: language, entities: [entity])
    }

    public func analyze(_ doc: TextDocument, entities: Set<String>,
                        artifacts: NLPArtifacts?, options: AnalyzeOptions)
        async throws -> [RecognizerResult]
    {
        guard let entity = supportedEntities.first, entities.contains(entity) else { return [] }
        var out: [RecognizerResult] = []
        let deadline = ContinuousClock.now + options.perPatternBudget

        for cp in compiled {
            let (spans, timedOut) = cp.matches(in: doc, deadline: deadline)
            if timedOut { options.log(.regexBudgetExceeded(cp.pattern.name)) }   // Python: skip pattern
            for (_, s, e) in spans {
                let matched = doc.substring(s, e)
                var score = cp.pattern.score
                var expl = AnalysisExplanation(recognizer: name,
                                               originalScore: score,
                                               patternName: cp.pattern.name,
                                               pattern: cp.pattern.regex)
                if let validate {
                    switch validate(matched) {
                    case .valid:        score = RecognizerResult.maxScore; expl.validationResult = true
                    case .invalid:      score = RecognizerResult.minScore; expl.validationResult = false
                    case .inconclusive: break
                    }
                }
                if invalidate?(matched) == true { score = RecognizerResult.minScore }
                expl.score = score
                guard score > RecognizerResult.minScore else { continue }
                out.append(RecognizerResult(entityType: entity, start: s, end: e,
                                            score: score, analysisExplanation: expl,
                                            recognitionMetadata: .init()))
            }
        }
        // Python runs remove_duplicates HERE too (pattern_recognizer.py:280), i.e. twice overall.
        return Deduplicator.removeDuplicates(out)
    }
}
```

Example of a checksum recognizer under this design — a whole Python class becomes a factory function plus a free function:

```swift
enum USRecognizers {
    static func usSSN() throws -> PatternRecognizer {
        try PatternRecognizer(
            entity: "US_SSN", name: "UsSsnRecognizer", countryCode: "us",
            patterns: PatternData.load("us_ssn"),          // from Resources JSON
            context: PatternData.context("us_ssn"),
            invalidate: { text in
                let d = text.filter(\.isNumber)
                guard d.count == 9 else { return false }
                let a = d.prefix(3), g = d.dropFirst(3).prefix(2), s = d.suffix(4)
                if a == "000" || a == "666" || a.first == "9" { return true }
                if g == "00" || s == "0000" { return true }
                return Set(d).count == 1
            })
    }
}
```

### 3.5 `PresidioNLP` — the engine seam

The critical finding: `NlpArtifacts` is consumed at exactly **two** call sites in all of Presidio (`SpacyRecognizer.analyze` reads `.entities`/`.scores`; `LemmaContextAwareEnhancer` reads `.tokens`/`.tokens_indices`/`.lemmas`/`.keywords`), and the spaCy `Doc` in `.tokens` is only used for truthiness, `enumerate()`, `len(token)`, and `token.text`. There is **no** POS field, no sentence boundaries, no dependency parse, no vectors in the contract — despite documentation claiming otherwise. So `[Token]` is a faithful substitute and the entire NLP layer swaps behind one protocol method.

```swift
public struct Token: Sendable, Hashable, Codable {
    public let text: String
    public let lemma: String
    public let start: ScalarOffset
    public let scalarLength: Int
    public let isStopword: Bool
    public let isPunctuation: Bool
}

public struct NLPEntity: Sendable, Hashable, Codable {
    public let label: String
    public let start: ScalarOffset
    public let end: ScalarOffset
    public let score: Double            // spaCy has none; Presidio fabricates 0.85
}

public struct NLPArtifacts: Sendable {
    public let language: String
    public let tokens: [Token]
    public let entities: [NLPEntity]
    /// lowercased lemmas minus stopwords, punctuation, "-PRON-" and "be",
    /// each split on ":" and flattened.  (nlp_artifacts.py:41-70)
    public let keywords: [String]

    public static func empty(_ lang: String) -> Self {
        .init(language: lang, tokens: [], entities: [], keywords: [])
    }
}

public protocol NLPEngine: Sendable {
    var engineName: String { get }
    var supportedLanguages: [String] { get }
    var supportedEntities: [String] { get }
    func prepare() async throws
    func process(_ doc: TextDocument, language: String) async throws -> NLPArtifacts
    func processBatch(_ docs: [TextDocument], language: String)
        -> AsyncThrowingStream<(TextDocument, NLPArtifacts), Error>
}

/// Proof the NLP layer is architecturally optional — and a legitimate shipping config
/// for regex-only PII detection. Mirrors NoOpNlpEngine (168 LOC, no ML).
public struct NoOpNLPEngine: NLPEngine {
    public let engineName = "no_op"
    public var supportedLanguages: [String] { [] }
    public var supportedEntities: [String] { [] }
    public func prepare() async throws {}
    public func process(_ doc: TextDocument, language: String) async throws -> NLPArtifacts {
        .empty(language)
    }
    public func processBatch(_ docs: [TextDocument], language: String)
        -> AsyncThrowingStream<(TextDocument, NLPArtifacts), Error> { /* ... */ }
}
```

### 3.6 `PresidioConfig` — YAML → factory registry

This replaces 833 LOC of `__subclasses__()` reflection plus 659 LOC of Pydantic. The mapping is:

| Python mechanism | Swift replacement |
|---|---|
| `EntityRecognizer.__subclasses__()` recursion | `BuiltinRecognizers.all: [RecognizerFactory]`, one line per recognizer |
| `recognizer_name == cls.__name__` string match | `[String: RecognizerFactory]` keyed on `identifier` |
| `inspect.signature(cls.__init__).parameters` kwarg reshaping | `RecognizerSpec` Codable struct + per-factory `acceptedKeys` metadata |
| `type: predefined` vs `type: custom` key-exclusion sets | Two decode paths on the spec's discriminator |
| `getattr(cls, "COUNTRY_CODE")` + module-path `country_specific/<cc>` parsing | `countryCode` on the factory, declared explicitly |
| Pydantic `extra='allow'` | `spec.extra: [String: ConfigValue]`, surfaced to the factory; strictness is a flag |

```swift
/// Decoded form of one entry in default_recognizers.yaml. Deliberately permissive:
/// unknown keys land in `extra` rather than failing, mirroring Pydantic extra='allow'.
public struct RecognizerSpec: Sendable, Codable {
    public var name: String?
    public var className: String?          // when present, this is the LOOKUP key and `name` is the label
    public var type: SpecKind = .custom    // .predefined | .custom
    public var enabled: Bool = true
    public var supportedLanguage: String?
    public var supportedLanguages: [LanguageContext]?
    public var supportedEntity: String?
    public var supportedEntities: [String]?
    public var patterns: [Pattern]?
    public var denyList: [String]?
    public var denyListScore: Double?
    public var context: [String]?
    public var countryCode: String?
    public var scoreThresholds: [String: Double]?
    public var globalRegexFlags: PythonRegexFlags?
    public var extra: [String: ConfigValue] = [:]

    /// The lookup key. Mirrors recognizers_loader_utils.py:142-161.
    public var lookupKey: String { className ?? name ?? "PatternRecognizer" }
}

public struct RecognizerFactory: Sendable {
    public let identifier: String
    public let countryCode: String?
    /// Keys this recognizer's initializer accepts. Replaces inspect.signature introspection.
    public let acceptedKeys: Set<String>
    public let make: @Sendable (RecognizerSpec, RecognizerBuildContext) throws -> any EntityRecognizer

    public init<R: EntityRecognizer>(_: R.Type, identifier: String, countryCode: String? = nil,
                                     acceptedKeys: Set<String>,
                                     make: @escaping @Sendable (RecognizerSpec, RecognizerBuildContext) throws -> R) {
        self.identifier = identifier
        self.countryCode = countryCode
        self.acceptedKeys = acceptedKeys
        self.make = { try make($0, $1) }
    }
}

public enum BuiltinRecognizers {
    public static let all: [RecognizerFactory] = [
        .init(PatternRecognizer.self, identifier: "PatternRecognizer",
              acceptedKeys: ["supported_entity", "patterns", "deny_list", "context",
                             "deny_list_score", "country_code"],
              make: { spec, ctx in try PatternRecognizer(spec: spec, ctx: ctx) }),
        .init(PatternRecognizer.self, identifier: "UsSsnRecognizer", countryCode: "us",
              acceptedKeys: ["supported_language", "context"],
              make: { spec, ctx in try USRecognizers.usSSN(spec: spec, ctx: ctx) }),
        // ... one line per predefined recognizer (99 total)
    ]
}

public struct RecognizerBuilder: Sendable {
    private let factories: [String: RecognizerFactory]
    public let strictness: ConfigStrictness      // .lenient mirrors extra='allow'; .strict rejects

    public init(_ fs: [RecognizerFactory] = BuiltinRecognizers.all,
                strictness: ConfigStrictness = .lenient) throws {
        var m: [String: RecognizerFactory] = [:]
        for f in fs {
            guard m.updateValue(f, forKey: f.identifier) == nil else {
                throw PresidioError.duplicateRecognizerIdentifier(f.identifier)
            }
        }
        self.factories = m; self.strictness = strictness
    }

    public mutating func register(_ f: RecognizerFactory) { /* additive, host-app extension */ }

    public func build(_ spec: RecognizerSpec, ctx: RecognizerBuildContext)
        throws -> [any EntityRecognizer]
    {
        guard spec.enabled else { return [] }
        guard let f = factories[spec.lookupKey] else {
            // Strictly better diagnostics than Python's PredefinedRecognizerNotFoundError.
            throw PresidioError.unknownRecognizer(spec.lookupKey, known: factories.keys.sorted())
        }
        if strictness == .strict, let bad = spec.extra.keys.first(where: { !f.acceptedKeys.contains($0) }) {
            throw PresidioError.unexpectedConfigKey(bad, recognizer: f.identifier)
        }
        // One instance per supported language (recognizers_loader_utils.py:99-140)
        return try ctx.languages(for: spec).map { lang in
            try f.make(spec.applying(language: lang), ctx)
        }
    }
}
```

**Do not** reach for `NSClassFromString` (Darwin-only, ObjC-runtime-only, forces `NSObject`), `_typeByName` (underscored SPI over mangled names; a bare metatype still can't be constructed without the protocol conformance you'd have had to declare anyway), or `dlopen` plugins (no Swift ABI stability on Linux, impossible on iOS, destroys the static-musl deployment story). Macros can synthesize the per-type boilerplate but **cannot** eliminate the explicit `all` array — a macro only sees the declaration it is attached to. Skip macros in v1; `swift-syntax` measurably slows clean builds.

### 3.7 `AnalyzerEngine`

The 11-step order is behaviorally load-bearing — in particular, thresholding runs **before** dedup (deliberately, per the upstream comment: recognizer-specific thresholds would otherwise be lost when duplicate spans collapse), and results are **not** sorted before return.

```swift
public struct AnalyzeOptions: Sendable {
    public var entities: Set<String>? = nil        // nil OR empty both mean "all"
    public var scoreThreshold: Double? = nil       // when set, bypasses per-recognizer thresholds
    public var returnDecisionProcess = false
    public var context: [String] = []
    public var allowList: [String] = []
    public var allowListMatch: AllowListMatch = .exact
    public var regexFlags: PythonRegexFlags = .presidioDefault
    public var adHocRecognizers: [any EntityRecognizer] = []
    public var precomputedArtifacts: NLPArtifacts? = nil
    public var perPatternBudget: Duration = .seconds(60)   // REGEX_TIMEOUT_SECONDS analogue
    public var maxConcurrentRecognizers = 1                // 1 == Python's sequential loop
}

public struct AnalyzerEngine: Sendable {
    public let registry: RecognizerRegistry
    public let nlpEngine: any NLPEngine
    public let contextEnhancer: (any ContextAwareEnhancer)?
    public let defaultScoreThreshold: Double
    public let supportedLanguages: [String]

    public func analyze(text: String, language: String,
                        options: AnalyzeOptions = .init()) async throws -> [RecognizerResult] {
        let doc = TextDocument(text)
        let allFields = (options.entities?.isEmpty ?? true)

        // 2. select recognizers (throws on no-language / no-entities / no-match, as Python does)
        let recognizers = try registry.recognizers(language: language,
                                                   entities: options.entities,
                                                   allFields: allFields,
                                                   adHoc: options.adHocRecognizers)
        // 3. re-derive the entity set from the union of supported entities
        let entities: Set<String> = allFields
            ? Set(recognizers.flatMap(\.supportedEntities))
            : options.entities!

        // 4. one NLP pass per analyze() — the entire integration surface
        let artifacts = try await options.precomputedArtifacts
            ?? nlpEngine.process(doc, language: language)

        // 5. run recognizers, stamping identity metadata
        var results: [RecognizerResult] = []
        for r in recognizers {
            try await r.prepare()
            var partial = try await r.analyze(doc, entities: entities,
                                              artifacts: artifacts, options: options)
            for i in partial.indices {
                if partial[i].recognitionMetadata.recognizerIdentifier == nil {
                    partial[i].recognitionMetadata.recognizerIdentifier = r.id
                    partial[i].recognitionMetadata.recognizerName = r.name
                }
            }
            results += partial
        }

        // 6. two-phase context enhancement: per-recognizer, then global
        results = enhanceUsingContext(doc, results, recognizers, artifacts, options.context)

        // 8. thresholds BEFORE dedup — do not reorder
        results = applyThresholds(results, recognizers, explicit: options.scoreThreshold)
        // 9. dedup algorithm #1
        results = Deduplicator.removeDuplicates(results)
        // 10. allow-list removal (only when non-empty)
        if !options.allowList.isEmpty {
            results = try applyAllowList(doc, results, options)
        }
        // 11. strip explanations unless requested
        if !options.returnDecisionProcess {
            for i in results.indices { results[i].analysisExplanation = nil }
        }
        return results     // deliberately NOT sorted, matching Python
    }
}

enum Deduplicator {
    /// entity_recognizer.py:275-307. Same-entity-type containment suppression only;
    /// overlapping spans of DIFFERENT types both survive here (the anonymizer resolves those).
    static func removeDuplicates(_ input: [RecognizerResult]) -> [RecognizerResult] {
        var seen = Set<RecognizerResult>()
        let unique = input.filter { seen.insert($0).inserted }
        var filtered: [RecognizerResult] = []
        for r in unique.sorted() {                       // total order, deterministic in Swift
            if r.score == 0 { continue }                 // zero-score results dropped outright
            if filtered.contains(r) { continue }
            if filtered.contains(where: { r.containedIn($0) && r.entityType == $0.entityType }) {
                continue
            }
            filtered.append(r)
        }
        return filtered
    }
}
```

### 3.8 `PresidioAnonymizer` — Operator + engine

```swift
public enum OperatorKind: Sendable, Hashable { case anonymize, deanonymize }

/// The `entity_type` Python injects into the params dict is a first-class field here.
public struct OperatorParams: Sendable {
    public let entityType: String
    public let values: [String: ConfigValue]

    public func string(_ k: String) throws -> String { /* typed accessor, throws InvalidParam */ }
    public func int(_ k: String) throws -> Int { /* ... */ }
    public func bool(_ k: String) throws -> Bool { /* ... */ }
    public func optionalString(_ k: String) -> String? { /* ... */ }
}

public protocol Operator: Sendable {
    static var operatorName: String { get }
    static var operatorKind: OperatorKind { get }
    func validate(_ params: OperatorParams) throws
    func operate(text: String, params: OperatorParams) throws -> String
}

public struct Replace: Operator {
    public static let operatorName = "replace"
    public static let operatorKind = OperatorKind.anonymize
    public func validate(_ p: OperatorParams) throws {
        // Python's validate_type short-circuits on falsy values, so new_value="" bypasses
        // the type check entirely. Swift's type system makes that unrepresentable; we accept
        // the divergence and document it (a strongly-typed port REJECTS inputs Presidio accepts).
    }
    public func operate(text: String, params: OperatorParams) throws -> String {
        let v = params.optionalString("new_value") ?? ""
        return v.isEmpty ? "<\(params.entityType)>" : v      // falsy -> "<ENTITY_TYPE>"
    }
}

public struct Mask: Operator {
    public static let operatorName = "mask"
    public static let operatorKind = OperatorKind.anonymize
    public func validate(_ p: OperatorParams) throws {
        let ch = try p.string("masking_char")
        guard ch.unicodeScalars.count <= 1 else { throw PresidioError.invalidParam("masking_char") }
    }
    public func operate(text: String, params: OperatorParams) throws -> String {
        let ch = try params.string("masking_char")
        let n  = try params.int("chars_to_mask")
        let fromEnd = try params.bool("from_end")
        // Python counts CODE POINTS. The upstream test suite pins this with emoji rows:
        //   ("text", "😈", 4, false) -> "😈😈😈😈"   and   ("😈😈😈😈", "*", 4, false) -> "****"
        let scalars = Array(text.unicodeScalars)
        let eff = n > 0 ? min(scalars.count, n) : 0
        let pad = String(repeating: ch, count: eff)
        return fromEnd
            ? String(String.UnicodeScalarView(scalars.prefix(scalars.count - eff))) + pad
            : pad + String(String.UnicodeScalarView(scalars.dropFirst(eff)))
    }
}

/// operators_factory.py builds its registry by INSTANTIATING each class to read its name.
/// Swift uses static metatype registration instead.
public struct OperatorRegistry: Sendable {
    private var anonymizers: [String: @Sendable () -> any Operator]
    private var deanonymizers: [String: @Sendable () -> any Operator]

    public static let builtin = OperatorRegistry(
        anonymize: [Replace.self, Redact.self, Mask.self, Hash.self,
                    Encrypt.self, Keep.self],
        deanonymize: [Decrypt.self, DeanonymizeKeep.self])

    public mutating func register<O: Operator>(_ t: O.Type, _ make: @escaping @Sendable () -> O)
}
```

The rewrite engine — the from-the-end anchoring is the subtlest thing in the whole package and must be reproduced exactly:

```swift
struct TextReplaceBuilder {
    private var output: [Unicode.Scalar]
    private let original: [Unicode.Scalar]
    private var lastReplacementIndex: Int

    init(_ doc: TextDocument) {
        original = Array(doc.text.unicodeScalars)
        output = original
        lastReplacementIndex = original.count
    }

    func text(start: Int, end: Int) -> String {
        // NOTE: the operator receives the FULL original span text even though only the
        // unclipped portion is removed. Preserve this.
        String(String.UnicodeScalarView(original[start..<end]))
    }

    /// Returns a distance measured from the END of the still-growing output.
    mutating func replace(_ replacement: String, start: Int, end: Int) -> Int {
        let clippedEnd = min(end, lastReplacementIndex)
        let repl = Array(replacement.unicodeScalars)
        let after = Array(output[clippedEnd...])
        output = Array(output[..<start]) + repl + after
        lastReplacementIndex = start
        return after.count + repl.count
    }

    var result: String { String(String.UnicodeScalarView(output)) }
}

extension EngineResult {
    /// engine_result.py:35-40 — convert from-end anchors to from-start indexes.
    mutating func normalizeItemIndexes() {
        let n = text.unicodeScalars.count
        for i in items.indices {
            items[i].start = n - items[i].end
            items[i].end = items[i].start + items[i].text.unicodeScalars.count
        }
    }
}
```

---

## 4. The three hard problems

### (a) NER parity without spaCy

**The baseline.** Presidio's shipped `conf/default.yaml` is spaCy `en_core_web_lg`, whose OntoNotes labels are mapped to 5 Presidio entities (PERSON, LOCATION, ORGANIZATION, NRP, DATE_TIME) with 11 labels ignored. Scores are *fabricated* at 0.85 (spaCy produces no confidences); `low_score_entity_names` get `score *= 0.4`. ORGANIZATION is **ignored by default** upstream because of false positives — a fact that materially reduces the parity bar.

**What Apple gives you, empirically probed on macOS 26 / Swift 6.2.4:**

| Capability | Result |
|---|---|
| `NLTagger(.nameType)` | Exactly 3 tags: `personalName`, `placeName`, `organizationName`. **8 languages**: en, es, fr, de, it, pt, ru, tr. |
| `NLTagger(.lemma)` | **10 languages** (those 8 + nl, sv). Genuine dictionary lemmas: children→child, were→be, better→good. |
| `tagHypotheses(at:unit:scheme:maximumCount:)` | Per-tag confidence — "David Johnson"→0.999, "Maine"→0.892. Maps directly onto `RecognizerResult.score`, replacing the fabricated 0.85. |
| `NSDataDetector` | `.date`, `.address`, `.link`, `.phoneNumber`, `.transitInformation`. Verified: "January 4th 1985", "2021-05-14", "next Tuesday at 3pm", componentized US address. **This is the DATE_TIME answer.** |
| `NLGazetteer` + `setGazetteers(_:for:.nameType)` | Verified end-to-end: custom `NRP` tags **interleave cleanly with built-in tags in one `enumerateTags` pass**. 24 KB binary for a modest vocabulary. **This is the NRP answer.** |
| Throughput | nameType pass ~495 KB/s (~97k tokens/s) over 51 KB; ~10× spaCy `en_core_web_lg`. Zero binary footprint. |

**Measured failure modes** (these are the honest cost):

- **Case fragility, the worst regression.** "Barack Obama visited Berlin." → PersonalName + PlaceName correctly. Lowercase "barack obama visited berlin." → **nothing found**. spaCy degrades on lowercase too, but far less catastrophically. ALL-CAPS mostly works but mis-splits ("MOHAMMED AL-FARSI" → PersonalName "MOHAMMED" + PlaceName "FARSI").
- **Type confusion.** "Los Angeles" → PersonalName. "Massachusetts General Hospital" → PlaceName.
- **Recall misses.** "Sunnybrook Health Sciences Centre" missed entirely.

**Mitigation stack, in order:**

1. **Layer it.** `protocol NerProvider` with three conformances: `NLTaggerNerProvider` (baseline, ships everywhere), `CoreMLNerProvider` (optional accuracy upgrade), `RemoteNerProvider`. Never let a higher tier gate a lower one. This is exactly the direction Presidio itself is moving (`slim.yaml` swaps `SpacyRecognizer` for `GLiNERRecognizer`; the slim engine docstring says "intended for use in Presidio v3 where entity extraction is handled by self-contained recognizers").
2. **Case normalization pre-pass.** Detect all-lower / all-upper input and either truecase it or route to the CoreML backend. Do not silently return zero entities.
3. **Given-names gazetteer.** `NLGazetteer` with a bundled name list, specifically to catch standalone and all-caps names. This is exactly what the one shipping Swift product engine (clipscrub-core, Apache-2.0) does, and it converged there independently.
4. **Exploit Presidio's own conservatism.** GPE/LOC/FAC all map to LOCATION and ORGANIZATION is ignored by default, so PlaceName↔OrganizationName confusion largely washes out. PERSON↔LOCATION cross-contamination is the residual precision hit.
5. **CoreML BERT for accuracy-critical work.** `dslim/bert-base-NER` (MIT, ~91 F1 CoNLL-03) or `obi/deid_roberta_i2b2` (MIT, what Presidio itself recommends for clinical de-id). **Warning: the one published CoreML conversion of bert-base-NER is 1,329 MB (float32) — unshippable.** You must quantize: fp16 ≈ 215 MB, int8 ≈ 110 MB, int4 palettization ≈ 55–70 MB. Use `EnumeratedShapes` `[64,128,256,384,512]` (not `RangeDim` — unbounded ranges are not permitted for ML programs and RangeDim is slower) and set the Reshape Frequency optimization hint to `.infrequent`, or flexible-shape models silently fall off the ANE.
6. **The offset-alignment landmine.** `swift-transformers` provides `BertTokenizer`/`BPETokenizer`/`UnigramTokenizer` (the full `tokenizers.json` pipeline) and **builds on Linux** (CI-tested, `swift:6.2.3`, CoreML properly `#if canImport`-guarded). But grep-confirmed: it has **no** offset-mapping API — the `Tokenizer` protocol exposes only `tokenize`/`encode`/`decode`, with no `Range<String.Index>`/`NSRange`/offsets equivalent to HF's `return_offsets_mapping`. It also has **no token-classification pipeline** (zero grep hits for `TokenClassification`). So on the transformer path you hand-write: subword→character alignment, BIO/BILOU decoding, subword merging, and all four HF aggregation strategies (`simple`/`first`/`average`/`max`) plus the overlapping-window `stride` logic — roughly 250–400 lines that must match `TokenClassificationPipeline` semantics or entity boundaries drift. Mitigate with an invariant assertion that every emitted span's substring round-trips against the source, plus property tests over emoji/combining-mark/CJK corpora.
7. **Stopword lists.** Presidio does not ship them — it borrows spaCy's per-language `STOP_WORDS`. You must vendor them (en is on the order of a few hundred entries) or `keywords` diverges and **every regex recognizer's context boost changes**. Non-optional if you want context-enhancement parity.
8. **Publish a per-entity fidelity table.** Do not claim parity. "Presidio-compatible, not Presidio-identical" is the correct framing and the main reputational risk is overclaiming here.

**Do not build on `FoundationModels`.** Three independent problems: it requires Apple Intelligence hardware so it can't be a baseline; its guardrails filter self-harm/violence/sexual content and **cannot be disabled**, so a PII-laden document can simply be refused (a redaction tool that fails on sensitive documents is worse than useless); and an LLM returns text, not character offsets. Additive pass only, behind `#if canImport(FoundationModels)`.

**Do not budget on `DataDetection.framework`.** SDK headers confirmed: it ships `DDMatchEmailAddress`, `DDMatchPostalAddress` (structured street/city/state/postal/country), `DDMatchMoneyAmount` etc. — but these are **result types only**. There is no detector or scanner class in the public headers and every `DDMatch` declares `init NS_UNAVAILABLE`. It is the result vocabulary for VisionKit's `DataScannerViewController` (camera/live text), not an API you can point at a `String`. `NSDataDetector` remains the only text-scanning data detector.

### (b) Regex dialect differences, especially lookbehind

**Decision: `NSRegularExpression` (ICU). Not Swift Regex. This is not close.**

Measured on Apple Swift 6.2.4 / Xcode 26.2 SDK / macOS 26 / arm64 vs Python 3.10.7, against 155 real Presidio patterns extracted by AST from 82 files:

| | NSRegularExpression | Swift Regex | Python `re` |
|---|---|---|---|
| Presidio patterns compiling | **155/155**, unmodified | 136/155 (**0/19** lookbehind) | 155/155 |
| Match agreement vs Python on 759 KB corpus | **155/155 agree, 0 disagree** (1,563 matches) | n/a | baseline |
| Runtime, 155 patterns × 759 KB | **3.246 s** serial / 1.949 s ×14 cores | ~100 s extrapolated | 3.919 s |
| 103-pattern synthetic set | 0.652 s | 20.719 s (**31.8× slower**) | 1.192 s |
| Presidio's own IBAN pattern, adversarial input | **0.010 s** | **hangs >120 s** | 0.000 s |
| OS availability floor | **none** (back to macOS 10.7) | macOS 13+/iOS 16+ | n/a |

Swift Regex has **no lookbehind support at all** — neither fixed nor variable. `Regex("(?<=\\$)\\d+")` throws "lookbehind is not currently supported"; the literal form is a compile error. SE-0448 is *Accepted* but its implementation PR (`swift-experimental-string-processing#760`) was still an open draft as of 2026-01-30 despite secondary sources claiming it shipped in 6.2. Do not wait for it.

Swift Regex also silently changes `\b` semantics: it defaults to UAX #29, so `\b\w+\b` on "don't stop" yields `["stop"]` where Python yields `["don","t","stop"]`. ICU's default is the *simple* rule, which is precisely why it is byte-identical.

**Implementation requirements:**

- **Keep patterns as strings in data files** mirroring Presidio's structure so you can `diff` against upstream. Do **not** transcribe into `RegexBuilder` — it compiles to the same slow engine, inherits every limitation, and turns 155 one-liners into thousands of lines you can no longer diff.
- **Never set `.useUnicodeWordBoundaries`.** This is the single line that preserves `\b` parity.
- **Flag 26 round-trip.** `PythonRegexFlags(rawValue: 26)` ↔ `.caseInsensitive | .anchorsMatchLines | .dotMatchesLineSeparators`. Preserve the integer in YAML.
- **Port `re.escape` exactly.** CPython 3.7+ escapes exactly `()[]{}?*+-|^$\.&~# \t\n\r\v\f`. `NSRegularExpression.escapedPattern(for:)` escapes a different set, so deny-list alternations built with it are not byte-equivalent.
- **Lint at load:** reject `\K` (ICU compiles it and silently treats it as a literal `K` — a silent-wrong-answer footgun), `(?P<`, `(?(cond)`, `(?R)`, `(?1)`. None appear in Presidio today; the lint prevents a future upstream pattern from misbehaving silently.
- **Bounded-lookbehind ceiling.** ICU rejects unbounded lookbehind like `(?<=a+)`. All 19 Presidio lookbehind patterns are single-character negative classes (`(?<!\d)`, `(?<![\w-]`, `(?<![\w:])`, `(?<![A-Z0-9])`, `(?<!\w)`, `(?<![A-Z0-9a-z])`), so exposure today is zero — but the lint should flag any future variable-length one.
- **Assemble the 6 non-literal patterns in Swift**, not by extraction: `us_mbi_recognizer.py:65,70` (f-strings from `VALID_LETTERS`) and `url_recognizer.py:24-27` (four `(?i)` + `BASE_URL_REGEX` concatenations).
- **The two numeric backreferences** (`ca_sin` `\b[1-79]\d{2}([- ])\d{3}\1\d{3}\b`, `mac` with a backref *inside a repeated group*) compile and match under ICU — but explicitly conformance-test them; backref-inside-repetition is the one place engines historically differ.

**ReDoS is the residual risk, and it is inherited, not introduced.** ICU is still a backtracker: `(a+)+b` on 26 characters takes 4.3 s (Python: 4.8 s). Presidio's Python has `regex.finditer(timeout=60)`; there is no equivalent in any Swift engine. Partial mitigation, in order of value:

1. **Fix the hot patterns first.** One pattern (`\b((?=.*?[a-zA-Z])(?=.*?[0-9]{4})[\w@#$%^?~-]{10})\b`) accounts for **47% of total runtime**; adding cores before fixing it gave only 1.67× on 14 cores. The 7.5 KB / ~700-TLD `BASE_URL_REGEX` and the 504-char IPv6 alternation are the other candidates.
2. **Structural prefilter.** 154/155 patterns require at least one digit. A cheap SIMD digit-presence scan over windows skips most natural-language text before any regex runs. Literal prefiltering (Aho-Corasick) is useless: only 5/155 patterns contain a ≥3-character literal run.
3. **Deadline in `enumerateMatches`.** Catches the many-matches blowup. It cannot interrupt a single catastrophic backtrack, because the callback only fires per match found — be honest about this in the design doc, don't sell it as a timeout.
4. **Input length caps** per regex pass, plus offline ReDoS static analysis of the pattern corpus in CI.

**Long-term escape hatch, if throughput or ReDoS becomes blocking:** vendor the Rust `regex` crate behind a C ABI shim. Guaranteed linear time, and `RegexSet` gives true single-pass multi-pattern scanning (there is no RE2::Set or Hyperscan equivalent in Swift — `Perfect-PCRE2` is dead since 2021, `hyperscan-Swift` since 2018 and is x86-only with no capture groups). Presidio uses **zero** backreferences and only single-char negative lookbehinds, so the conversion cost is its 29 lookaheads. Not a day-one choice.

### (c) Encrypt/Decrypt byte compatibility

**The exact Python contract** (`aes_cipher.py`):

```
ciphertext_string = base64_urlsafe_WITH_PADDING(
    iv(16 random bytes) || AES-CBC-Encrypt(key, PKCS7-pad(utf8(plaintext), 16))
)
key = raw UTF-8 bytes of the user's string — NO KDF, NO hashing. Valid at 16/24/32 bytes.
decrypt: bytes[0..<16] is the IV, bytes[16...] is the ciphertext.
No MAC, no AEAD, no version prefix, no associated data.
```

**The trap: CryptoKit cannot do this and never will.** Apple deliberately omits AES-CBC and every unauthenticated mode. Reaching for CryptoKit dead-ends.

**The answer: `swift-crypto` ≥ 4.5.1, `CryptoExtras` module, `AES._CBC`.** AES-CBC landed in 3.1.0; 4.0.0 (2025-10-06) renamed `_CryptoExtras` → `CryptoExtras`; 4.5.1 (2026-07-16) explicitly backs AES-CBC with BoringSSL and constant-time PKCS#7 unpadding. Critically, `Sources/CryptoExtras/AES/AES_CBC.swift` routes unconditionally to `OpenSSLAESCBCImpl` with **no** Darwin/CryptoKit branch — so macOS, iOS, and Linux all execute the same BoringSSL code and produce identical bytes to Python's `cryptography`.

```swift
import Foundation
import Crypto
import CryptoExtras

public enum AESCipher {
    public static func isValidKeySize(_ key: Data) -> Bool { [16, 24, 32].contains(key.count) }

    public static func encrypt(key: Data, text: String) throws -> String {
        guard isValidKeySize(key) else { throw PresidioError.invalidParam("key") }
        var ivBytes = Data(count: 16)
        ivBytes.withUnsafeMutableBytes { _ = SystemRandomNumberGenerator().fill($0) }
        let iv = try AES._CBC.IV(ivBytes: ivBytes)
        let ct = try AES._CBC.encrypt(Data(text.utf8),
                                      using: SymmetricKey(data: key),
                                      iv: iv)                    // PKCS7 by default
        return Base64URL.encode(ivBytes + Data(ct))
    }

    public static func decrypt(key: Data, text: String) throws -> String {
        guard isValidKeySize(key) else { throw PresidioError.invalidParam("key") }
        let raw = try Base64URL.decode(text)
        guard raw.count > 16 else { throw PresidioError.invalidParam("ciphertext") }
        let iv = try AES._CBC.IV(ivBytes: raw.prefix(16))
        let pt = try AES._CBC.decrypt(raw.dropFirst(16),
                                      using: SymmetricKey(data: key), iv: iv)
        guard let s = String(data: Data(pt), encoding: .utf8) else {
            throw PresidioError.invalidParam("ciphertext")
        }
        return s
    }
}

/// Python's base64.urlsafe_b64encode uses the -/_ alphabet and RETAINS '=' padding.
/// Foundation's base64EncodedString() uses +/ . Transform, do not strip padding.
enum Base64URL {
    static func encode(_ d: Data) -> String {
        d.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }
    static func decode(_ s: String) throws -> Data {
        let std = s.replacingOccurrences(of: "-", with: "+")
                   .replacingOccurrences(of: "_", with: "/")
        guard let d = Data(base64Encoded: std) else {
            throw PresidioError.invalidParam("ciphertext")
        }
        return d
    }
}
```

**Also byte-critical, and easy to miss — the `Hash` operator.** Digest = `hexdigest(text.utf8 || salt)` — the salt is **appended**, not prepended. If no `salt` param is supplied, Presidio generates `os.urandom(32)` **per entity**, so hashing is non-deterministic and not round-trippable by default. `sha256` (default) or `sha512`; md5 removed; empty salt raises; salt < 16 bytes raises; `str` salts are UTF-8 encoded. Copy this exactly.

**Non-negotiable CI test:** a Python-side generator that emits known-answer vectors with a **fixed** IV, checked into the fixture corpus and verified from Swift on both macOS and Linux. Do not accept "it round-trips in Swift" as evidence.

`AES._CBC` still carries a leading underscore even inside the public `CryptoExtras` module — pin the `swift-crypto` version and wrap it behind your own `AESCipher` type so a rename is a one-file change. Reject `CommonCrypto` (Darwin-only), system OpenSSL (swift-crypto already vendors BoringSSL), and CryptoSwift (no AES-NI, single spare-time maintainer, non-OSI custom attribution license).

---

## 5. Conformance strategy

Five layers, in increasing cost and decreasing coverage.

### Layer 1 — Extracted JSON fixtures (proven, not hypothetical)

An AST extractor was **built and run** against the repo. Results:

- **1,626 normalized recognizer cases**, 84 files, **83 of 99 recognizer classes**, 959 positive / 667 negative, 100% recognizer+entity attribution, ~430 KB JSON.
- 90% collapse into 6 parametrize signatures (`ranges` 802, `iban` 330, `pos_only` 275, `len_only` 109, `single_pos_score` 60, `pos_score` 24); only 9 functions had shapes the pass couldn't handle. **One normalizer handles nearly everything.**
- Largest single table: `test_iban_recognizer.py::test_when_all_ibans_then_succeed` at 330 rows (~110 countries × valid-unspaced / valid-spaced / format-invalid / bad-checksum) — a complete IBAN conformance suite in one function.
- Plus ~103 anonymizer/operator cases, of which **14 integration expectations are already full-engine JSON strings** liftable verbatim.
- Plus 30 cleanly-parseable e2e request/response pairs, 27 YAML config fixtures under `presidio-analyzer/tests/conf/` (language-neutral, reuse as-is), and `data/context_sentences_tests.txt` (127 lines).

**Extraction gotchas the extractor must handle** (all identified):
- Fixture-graph indirection: `recognizer`/`entities`/`max_score` come from module-level and session `@pytest.fixture`s, not from the parametrize rows. Resolve statically.
- The string sentinel `"max"` appears in 44 numeric score-range tuples and is rewritten in the test body to `EntityRecognizer.MAX_SCORE` (= 1.0). Resolve at extraction time or you emit a type-heterogeneous score field.
- The assertion epsilon is `1e-5`, applied as `score >= max(0, min-1e-5) && score <= min(1, max+1e-5)`, after sorting results by `start`.
- 279 `pytest.raises` sites (143 with `match=` regexes against exact Python message strings) pin *error text*, not behavior. Drop them or rewrite as error-code assertions. Note many use unescaped `.` so they are looser than they read.

**Make the fixtures regenerable.** Pin an upstream Presidio commit, re-run the extractor, diff the corpus. This is how you track upstream releases instead of forking a snapshot.

### Layer 2 — Differential harness against Docker Presidio (the real oracle)

This is the technique that retires most of the accuracy risk, and it is also upstream's own recommendation for non-Python consumers.

```
corpus/*.txt  ──┬──> Swift PresidioAnalyzer ────> results_swift.json
                └──> ghcr.io/.../presidio-analyzer ──> results_python.json
                                    │
                          span-diff + per-entity P/R/F1
                                    │
                    CI artifact: fidelity_report.md (per entity type)
```

This converts "we think NER is close enough" into a published number that moves with every commit. It also gives customers with a hard bit-identical requirement a real answer: ship `PresidioRemoteAnalyzer` conforming to the same `Analyzer` protocol (~1 day of `URLSession` + `Codable`).

### Layer 3 — Property tests

- **Offset round-trip:** for every emitted span, `doc.substring(start, end)` must equal the matched text, and `scalarOffset(utf16Offset(x)) == x` for all `x`. Fuzz over emoji, combining marks, CJK, RTL — the upstream CLI fixtures already contain `hétérogénéité`, `お早う御座います。`, and Arabic with combining marks.
- **Anonymize invariants:** result items are in descending-start order; no item span exceeds the output length; `anonymize` on already-anonymized text is stable.
- **Regex lint:** every pattern in the corpus compiles, and none contains a forbidden construct.
- **Registry:** every identifier in `default_recognizers.yaml` resolves to a factory; no duplicate `RecognizerID`s.

### Layer 4 — Crypto known-answer vectors

Python-generated, fixed IV, checked in. Run on macOS **and** Linux.

### Layer 5 — HTTP conformance (reuse the e2e suite verbatim)

The e2e suite's base URLs are env-overridable (`ANALYZER_BASE_URL`, `ANONYMIZER_BASE_URL`, `IMAGE_REDACTOR_BASE_URL`), so all 52 tests can be pointed at a Swift server with **zero code changes**. Cheapest high-signal win available.

**But first, fix the oracle.** `e2e-tests/common/assertions.py:19-25` `_equal_lists_of_dicts` zip-truncates and discards its own nested-list recursion result. Verified empirically:

```python
equal_json_strings('[{"a":1}]',          '[{"a":1},{"b":99}]')  # -> True   (extra entity)
equal_json_strings('[{"a":1},{"b":2}]',  '[{"a":1}]')           # -> True   (missing entity)
```

**44 of 52 e2e tests rely on this.** A Swift server returning zero entities would pass. Replace it with a strict order-insensitive multiset comparator before trusting anything. (Worth reporting upstream regardless of the port.)

### CI shape

| Job | Runner | Contents |
|---|---|---|
| `unit-macos` | macOS + Xcode | All targets incl. `PresidioNLPApple`; fixture corpus; property tests |
| `unit-linux` | `swift:6.3` container | All targets minus Apple-only; verifies the `#if canImport` gating actually holds |
| `crypto-kat` | both | Python-generated fixed-IV vectors |
| `differential` | linux + docker-compose | Swift service vs `presidio-analyzer` container over the corpus; emits `fidelity_report.md` |
| `e2e-http` | linux + docker-compose | Upstream e2e suite, patched comparator, pointed at the Swift server |
| `regenerate-fixtures` | scheduled weekly | Re-run the extractor against upstream `main`; open a PR on diff |

The upstream `COVERAGE_THRESHOLD=90` diff-coverage gate has no direct Swift equivalent; substitute a fixture-coverage gate (percentage of the 1,626 cases that are green) — it is a better metric for this project anyway.

---

## 6. Phased roadmap

One experienced Swift engineer, full-time. Person-weeks (pw).

### Phase 0 — Foundations and fixture extraction — **2 pw**

SwiftPM skeleton and target graph. `PresidioCore` value types. The offset model and its property tests. The Python AST extractor (~600 LOC, already demonstrated) emitting versioned JSON. Pattern lint. `PythonRegex.escape` port + tests against CPython output.

**Ships:** the conformance corpus and the offset layer. No user-facing feature. Do not skip this; every later phase depends on the offset decision being right.

### Phase 1 — Deterministic core (the MVP) — **13 pw**

`PresidioRegex` ICU layer · `PatternRecognizer` · the 85 pattern/checksum recognizers driven from `Resources/recognizers/*.json` · IBAN with its custom `analyze` · `AnalyzerEngine` (all 11 steps) · thresholds · allow-lists · dedup algorithm #1 · **the entire anonymizer** including AES byte-compat and the from-the-end rewrite.

**Ships: a genuinely useful product.** ~60+ entity types (all regex/checksum entities: credit card, IBAN, crypto, IP, MAC, UUID, URL, email, plus all 68 country-specific entity types), full anonymize/deanonymize, **zero model download, zero network, fully offline, iOS-shippable, no OS availability floor.** This is not a toy configuration — Presidio itself ships `NoOpNlpEngine` and `slim.yaml` for exactly this shape.

Gate: ≥95% of the 1,626 extracted fixtures green; crypto KAT green on both platforms.

### Phase 2 — Apple NER — **5 pw**

`PresidioNLP` protocol + `NLPArtifacts` + label mapping/ignore/low-score pipeline · `NoOpNLPEngine` · `PresidioNLPApple` (`NLTokenizer` + `NLTagger(.nameType/.lemma)` + `tagHypotheses` for scores + `NLGazetteer` for NRP) · `NSDataDetectorRecognizer` for DATE_TIME/phone/email/URL/address · vendored stopword lists · `LemmaContextAwareEnhancer` · case-normalization pre-pass · given-names gazetteer.

**Ships:** PERSON / LOCATION / ORGANIZATION / DATE_TIME / NRP on Apple platforms — i.e. full default-entity coverage — plus the context-boost feature that all regex recognizers depend on. First point at which the differential harness produces a meaningful fidelity number.

### Phase 3 — Config, registry, REST, CLI — **6 pw**

Yams-backed YAML/JSON decoding · `RecognizerSpec` + factory registry · cross-field validation (the ~10 Pydantic rules must be hand-written) · language/country expansion · `PresidioServer` (Hummingbird + OpenAPI-generated from upstream's spec) · `presidio-cli` (swift-argument-parser) · `PresidioPhone`.

**Ships: v1.0.** Feature-complete against the deterministic half, YAML-configurable, deployable as a container (static musl binary for the analyzer/anonymizer), CLI-usable, and passing the patched upstream e2e HTTP suite.

**Cumulative: 26 pw ≈ 6 person-months.**

### Phase 4 — Transformer NER backend — **9 pw**

CoreML conversion pipeline (quantization sweep, `EnumeratedShapes`, ANE hints) · `swift-transformers` tokenizer integration · **subword→character offset alignment** (the highest-risk item) · BIO/BILOU decoding · all four aggregation strategies · stride windowing · chunkers · optional ONNX backend for Linux parity.

**Ships:** an accuracy tier that *exceeds* spaCy `en_core_web_lg` (~91 vs ~85 F1 CoNLL-03), at 110–215 MB, behind the same protocol.

### Phase 5 — Structured + image redaction — **8 pw**

`TabularSource` protocol + TabularData/CSV backends + the 3 selection strategies · `BboxProcessor` port · OCR protocol + Vision backend · span→bbox mapping (rewrite the shared-iterator loop as an index cursor) · redaction draw path.

**Ships:** presidio-structured and non-DICOM image redaction.

**Cumulative excluding DICOM: 43 pw ≈ 10 person-months.**

### Deferred — DICOM — **10 pw, do not schedule**

See §8.

---

## 7. Effort summary

### Swift LOC

Two estimates, because they encode different designs. State which you are budgeting.

| Target | Literal-transliteration (sub-agent sum) | Data-driven design (recommended) |
|---|---:|---:|
| PresidioCore | — | 900 |
| PresidioRegex | — | 700 |
| PresidioAnalyzer | 5,500 | 2,800 |
| PresidioRecognizers | **14,000** | **7,300** (≈4,000 JSON pattern/context data + 2,500 validators + 800 glue) |
| PresidioNLP + Apple backend | 3,200 | 1,700 |
| PresidioNLPCoreML | (in above) | 1,600 |
| PresidioAnonymizer | 3,200 | 2,200 |
| PresidioConfig | (in Analyzer) | 2,000 |
| PresidioPhone | — | 300 |
| PresidioServer + CLI | (in 6,500) | 1,300 |
| PresidioStructured | (in 6,500) | 900 |
| PresidioImage (non-DICOM) | (in 6,500) | 1,600 |
| Conformance harness + tests | 3,000 | 3,500 |
| **Total** | **~35,400** (≈34,400 after removing ~1,000 LOC of double-counting) | **~26,800** |

Plus ~430 KB of fixture JSON and ~600 LOC of Python extractor (not Swift, not maintained after Phase 0 except for regeneration).

**Why the two differ:** the entire gap is `PresidioRecognizers`. The 14,000 figure assumes one Swift type per Python class (99 types). The 7,300 figure collapses 85 of them into one `PatternRecognizer` struct parameterized by JSON data plus 55 free validator functions. The data-driven design is strongly recommended not for LOC but because **it is what makes upstream tracking possible** — regenerating `Resources/recognizers/*.json` from a new Presidio release is a script; regenerating 85 hand-written Swift types is not. Both `pii-vault` (Rust/TS) and `clipscrub-core` (Swift) converged on this independently.

### Person-months

| Scope | pw | person-months | Calendar with 2 engineers |
|---|---:|---:|---|
| **v1.0** (Phases 0–3: full deterministic parity + Apple NER + config + REST + CLI) | 26 | **6** | ~3.5–4 months |
| **Full minus DICOM** (+ Phases 4–5) | 43 | **10** | ~6 months |
| Sub-agent raw sum (all subsystems, incl. DICOM) | 58 | 13.5 | — |
| DICOM alone (deferred) | 10 | 2.3 | — |

### Assumptions

1. One experienced Swift engineer per pw, comfortable with Foundation, `NSRegularExpression`, Swift 6 concurrency, and SwiftPM. **Not** assumed familiar with Presidio — ~2 pw of Phase 0/1 is ramp.
2. Python source is available and readable throughout. No reverse-engineering.
3. **Parallelizes unevenly.** `PresidioRecognizers` is embarrassingly parallel across engineers (85 independent units with independent fixtures). `AnalyzerEngine`, `AnonymizerEngine`, and the offset layer are serial and single-owner. Two engineers give ~1.6× on v1.0, not 2×.
4. Estimates are for **"conformance-tested against the fixture corpus,"** not "compiles."
5. Excludes: DICOM, Stanza, LangExtract/LLM recognizers, AHDS surrogate, matplotlib overlay.
6. Excludes: production ops, deployment automation, documentation site, notebook/sample rewrites (~19 notebooks + 43 Python samples in upstream docs do not survive; budget separately if you need them).
7. Includes: the conformance harness, the differential CI job, and the fixture extractor.
8. Assumes ICU is chosen for regex. Swift Regex would add ~4 pw of mechanical migration (19 lookbehind rewrites + `.wordBoundaryKind(.simple)` on every pattern + the IBAN nested-quantifier rewrite) and cost ~30× throughput. Do not.

---

## 8. What NOT to port

| Item | LOC | Why |
|---|---:|---|
| **DICOM redactor + verify engine** | 1,439 | No usable Swift/ObjC DICOM library exists. `DcmSwift` (the best): 15★, last push 2022-11-08, Swift 5.3, self-disclaimed as "partial, work in progress" and "not a medical imaging nor diagnosis oriented library," no documented pixel-data or compressed-transfer-syntax support. Newest alternatives are 2–6★ and weeks old. Remaining paths are vendoring DCMTK C++ (doubles the build matrix, needs a hand-written shim, XCFramework on Darwin + distro packages on Linux) or writing a Part-10 parser (~1.5–2.5k LOC, tractable for *uncompressed* pixel data only). Also: the Python implementation harvests PHI by matching **human-readable DICOM element display names** (`"name" in element.name.lower()`), so parity requires shipping a matching data dictionary. A mis-parsed private tag is a PHI leak, not a bug. **Ship without it; expose the ad-hoc deny-list mechanism it was built on so a downstream medical user can supply their own reader.** |
| **`StanzaNlpEngine`** | 517 | ~370 lines are vendored `spacy-stanza` glue (Doc conversion, word/space realignment, `char_span` attachment). Needs the Stanza neural pipeline. Zero portability, zero users you care about. |
| **LangExtract / LLM recognizers + `llm_utils/`** | ~1,100 | `langextract` + `openai` + Jinja2 prompt templating + Azure credential chains. If you want LLM extraction, write a small `URLSession` client against the `LMRecognizer` post-filter pipeline (which *is* worth porting — it's ~30 lines of filters) rather than porting the LangExtract plumbing. Note the hard-coded alignment→confidence constants (`MATCH_EXACT 0.95 / FUZZY 0.80 / LESSER 0.70 / NOT_ALIGNED 0.60`) if you do. |
| **AHDS surrogate operator + Azure Health Deid recognizer** | ~600 | Preview Azure SDK (`api_version 2025-07-15-preview`), 130-entry entity mapping table, network-calling operator, import-gated so `get_anonymizers()` returns 7 or 8 names depending on pip extras. Isolate as an optional target or drop. |
| **`presidio` metapackage** | 1 | Literally one docstring line; exists so `pip install presidio` pulls two wheels. SwiftPM umbrella targets solve this differently. |
| **`pypng`, `click`** | 0 | Declared in `pyproject.toml`, imported **nowhere** (grep-verified). The CLI uses argparse. Do not carry them forward. |
| **matplotlib verification overlay** (`add_custom_bboxes`, `fig2img`) | ~130 | Rasterizes a matplotlib `Figure` sized `pixels/70` inches, saves to BytesIO, reopens as PIL, resizes back — including matplotlib's default fonts, DPI, axes, and `boxstyle="round4"`. Byte or even visual parity with Core Graphics is unattainable. It is a debug/eval tool. |
| **`n_process` multiprocessing knob** | — | Forks spaCy workers. `TaskGroup` is the Swift analogue but the semantics don't map; expose concurrency differently. |
| **Pydantic `extra='allow'` pass-through** | — | Arbitrary unvalidated YAML keys flowing into constructors cannot be reproduced by `Codable`. Make it explicit (`spec.extra` + a strictness flag) and document the divergence. |
| **`__subclasses__()` + `inspect.signature` kwarg reshaping** | 833 | Replaced by the factory table. Accept that YAML configs relying on signature-introspection quirks (plural→singular renaming only when the singular is accepted and the plural isn't; different key-drop policies for `predefined` vs `custom`) will behave differently. |
| **`SpacyRecognizer.CHECK_LABEL_GROUPS`** | ~15 | Deprecated dead code upstream. |
| **`to_dict()` returning `self.__dict__`** | — | Reflective serialization of live internal state, in three places. Use `Codable` with hand-pinned `CodingKeys` matching the wire format. |
| **Byte-equality image golden test** | — | `assert response.content == expected_result_image.read()` against a checked-in PNG. Any OCR or encoder change fails it. Replace with the existing 95%-pixel-similarity oracle, or drop image parity testing entirely. |
| **`TokenizerBasedTextChunker`** | ~160 | Requires an HF *fast* tokenizer with `return_offsets_mapping`. Only needed on the transformer path, and you're writing the offset alignment yourself anyway. |

### Bugs to deliberately *not* reproduce

- `presidio-cli` always exits 0 (`show_problems` returns an always-zero `max_level`) — makes it useless as a CI gate.
- `presidio-cli` config validates `self.threshold` (still the default 0) instead of the parsed YAML value before assigning it, so out-of-range thresholds are silently accepted from files.
- `equal_json_strings` zip-truncation (§5).
- `EntityRecognizer` declares `@abstractmethod` on a class that is not an `ABC`, so it is directly instantiable and `load()`/`analyze()` silently return `None`.

### Bugs requiring a *conscious* decision

- `us_driver_license_recognizer.py:30` contains a stray `A-Z]{2}[0-9]{2,5}` alternative missing its opening bracket. Reproduce bug-for-bug or fix deliberately — it changes recall.
- `kr_frn_recognizer.py` is tagged `supported_language="kr"` while the other four Korean recognizers use `"ko"`. It will never be selected for a `ko` request.
- `analyze_dict` passes only the immediate key as context for scalars but the accumulated `specific_context` path for dicts/lists — a real inconsistency.
- Three reported values for `deny_list_score` (see §10).

---

## 9. Risks

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| 1 | **NER quality regression is user-visible** — missed PERSON entities are what users judge the product on; NLTagger returns **zero** entities on lowercase input | High | High | Layered `NerProvider`; case-normalization pre-pass; given-names gazetteer; CoreML tier for accuracy-critical work; **publish a per-entity fidelity table from the differential harness and never claim parity** |
| 2 | **Offset model chosen wrong** — Python scalar vs Swift grapheme vs ICU UTF-16; silently wrong spans leak PII | Medium | Critical | Decide in Phase 0. `TextDocument` with explicit conversion tables + all-BMP fast path. Property test that every emitted span's substring round-trips. Fuzz with the upstream emoji/Hebrew/Arabic/CJK fixtures |
| 3 | **Subword→character alignment bugs** on the transformer path — `swift-transformers` has **no** offset API (grep-confirmed) | High (if Phase 4 is taken) | High | Reconstruct alignment via a cursor re-matching normalized subwords against the source; assert the round-trip invariant on every span; property-test over Unicode-heavy corpora; treat this as ~40% of Phase 4's budget, not 10% |
| 4 | **ReDoS** — ICU is a backtracker and there is no timeout equivalent; a PII scanner processes untrusted text | Medium | High | Fix the 3 hot patterns first (one is 47% of runtime); digit-presence SIMD prefilter; `enumerateMatches` deadline (catches many-matches, **not** single catastrophic backtracks — say so); input length caps; offline ReDoS analysis in CI. Note ICU is materially *more* robust than Swift Regex here (10 ms vs >120 s hang on Presidio's own IBAN pattern) |
| 5 | **Tie-break divergence makes conformance noisy** — Python ordering is `set`-derived and nondeterministic | High | Medium | Define a total order in Swift (add `entityType` as final tiebreak); normalize **both** sides before comparison; do not chase bit-exact golden files |
| 6 | **Config-layer divergence** — `extra='allow'`, signature introspection, `CONFIG_MODEL_MAP` dispatch, union-coercion order | Medium | Medium | Explicit `acceptedKeys` metadata per factory; strictness flag; reuse the 27 upstream YAML fixtures as the conformance corpus for the config loader specifically |
| 7 | **Crypto byte-incompatibility discovered late** | Low | High | Python-generated fixed-IV KAT vectors in CI from Phase 1 day one, on macOS **and** Linux. Do not accept Swift-only round-trip as evidence |
| 8 | **`PhoneNumberKit` behavioral drift** — explicitly *not* a libphonenumber port | Medium | Medium | Differential-test the phone recognizer specifically against Python `phonenumbers` over a region-stratified corpus; the 3 ZA classes need `PhoneNumberType` verification |
| 9 | **Linux build silently loses features** — `NaturalLanguage`, `NSDataDetector`, `Vision`, `TabularData`, `CoreML` are all Apple-only; `NSDataDetector` is **not** in swift-corelibs-foundation | Medium | Medium | Gate every Apple framework behind a protocol from commit one; a dedicated `unit-linux` CI job that proves the `#if canImport` boundaries hold. Retrofitting this later is painful; doing it upfront is free |
| 10 | **Effort underestimated on `PresidioRecognizers`** — 85 recognizers × extract + validator + fixtures | Medium | Medium | It parallelizes perfectly. Track burn-down against the 1,626-case fixture corpus, which gives a real percentage-complete rather than a feeling |
| 11 | **Upstream drift** — Presidio ships releases; a snapshot fork rots | High | Medium | Data-driven recognizer design + regenerable fixtures + a weekly CI job that re-extracts from upstream `main` and opens a PR on diff |
| 12 | **PSL staleness** (vendored `tldextract` substitute) | Medium | Low | Snapshot + a scheduled refresh job; the email validator only checks `fqdn != ""`, so drift is low-consequence |
| 13 | **`swift-crypto` renames `AES._CBC`** (still underscored in a public module) | Low | Low | Pin the version; wrap behind your own `AESCipher` so a rename is a one-file change |
| 14 | **Model size blocks App Store distribution** — the published fp32 CoreML bert-base-NER is **1,329 MB**; cellular download cap is 200 MB | Medium | Medium | Quantize (fp16 ~215 MB / int8 ~110 MB / int4 ~55–70 MB); ship the Apple-NER tier in-bundle and the transformer via Background Assets/ODR (8 GB per pack, 70 GB hosted on iOS 18+); never gate functionality on the download |
| 15 | **Overclaiming compatibility** — reputational, and the easiest mistake to make | Medium | High | "Presidio-compatible, not Presidio-identical." Ship the fidelity table with the README. Do not use the Presidio name in the product name (MIT grants no trademark rights) |

---

## 10. Where the evidence conflicts or is unverified

Read this before writing code. These are places where the sub-agent analyses disagreed, or where a claim was flagged as unverified.

1. **`deny_list_score` default — three different values reported.** The core-engine analysis quotes the constructor signature as `deny_list_score: float = 1.0` and separately notes "default 1.0 in code, but the Pydantic YAML default is 0.0 (`yaml_recognizer_models.py:367-369`), a genuine inconsistency." The predefined-recognizers analysis quotes the *same* signature as `deny_list_score=0.3`. **Resolve by reading `pattern_recognizer.py:59` and `yaml_recognizer_models.py:367` directly before porting.** This value directly determines whether every deny-list match survives thresholding.

2. **Lookbehind count: 19 or 20.** The regex census reports 19 patterns containing negative lookbehind; the research narrative says "all 20 of its lookbehinds." Reconcilable as 19 *patterns* / 20 *occurrences* (one pattern carries two), but confirm before writing the migration lint. Materially irrelevant to the ICU recommendation.

3. **SE-0448 (Swift Regex lookbehind) status.** Accepted, but the implementation PR (`swift-experimental-string-processing#760`) was still an open draft as of 2026-01-30, "despite secondary sources claiming it landed in Swift 6.2." The ICU recommendation is robust either way — do not re-evaluate on a rumor.

4. **NLTagger language coverage was flagged unverified, then resolved.** The NLP analysis said the `.lemma`/`.nameType` language sets "must be probed at runtime… Apple does not publish a stable list" and speculated ~11 languages for `nameType`. The later ecosystem research **empirically probed 33 languages** and found `nameType` = **8** (en, es, fr, de, it, pt, ru, tr) and `lemma` = **10** (+nl, sv). Use the probed numbers; re-probe on your minimum deployment target since availability is OS-version-dependent.

5. **`swift-transformers` offset mapping was flagged as "the single highest-risk unknown," then resolved negatively.** Grep-confirmed: the `Tokenizer` protocol exposes only `tokenize`/`encode`/`decode`; there is **no** offsets/`NSRange`/`Range<String.Index>` API anywhere, and **no** token-classification pipeline (zero hits for `TokenClassification`). This is now a known cost, not an unknown.

6. **The NLP subsystem's own effort numbers are internally inconsistent.** It reports 11 pw for the subsystem, while its rationale says "a regex-only + Apple-NER Swift port is a few weeks. Parity with the transformers engine is a quarter" (~13 weeks). The roadmap in §6 splits these (Phase 2 = 5 pw Apple, Phase 4 = 9 pw transformer) rather than adopting either figure.

7. **Double-counting in the LOC totals.** `predefined_recognizers/ner/` (777 LOC) and `predefined_recognizers/nlp_engine_recognizers/` (206 LOC) are counted in **both** the predefined-recognizers subsystem (11,268) and the NLP subsystem (2,896). De-duplicated production Python is ~26,977, not 27,960. The Swift totals in §7 are similarly overlapped in the sub-agent column.

8. **Recognizer module count: 99 vs 123.** The core-engine analysis says "~123 predefined recognizer modules"; the predefined-recognizers analysis counted "99 non-`__init__` .py files" and 99 recognizer classes (102 classes minus 3 LLM provider adapters). 123 presumably includes `__init__.py` files across subdirectories. **Use 99 recognizer classes / 87 entity types / 161 `Pattern()` declarations.**

9. **`PatternRecognizer.__analyze_patterns` line references differ slightly** between the two analyses (`:193-281` vs `:196-290`), suggesting they read marginally different revisions. Immaterial, but re-read against your pinned commit.

10. **Unverified, flagged for follow-up before Phase 4:** (a) whether `NLTagger.tagHypotheses` returns probabilities calibrated enough to substitute for transformer softmax scores in Presidio's thresholding; (b) the current ONNX Runtime SwiftPM/xcframework packaging story and its Linux-from-Swift ergonomics (the SPM package tags lag badly — latest `v1.19.2` vs upstream 1.24.x, and it ships Apple-only xcframeworks so Linux requires hand-rolled C interop); (c) exact spaCy `STOP_WORDS` list sizes per language (spaCy was not installed in the analysis environment).

11. **Not measured anywhere:** there is **no** in-repo benchmark or F1 evaluation dataset. All accuracy benchmarking lives in the external `presidio-research` repo (18 doc references, zero data in-tree). `docs/evaluation/` contains exactly one 3.8 KB markdown file. **The port gets correctness fixtures from this repo but no accuracy baseline** — the differential harness (§5, Layer 2) is the only way to produce one.