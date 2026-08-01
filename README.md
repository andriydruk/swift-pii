# swift-pii

A Presidio-compatible PII detection and anonymization library in pure Swift.

**Status: M1–M5 complete.**
Detection (99.5% of the harvested corpus), de-identification including reversible
AES, spaCy-exact tokenization, NER from raw text, and the end-to-end
`AnalyzerEngine` (99.8% across an option matrix) are all differentially verified
against Python. NER parity is 98.9%, not exact — see below.

Not affiliated with or endorsed by the Presidio project. "Presidio-compatible"
describes the behavioural target. The package is deliberately not named after
Presidio — MIT grants no trademark rights, and a `swift-presidio` would read as
the official Swift port. Module names keep the `Presidio` prefix because there
they describe what the code is compatible with.

```swift
.package(url: "https://github.com/andriydruk/swift-pii.git", from: "0.1.0")
```

## Why this exists

[Presidio](https://github.com/data-privacy-stack/presidio) is Python, and its
detection quality depends on spaCy. This package reproduces its behaviour in
Swift without any Apple closed-source framework, so the same code runs on
macOS, Android, and Windows.

## Design commitments

**Unicode scalar offsets are the wire contract.** Python indexes strings by
scalar; `NSRegularExpression` reports UTF-16; Swift `String` is grapheme-indexed.
Conflating them produces silently wrong spans — a PII-leak class of bug.
[`TextDocument`](Sources/PresidioCore/TextDocument.swift) owns every conversion
and nothing else does index arithmetic on a `String`.

**No Apple closed-source frameworks.** `NaturalLanguage`, `CoreML`, `Vision`,
`CryptoKit`, `Accelerate` and friends are banned and enforced by
[`Tools/check_portability.sh`](Tools/check_portability.sh) in CI. `PresidioCore`
goes further and imports no Foundation at all.

**Tests are harvested, not written.** Presidio ships 215 test files and ~3,763
concrete cases. The recognizer tables are pure data, so
[`Tools/extract_fixtures.py`](Tools/extract_fixtures.py) lifts them into
language-neutral JSON that Swift tests consume directly. Correctness is measured
against upstream's own expectations rather than fixtures we invented.

**Ordering is deterministic here, unlike upstream.** Presidio's result order
derives from Python `set` iteration and a sort key that omits `entity_type`, so
ties vary with `PYTHONHASHSEED`. This package defines an explicit total order —
score desc, start asc, length desc, entity type asc — and documents it as the
contract. Bit-exact ordering parity with Python is not achievable; reproducible
ordering is.

## Conformance corpus

Regenerate from a Presidio checkout:

```bash
python3 Tools/extract_fixtures.py --presidio /path/to/presidio --out Tests/PresidioConformance/Fixtures/recognizer_cases.json
```

Current corpus:

| Corpus | Tables | Cases | Recognizers |
|---|---:|---:|---:|
| `recognizer_cases.json` | 101 | 1,654 (987 pos / 667 neg) | 83 |
| `validator_cases.json` | 21 | 203 | 21 |

50 upstream tables are not extractable (non-literal argvalues, mock-dependent,
or shapes the parser doesn't handle). They are **recorded in the artifact** under
`skipped` with reasons — coverage you can't see is coverage you don't have.
Those need the differential Python side-car planned for M1.

Two upstream subtleties the extractor handles, both of which would otherwise
corrupt the corpus:

- **`expected_len` is authoritative, positions are not.** The Python assertion
  is `zip(results, expected_positions)`, which stops at `results`. A row like
  `("123456789012", 0, (0, 12), 0)` asserts that *nothing* is found — the
  `(0, 12)` is vestigial. Carrying it through would invert a negative test into
  a positive one.
- **Tables with no score column may still pin an exact score.** Their assertion
  calls `assert_result(..., max_score)`. Defaulting those to a 0.0–1.0 range
  would silently accept a wrong score — including all 330 IBAN cases.

## Regex backend

Settled in [ADR 0001](docs/decisions/0001-regex-backend.md) with a
1,112,064-codepoint differential against Python's `regex` module:

| Backend | `\w` extra / missing | `\d` extra |
|---|---|---:|
| NSRegularExpression (ICU) | 4,773 / **0** | 10 |
| Swift Regex (default) | 5,622 / **1,147** | **1,263** |
| Swift Regex (`.unicodeScalar`) | 4,697 / **1,897** | **1,263** |

Swift Regex is disqualified: it drops 1,093 combining marks and both
ZWJ/ZWNJ from `\w` (so `\b` breaks around accented text), and treats
superscripts, fractions and Roman numerals as digits — which is why
`\b\d{6,14}\b` would match `①②③④⑤⑥⑦⑧⑨⑩`.

ICU's `\w` *definition* matches Python's; its entire divergence is Unicode
**data-version** skew — every sampled extra is unassigned in Unicode 13.0.0 and
assigned in macOS 26's newer ICU. That disqualifies it rather than vindicating
it: the host ICU version differs across Android, macOS and Windows, so `\b`
would behave differently per platform.

So the tables are generated from `regex` and compiled in as source
([`UnicodeTables.swift`](Sources/PresidioRegex/UnicodeTables.swift), 796 + 71 + 10
ranges), pinning the Unicode version as reviewable data. A test asserts
membership matches Python for all 1.1M codepoints.

### Differential result

All 155 patterns × 1,550 corpus texts = **240,250 comparisons, 5,996 matches,
zero divergences** from Python — same count, same offsets, same order. Absence
of a match is asserted as strongly as presence.

Cost of the trade, measured on that same workload (release, M4 Max):

| | full 155-pattern sweep | |
|---|---:|---|
| Python `regex` (C, single-threaded) | 0.093 s | |
| this engine, single-threaded | 0.406 s | 4.4× slower |
| this engine, 14 cores | **0.055 s** | **1.7× faster** |

`PureRegex` and `PatternRecognizer` are `Sendable` — plain, not `@unchecked` —
so one compiled pattern can be shared across tasks. All match state lives in a
per-call VM. Scanning 155 independent patterns is embarrassingly parallel, which
makes concurrency worth an order of magnitude more than micro-optimization:
7.3× on 14 cores, verified to produce identical results under concurrent load.

We are slower than the implementation we are replacing. That is acceptable while
correctness is the gate — compilation is only 0.15 ms/pattern, and the absolute
numbers are small. See the ADR for the optimization plan.

Matching runs on a bytecode VM with a heap-allocated backtrack stack, not
recursion. The predecessor's depth grew with the *input*: `a+` crashed at ~2–4k
characters even on the main thread's 8 MB stack, and at ~400 characters on the
512 KB stacks Swift concurrency hands out — a crash-on-ordinary-input defect for
any caller using a `Task`. It now handles 500,000 characters on 8 MB and 100,000
on 512 KB, while being ~20% faster.

The start-position prefilter is a precomputed bitmap rather than an AST-derived
closure — it runs at every position for every pattern, so it is the hottest code
in the package. Worth 12% on its own.

A single-pass dispatch across all patterns was tried and **rejected on
measurement**: it was byte-identical but 7% slower, because an average corpus
character wakes 71.6 of the 155 patterns (digits wake 93). PII patterns are
dominated by digit and letter classes, so there is no dispatch win to be had.
Recorded in the ADR so it is not retried.

## The engine

```swift
let engine = try AnalyzerEngine.makeDefault()
let results = try engine.analyze(text: "my card is 4095-2609-9393-4932")
```

`AnalyzerEngine` runs the recognizers, raises scores from surrounding context,
applies per-recognizer and per-entity thresholds, deduplicates, and applies
allow lists. Verified against Presidio's own engine over **900 texts × 7 option
sets — 6,289/6,300 runs agree exactly** (99.8%).

The comparison injects **Python's NLP artifacts** rather than running our own
pipeline. That is the point: otherwise a divergence in the engine and one in the
NER model are indistinguishable, and the failure that actually matters — an
engine bug masked by a compensating NER difference — would never show up. The 11
remaining divergences are all a missing `PHONE_NUMBER` across two texts, the
phone matcher's own measured gap; nothing else diverges and there are no false
positives, both of which the test asserts separately from the ratchet.

### A default engine loads 17 recognizers, not 88

`AnalyzerEngine()` does not load the whole catalogue. Upstream ships
`conf/default_recognizers.yaml` and most country-specific entries carry
`enabled: false`. Loading everything instead is not a more thorough version of
Presidio — it reports entities Presidio never would, which reads as a wall of
false positives. The resolved configuration is extracted to JSON by
[`Tools/extract_registry_config.py`](Tools/extract_registry_config.py), so
reproducing the defaults needs no YAML parser. Reading a *user's* YAML at
runtime is not implemented.

Pass `configuration: nil` to load everything explicitly.

### The lemmatizer, and why there isn't one

Upstream's context enhancer compares spaCy **lemmas**, which need POS tags,
which need the tagger — a whole extra model component plus WordNet-derived
tables. Whether that is worth porting is measurable, so it was measured:
replacing lemmas with lowercased token text, over 3,241 texts in which the
enhancer fired 177 times, changed **nothing** — 3,241/3,241 identical results.

That is structural rather than lucky. Context matching is *substring* by
default, and English lemmatization is nearly always a suffix strip, so the
recognizer's context word is a substring of the inflected form either way
(`card` matches both `card` and `cards`).

It stops holding in `whole_word` mode, where the same corpus gives 2
divergences — `MACs` lemmatizes to `mac`, which matches the context word
exactly, while the lowercased token does not. So lemmatization is a protocol
(`Lemmatizing`) with a default that is honest about what it does, and a real
lemmatizer can be dropped in without touching the enhancer.

## Concurrency

Every public type is `Sendable`, and an `AnalyzerEngine` is meant to be built
once and shared. Where `@unchecked Sendable` appears it is because the type was
*audited*, and the justification is written at the declaration:

- `SpacyTokenizer` memoizes span splits — worth 4.3× on repeated text, so the
  cache stays and is guarded by a lock. Its three derived special-case tables
  used to be `lazy var`, whose initialization is itself a race on a shared
  instance; they are now built eagerly in `init`.
- `NERModel`'s weights are `var` only because the msgpack decode assigns them
  in a loop. They are written during `init` and read-only afterwards, and
  inference allocates its scratch per call.

ThreadSanitizer cannot load on this project's macOS dev host (Xcode's sanitizer
dylib fails the platform code-signature policy), so the race check runs as its
own **Linux CI job**.

That job was then checked against a branch with the lock deliberately removed —
and the first version of it **passed**, because the test warmed the tokenizer
cache serially before the concurrent phase, so the tasks only ever read it. The
test now gives every task text no other task has seen, and on the same broken
branch TSan reports `Swift access race` in `SpacyTokenizer.emit`. A sanitizer
job that has only ever seen correct code is not evidence. See
[ADR 0002](docs/decisions/0002-concurrency.md).

## Diagnostics

Every bundled resource loads through `Bundle.module` into an optional, and every
consumer of a failed load degrades *quietly* — a validator with no table returns
`.invalid` for everything, which is indistinguishable from "nothing matched".
That has already caused one real bug here, where a single missing key disabled
five recognizers with no error anywhere.

```swift
print(Diagnostics.report())
// ok   PresidioRecognizers/recognizers.json: 88 definitions, 88 with patterns
// ok   PresidioEngine/registry_config.json: 17 English recognizers enabled, flags 26
// ...
```

Each of the nine checks probes decoded **content**, not file presence — a
truncated or schema-drifted file passes an existence check and fails here.

## Performance

Measured on the engine's real workload: 200 documents (~390 bytes each) through
all 17 default recognizers, release build, M-series.

| | per document |
|---|---:|
| `analyze` | **3.3 ms** |
| engine construction | 20 ms — build once, share it |

`PhoneRecognizer` is **69%** of that, and the reason is structural rather than a
defect: it scans the whole text once per configured region, so the region list is
the biggest lever a caller has.

| regions | cost over the same corpus |
|---|---:|
| 8 (default) | 441 ms |
| 2 | 125 ms |
| 1 | 70 ms |

```swift
PhoneRecognizer(regions: ["US"])   // ~6x cheaper than the default eight
```

The M5 pass made the engine **1.8× faster** (6.1 → 3.3 ms/document) by fixing one
thing: the phone matcher re-sliced the entire remaining text on every iteration
*and* computed every remaining match only to take `.first`. `PureRegex` gained
`firstMatch(inScalars:from:)`, which stops at the first hit and scans from an
offset. The full test suite got 40% faster as a side effect.

## Conformance status

Against the 1,654-case corpus harvested from Presidio's own tests:

| | cases | |
|---|---:|---|
| **Verified green** | **1,646** | 99.5% — every case passes, spans and scores |
| Blocked on validators | **0** | — |
| Known-divergent | 8 | 0.5% — the phone leniency table, below |

Every recognizer in the corpus now runs, and **53 validators** cover every one
whose patterns can be lifted into data. The blocked count is a test-enforced
hard zero, not a ratchet.

Three recognizers declare no `PATTERNS` at all — they delegate to
libphonenumber — so they are driven through a custom-recognizer path rather
than the catalogue:

| Recognizer | cases | Agreement |
|---|---:|---|
| `PhoneRecognizer` | 106 | 98/106 — see below |
| `ZaMobileNumberRecognizer` | 14 | 14/14, spans included |
| `ZaTelephoneNumberRecognizer` | 14 | 14/14, spans included |

`UsMbiRecognizer` and `UrlRecognizer` were in this table until the extractor
learned to fold f-strings and `+` over class-level string constants. Their
patterns were always liftable — they were simply not spelled as literals.

### The libphonenumber recognizers

`PhoneRecognizer` has no patterns of its own: it delegates entirely to
`phonenumbers`, so parity means porting Google's algorithm. There was no
shortcut — **PhoneNumberKit has no text-scanning API**, only parse/format/
validate, so it cannot supply `PhoneNumberMatcher`, which is the part the
recognizer is built on.

Both halves are now ported, against metadata extracted for the 39 regions
sharing the twelve configured country codes
([`Tools/extract_phone_metadata.py`](Tools/extract_phone_metadata.py), 121 KB).

**Parse and validation**, over 480 differential cases:

| | agreement |
|---|---:|
| parse / reject | 479/480 (99.8%) |
| national number | 416/432 (96.3%) |
| validity | 431/432 (99.8%) |
| region resolution | 430/432 (99.5%) |

**The matcher**, over 624 differential cases across 12 regions and 2 leniencies:

| | agreement |
|---|---:|
| exact per-case | 601/624 (96.3%) |
| span recall | 394/407 (96.8%) |

**The recognizer**, over its own 106 harvested corpus cases: **98/106 (92.5%)**.
The two South African line-type recognizers reuse the same matcher and split its
results by `number_type`: **28/28, spans included**. Their prefix fallback is
only consulted when the metadata cannot type a number, and its rule order
matters — 086 and 087 are sharecall and VoIP lines that the bare "starts with 8"
rule would call mobile.

Three semantics were worth getting right, each of which silently changes results:

- `region_code_for_number` returns a **single-region country code
  unconditionally**, without validating. Only a shared code (+1, +44) is
  disambiguated — which is why the metadata covers 39 regions, not 13.
- `national_significant_number` **keeps leading zeros**, and that is what
  validation matches. `"020 7946 0958"` parsed as US is an eleven-digit number
  matching nothing; dropping the zero makes a British number look like a valid
  US one.
- `_is_national_prefix_present_if_required` rejects a nationally-formatted
  number missing its prefix — this is what makes a Philippine mobile invalid
  without its leading `0`.

Known gaps: `STRICT_GROUPING` and `EXACT_GROUPING` leniency fall back to
`VALID` (more permissive), and the 8 remaining corpus failures are the leniency
table, whose expected count varies with a per-row `leniency` column the corpus
does not carry.

### Bulk data

Five recognizers needed data rather than arithmetic, extracted by
[`Tools/extract_recognizer_data.py`](Tools/extract_recognizer_data.py): the
Public Suffix List (10,239 rules) for `EmailRecognizer`, India's RTO district
tables for vehicle registrations, Singapore's UEN alphabets, South Africa's
legacy company prefixes, and base58/bech32 plus SHA-256 for `CryptoRecognizer`.

The PSL is punycoded at extraction time. It stores IDN suffixes in Unicode
(`рф`) while addresses carry them as A-labels (`xn--p1ai`), so 459 rules would
otherwise never match — and doing it in Python keeps IDNA out of the Swift
package entirely.

These validators fail *closed* when their data does not decode, which is
indistinguishable from "nothing validates". A test asserts the resource is
present, because one missing key once disabled all five silently.

### Behaviours that are easy to get wrong

Each was found by a conformance failure, and each silently changes detection:

- **Regex flags are per recognizer, not global.** The default is
  `DOTALL|MULTILINE|IGNORECASE`, but `IbanRecognizer` drops IGNORECASE
  (`iban_recognizer.py:77`). Applying the default produced 8 false positives.
- **IBAN country formats are prefix matches.**
  `self.BOSEOS = bos_eos if exact_match else ()` with `exact_match=False`, so
  the regex is never wrapped in `^...$`. Several country regexes are *shorter*
  than the IBAN they describe — MU covers 28 of 30 characters — so anchoring the
  end rejects the very IBANs upstream accepts.
- **The tri-state is load-bearing.** `.unknown` (Python `None`) keeps a match at
  its pattern score instead of dropping it. DE_VAT_ID relies on it because the
  BZSt never published its checksum; Korean RRN/FRN because the algorithm only
  applies to numbers issued before October 2020.
- **One class can have several constructions.** `DeVatIdRecognizer` appears as
  both `recognizer` (heuristic) and `strict_recognizer`, with opposite
  expectations for the same input. The corpus records which fixture built each
  table, and an unregistered variant is reported as uncovered rather than run
  against the wrong logic.
- **`ipaddress` is stricter than the regex.** The IPv4 pattern matches `010`,
  but CPython rejects leading zeros; IPv6 accepts a `%zone` suffix and IPv4 does
  not.

## Anonymizer

Detect-and-anonymize works end to end. The package is unusually portable —
2,457 LOC of pure string manipulation, one regex, no NLP — so this is a close
transliteration, and it keeps `PresidioAnonymizer` dependency-free including its
own SHA-2.

Upstream's anonymizer tests are imperative rather than table-driven, so there
was nothing to harvest. Instead `presidio_anonymizer` is driven directly as an
oracle ([`Tools/anonymizer_reference.py`](Tools/anonymizer_reference.py)): 43
scenarios covering every operator, conflict resolution, whitespace merging, span
edge cases and non-BMP offsets, recording the exact output text *and* the exact
operator-result spans. **All 43 match.** That pins behaviour upstream never
explicitly asserts.

Operators: `replace`, `redact`, `mask`, `hash`, `keep`, `custom`, `encrypt`,
and `keep`/`decrypt` on the deanonymize side.

### Encryption

`encrypt`/`decrypt` live in a **separate target**, `PresidioAnonymizerCrypto`,
so the anonymizer core stays dependency-free. swift-crypto vendors BoringSSL,
which does not build everywhere (WASM notably), and most callers do not need
reversible pseudonymization. A lint keeps the dependency confined.

`CryptoKit` cannot do this at all — its `AES` enum exposes only `GCM` and
`KeyWrap`, with no CBC mode — so this uses swift-crypto's
`_CryptoExtras.AES._CBC`, which is BoringSSL-backed on every platform including
Darwin.

"Byte-compatible" is the wrong bar for encryption: upstream calls
`os.urandom(16)` per invocation, so ciphertext is not reproducible even
Python-to-Python. Two things are testable and both are verified:

| | |
|---|---|
| **42 known-answer vectors** | IV pinned → ciphertext **byte-identical to Python**, across AES-128/192/256 and 14 plaintexts (empty, block-boundary, emoji, CJK, RTL) |
| **42 interop ciphertexts** | produced by real Presidio with its random IV → must decrypt to the original plaintext |

The known-answer vectors are also what pins swift-crypto's behaviour, which is
why `Package.resolved` is not committed: a version bump that changed AES-CBC
would fail these immediately.

Two encoding details that would otherwise bite: Python's URL-safe base64 uses
`-`/`_` where Foundation emits `+`/`/`, and `urlsafe_b64decode` silently
*discards* out-of-alphabet characters where `Data(base64Encoded:)` returns nil.
Both are reproduced, the latter so a ciphertext that picked up whitespace in
transit still decodes.

Two deviations from upstream, both intentional and both enforced by tests:

- **`hash` requires an explicit salt.** Upstream generates `os.urandom(32)` when
  none is given. This target has no portable random source, and silently
  substituting a fixed salt would turn an unreversible hash into a reversible
  one — so it errors instead.
- **Conflict resolution carries the score.** `PIIEntity` upstream has no score,
  but `_remove_conflicts` operates on `RecognizerResult` and decides identical
  spans by score. Dropping it made every equal-span pair annihilate.

The subtle part is that Python mutates entities **in place** during the merge
pass, so a later iteration observes an earlier widening. Reading from the
original input instead makes same-type overlaps vanish entirely.

## Tokenizer

spaCy's English tokenizer is entirely rule-based — four regexes plus a
special-case table — so it ports exactly rather than approximately. It runs on
`PureRegex`, not ICU, so token boundaries do not drift with the host's Unicode
version.

**63,453 tokens across 2,517 texts match spaCy exactly** — text, scalar offsets,
*and* NORM.

All three matter: boundaries decide what the NER model sees, offsets map spans
back onto the source, and NORM is consumed directly as an NER feature.

### NORM is not lowercase

Resolution order, determined empirically against spaCy rather than from docs:

1. If the token came from a tokenizer exception, that **exception piece's**
   NORM. This is per-(exception, piece), not per surface form — `gonna` splits
   into pieces carrying `going`/`to`, while a bare `a` elsewhere stays `a`.
   Getting this wrong cost 994 mismatches on a first attempt.
2. `lexeme_norm[exact surface form]` — keyed by the **exact** text, not
   lowercased. `licence`→`license`, but `PLZ` stays `plz` because only `plz` is
   a key.
3. `BASE_NORMS[exact]` — punctuation folding (backtick→apostrophe, em-dash→hyphen).
4. Otherwise lowercase.

The gold file must come from the **loaded model**, not `spacy.blank("en")`: a
blank pipeline ships no `lexeme_norm` table, so it leaves `licence` alone and
would wrongly fail a correct implementation.

## NER

`SpacyNER` runs spaCy's v3 pipeline in pure Swift: tokenizer → MultiHashEmbed →
Maxout → LayerNorm → 4 residual maxout-window blocks → transition-based parser
over BILUO actions. Weights are read straight from the model's thinc msgpack
files, so there is no conversion step and no ML runtime — the matmul is
hand-written SIMD.

Input is raw text; output is `NamedEntity` with **scalar character offsets**,
which is what a PII pipeline actually needs.

Model weights are **not bundled** (15 MB for `en_core_web_sm`, 619 MB for `lg`).
Point `SpacyNER(modelDirectory:)` at an unpacked model. The parity suite is
gated on `SPACY_MODEL_DIR` and reports when unset rather than passing vacuously.

### Parity is 98.9%, not exact

Measured end to end over 2,000 texts / 2,592 entities from `en_core_web_sm`:

| | |
|---|---:|
| Matched | 2,564 |
| Missed | 28 |
| Spurious | 69 |
| Recall | 98.92% |

The layers are cleanly separable, and the gap is isolated:

- **Tokenization: exact.** 0/2000 token divergences on this very corpus.
- **NORMs: exact.** 0/2000 divergences.
- **Forward pass: not exact.** The residual is entirely here.

The likely cause is float accumulation order — the hand-written SIMD reduction
sums in a different order from numpy's BLAS, which flips `argmax` on borderline
transitions. The divergent cases are plausible spans with a different label or
extent (`DATE` vs `CARDINAL` over an identical span), never corrupted offsets.
To confirm, dump the tok2vec output for a divergent sentence and diff it against
spaCy's; a last-few-bits difference is accumulation order.

Worth stating plainly: an earlier prototype measured 0 FP / 0 FN, but that was
with **spaCy supplying the tokens and norms** and the `tok2vec` component
excluded from the pipeline. Composed end to end against the full pipeline, it is
98.9%. The pipeline difference alone accounts for only 4 of 2,000 texts.

## Recognizer definitions

[`Tools/extract_patterns.py`](Tools/extract_patterns.py) lifts recognizers into
data — 82 recognizers, **155 patterns**, 82 entity types, 55 needing a Swift
checksum validator, 2 needing a hand port (`UsMbiRecognizer`, `UrlRecognizer`
build their patterns programmatically).

Pattern feature census, which is why the port is tractable: `\b` 131, `\d` 112,
negative lookahead 28, negative lookbehind 19 (all fixed-width single-character),
inline `(?i)` 8 — and **zero** named groups, atomic groups, possessive
quantifiers, conditionals, `\p{...}` or `\B`.

## Layout

```
Sources/PresidioCore/          offset model, span algebra    (stdlib only)
Sources/PresidioRegex/         generated Unicode tables      (stdlib only)
Sources/PresidioRecognizers/   extracted recognizer data
Tests/PresidioConformance/     corpus loader + JSON fixtures
Tools/extract_fixtures.py      harvests upstream pytest tables
Tools/extract_patterns.py      harvests recognizer definitions
Tools/unicode_classes_*.{py,swift}  the backend differential
Tools/check_portability.sh     CI guardrails
```

## Build

```bash
swift build && swift test && ./Tools/check_portability.sh
```

## Planning documents

- [PLAN.md](PLAN.md) — milestones, test strategy, effort
- [PURE-SWIFT-VERDICT.md](PURE-SWIFT-VERDICT.md) — feasibility findings and measurements
- [presidio-pure-swift-architecture.md](presidio-pure-swift-architecture.md) — full design
- [prototypes/](prototypes/) — validated spaCy NER port and regex engine, not yet integrated

## Licence

Recognizer patterns, context word lists, score constants, entity names, and test
expectations derive from Presidio, MIT © Presidio Contributors.
