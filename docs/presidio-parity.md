# Parity with Microsoft Presidio

swift-pii is a behavioural port of
[Presidio](https://github.com/data-privacy-stack/presidio), Microsoft's PII
toolkit, which is written in Python and depends on spaCy. This document is the
evidence for the word "behavioural": what was measured, against what, and where
it still differs.

Nothing here is needed to *use* the library — see the [README](../README.md).

## How correctness is established

Tests are **harvested, not written**. Presidio's analyzer and anonymizer ship
163 test files and 3,272 collected pytest cases; the recognizer tables are pure
data, so [`Tools/extract_fixtures.py`](../Tools/extract_fixtures.py) lifts them
into language-neutral JSON that Swift tests consume directly. Correctness is
measured against upstream's own expectations rather than fixtures we invented.

Where upstream has no test, the tool that *generates* one runs the Python and
records what it did. Every corpus in the repository has a generator in
[`Tools/`](../Tools); none is hand-maintained.

That last sentence was not true until recently. `ner_gold_sm.json` — the corpus
the headline NER number is measured against — predated the rest of `Tools/` and
had no generator, so it was the one fixture that could have gone stale in silence.
It has one now, and CI re-derives it. Regenerating it with a different spaCy
*library* version (3.8.14 to 3.7.5, same model 3.7.1) changed nothing on any of
the 1,850 unique texts, which is the first direct evidence for a claim the README
has always made: the model version is what matters, not the library's.

| Corpus | cases | agreement |
|---|---:|---|
| Recognizers (harvested) | 1,731 | **1,731 (exact)** |
| `AnalyzerEngine` option matrix | 6,300 | **6,300 (exact)** |
| Tokenizer | 2,517 | **exact** |
| Regex substrate | 1,609 | **exact** |
| Phone matcher (4 leniencies) | 4,032 | 4,031 |
| Phone parse / validity | 480 | **480 / exact** |
| Tagger / POS / lemma | 5,513 | **exact / exact / exact** |
| NER | 2,028 | **exact** |
| Dependency parse / boundaries | 2,028 | **exact** |
| Validators (adversarial) | 2,111 | **exact** |
| Validators (harvested) | 206 | **exact** |
| `RecognizerResult` predicates (harvested) | 37 | **exact** |
| Static helpers (harvested) | 18 | **exact** |
| `remove_duplicates` (harvested) | 3 | **exact** |
| Anonymizer + crypto | 43 | **exact** |
| Batch analyzer | 9 | **exact** |
| **Total** | **28,665** | |

## Scope

| Upstream | Status |
|---|---|
| `presidio-analyzer` | ported — engine, batch engine, registry, context enhancer, YAML config, spaCy NLP |
| `presidio-anonymizer` | ported — 8 of 9 operators, anonymize and deanonymize |
| `presidio-cli` | ported |
| `presidio-image-redactor` | not ported — needs DICOM and a cross-platform OCR story, neither of which exists in Swift |
| `presidio-structured` | not ported |
| REST API servers | not ported |

**Recognizers: 88 of 99 classes.** The 10 absent are Azure x3, LangExtract x2,
GLiNER, HuggingFaceNER, MedicalNER, Stanza and Transformers — every one a cloud
service or an alternative NLP backend, not a detection rule.
(`ZaPhoneNumberRecognizer` shows up in a naive diff but is upstream's abstract
base class, and is implemented.)

**Operators: 8 of 9.** `AHDSSurrogate` is out of scope.
**NLP engines: 2 of 5** — spaCy and NoOp.

Every shipped recognizer has harvested test cases; none ships unverified.

## Deliberate divergences

**Ordering is deterministic here, unlike upstream.** Presidio's result order
derives from Python `set` iteration and a sort key that omits `entity_type`, so
ties vary with `PYTHONHASHSEED`. This package defines an explicit total order —
score desc, start asc, length desc, entity type asc — and documents it as the
contract. Bit-exact ordering parity is not achievable; reproducible ordering is.

**The CLI exits meaningfully.** `presidio-cli` computes `max_level = 0`, never
updates it, and exits on that, so it exits 0 whatever it finds and cannot gate
CI. Ours exits 1 on findings.

**`RecognizerResult` compares on `(entity, start, end, score)`**, matching
Python's `__eq__`/`__hash__`. Swift's synthesized conformance would also compare
metadata, which is invisible within one recognizer but stops `remove_duplicates`
from collapsing the same span found by two.

## Where it still differs

- Nothing in the NLP pipeline is approximate any more. Tokens, NORMs,
  fine-grained tags, coarse POS, lemmas, entity spans, dependency heads,
  dependency labels and sentence boundaries are all exact.
- **One phone case** of 4,032: a leniency-0 timestamp where the inner-match
  fallback accepts "00" as *possible*. Presidio always uses leniency 1.
- **44 upstream test tables** remain unharvested, recorded with reasons in the
  corpus artifact. Almost entirely infrastructure — registry configuration, NER
  model configuration, ONNX and device selection — rather than recognizer
  behaviour.

## Lemmas and context scoring

Presidio raises a result's score when a *supporting word* sits near it, and it
compares those words by dictionary form — so deciding that "identities" is
"identity" is what makes the boost fire. spaCy does that in **rule mode**, which
needs part-of-speech tags and therefore the tagger.

**With the model, this port is exact.** The whole chain is ported: tagger ->
attribute ruler -> rule-mode lemmatization.

| stage | agreement over 5,513 tokens |
|---|---|
| fine-grained tags | **5,513/5,513** |
| **lemmas** | **5,513/5,513** |

| stage | agreement over 5,513 tokens |
|---|---|
| coarse POS, with dependency labels | **5,513/5,513** |
| coarse POS, without them | 5,499/5,513 |

POS was 5,499/5,513 for a long time, and described as unreachable without the
dependency parser. Both halves of that turned out to be worth revisiting.

The attribute ruler is a `Matcher` over 179 token patterns. The extractor
flattened each one to a `(tags, lowers)` pair and put the 22 that would not
flatten — the ones testing `DEP`, matching two adjacent tokens, or using
`NOT_IN`/`REGEX` — into a side list that nothing read. That lost more than the
rules. It lost their **position**: spaCy sorts matches by pattern index and
applies them in that order, so rule 173 setting `PRON` has to run after rule 47
setting `DET`. A rule lifted out of the sequence cannot be appended back at the
end. It also dropped alternatives, so rule 175's `[[VBZ gets], [VBD got]]` kept
only the first and `got` -> `get` was never applied.

The ruler is now a faithful ordered matcher over the full vocabulary, which is
small and closed: keys `TAG`/`LOWER`/`DEP`/`IS_SPACE`, operators literal / `IN` /
`NOT_IN` / `REGEX`, patterns one or two tokens long with an `index` choosing
which token is annotated. Two properties of spaCy's version are easy to lose and
both matter: all matching happens *before* any annotation, so a rule's `TAG` test
never sees a tag an earlier rule assigned; and rules apply in pattern order, not
token order.

There is no separate no-parser code path. spaCy represents an unset attribute as
the string id of `""`, so with no dependency labels every `DEP` constraint simply
fails — which is exactly what a pipeline without a parser does, and is why the
second row above is the old number rather than nonsense. Both rows are asserted.

**No parser-dependent rule reaches a lemma.** That was previously an argument;
it is now a measurement — the suite runs the whole chain both ways over the
corpus and compares all 5,513 lemmas. That is what lets `SpacyRuleLemmatizer`
default to skipping the parse: the engine wants lemmas, and a parse would buy it
nothing.

**Without the model** the default is `LookupLemmatizer`: spaCy's POS-free lookup
table, restricted to `-ies` plurals.

| | agreement | regressions vs lowercase |
|---|---:|---:|
| lowercase only | 86.25% | — |
| **`-ies` subset (default)** | **86.86%** | **0** |
| full lookup table | 96.87% | 251 occurrences, 48 distinct |

The full table wins on raw agreement and loses where it counts: it stems
`number` -> `numb`, and `number` is a context word for **36 recognizers**, so a
phone number written "My number is ..." drops from 0.75 to 0.4. Raw lemma
accuracy is the wrong metric — what matters is agreement on the
*context-matching outcome*, where lowercasing's errors are systematically
harmless because substring matching absorbs suffix-stripping. It remains
available as `LookupLemmatizer(scope: .full)`, with a test pinning
`number` -> `numb` so the default is not "fixed" later.

The gap the default leaves is small and measured: of **523 context words across
all 88 recognizers**, exactly **6** are reachable only through a lemma
(`beneficiary`, `birthday`, `delivery`, `identity`, `security`, `taxonomy`), all
the `-y -> -ies` plural. In the 17 a default engine loads, zero.


## Regenerating the corpora

```bash
python3 Tools/extract_fixtures.py --presidio /path/to/presidio \
    --out Tests/PresidioConformance/Fixtures/recognizer_cases.json
```

That one needs nothing installed — it reads with `ast` only, which is why CI can
regenerate it from a bare checkout. The oracle tools do need a Python
environment, and their versions are pinned in
[`Tools/requirements.txt`](../Tools/requirements.txt) for a reason: the corpora
record which `regex` and `phonenumbers` they were built with, and tests fail if
those drift from the data compiled into the package.

## Regex backend

Settled in [ADR 0001](../docs/decisions/0001-regex-backend.md) with a
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
([`UnicodeTables.swift`](../Sources/PresidioRegex/UnicodeTables.swift), 796 + 71 + 10
ranges), pinning the Unicode version as reviewable data. A test asserts
membership matches Python for all 1.1M codepoints.

### Differential result

All 161 patterns × 1,609 corpus texts = **259,049 comparisons, 6,244 matches,
zero divergences** from Python — same count, same offsets, same order. Absence
of a match is asserted as strongly as presence.

The reference records the `regex` module version it was built with, and a test
fails if that differs from the version the Unicode tables were generated from
(`regex==2024.11.6`, which reports `__version__ == 2.5.148`). That guard earns
its keep: regenerating this corpus with a newer `regex` release tripped it
immediately, which is the same data-version skew that disqualified ICU.

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
character wakes 71.6 of the 155 patterns then in the corpus (digits wake 93).
PII patterns are
dominated by digit and letter classes, so there is no dispatch win to be had.
Recorded in the ADR so it is not retried.

## Conformance corpus

Regenerate from a Presidio checkout:

```bash
python3 Tools/extract_fixtures.py --presidio /path/to/presidio --out Tests/PresidioConformance/Fixtures/recognizer_cases.json
```

That one needs nothing installed — it reads with `ast` only. The oracle tools
do, and their versions are pinned in
[`Tools/requirements.txt`](../Tools/requirements.txt) for a reason: the corpora
record which `regex` and `phonenumbers` they were built with, and tests fail if
those drift from the data compiled into the package.

Current corpus:

| Corpus | Tables | Cases | Recognizers |
|---|---:|---:|---:|
| `recognizer_cases.json` | 106 | 1,722 (1,034 pos / 688 neg) | 86 |
| `computed_cases.json` | 1 | 9 | 1 |
| `validator_cases.json` | 22 | 206 | 22 |

**32** upstream tables are still not extracted, and they are **recorded in the
artifact** under `skipped` with reasons — coverage you can't see is coverage you
don't have.

It was 44, and the paragraph here used to describe the remainder as "almost
entirely infrastructure". That was an overstatement nobody had checked. Reading
the list, about a third was real behaviour that the extractor could not *express*
rather than behaviour that did not matter: a unit test of a value type has no text
column, so it fell out under "unsupported shape" and looked like configuration.

[`Tools/extract_operation_cases.py`](../Tools/extract_operation_cases.py) handles
that class — a second tool with a second contract, the same split as
`extract_computed_fixtures.py`. It reads three shapes statically:

| shape | cases |
|---|---:|
| **Predicates** — two literal-built values, one boolean assertion. `contains`, `equal_indices`, `has_conflict`, ordering, equality, hashing | 37 |
| **Functions** — a call whose arguments are literals or parameters. `sanitize_value`, Aadhaar palindrome and Verhoeff, ZA prefix classification | 18 |
| **Pipelines** — a list of results through a function, with assertions about the survivors. `remove_duplicates` | 3 |

That covers 12 of the 44, plus **seven tests nobody was counting** — they carry
no parametrize decorator, so they were never tables and never appeared in a
skipped list. All 58 agree.

The third shape is the point of the first two. `remove_duplicates` is what the
span predicates *feed*, and its behaviour does not follow from theirs: it dedupes
on equality, sorts by a key that omits the entity type, drops zero scores, and
only then removes what is contained in a survivor **of the same type**. That last
qualifier is pinned by exactly one upstream table.

The harvest also found something. Upstream's `_is_palindrome` takes an optional
second argument that lowercases *and strips spaces*, which its name does not say.
The port had a one-argument version — behaviourally sufficient for its only
caller, since Aadhaar numbers are digits, and wrong as a port. Two of the five
rows exercise the argument that did not exist.

**What remains, counted honestly.** The tool's own `skipped` list means "not
covered anywhere", not "not covered by me". Its first version conflated the two
and reported four tables that `extract_fixtures.py` already harvests, which
overstated the gap — the same species of error as this section's earlier
"almost entirely infrastructure", pointing the other way. Those are now recorded
separately as `covered_elsewhere`, and a test asserts the two stay distinct.

Of the 32 left: registry and NER model configuration, ONNX and device selection,
recognizers this port does not ship, serialization round-trips, and **five**
tables whose subject is a pytest fixture, so the constructor arguments live
outside the file being read. Those five are reachable — they need the fixture
resolved, not a new idea.

The extractor evaluates without executing. Beyond plain literals it folds
module-level constants, sequence repetition (`[(0.5, 0.8)] * 2`) and
placeholder-free f-strings, because refusing those cost seven real tables. It
also reads `assert len(results) == 0` out of a test body, which is how a table
with only a `text` column is understood as negative — from the assertion, not
from the test's name.

One upstream table computes its cases with a Verhoeff routine at module scope,
so no static evaluator can reach it.
[`Tools/extract_computed_fixtures.py`](../Tools/extract_computed_fixtures.py)
handles that class by *importing* the test module — a separate tool with a
separate contract, writing its own artifact, so `extract_fixtures.py` stays
`ast`-only and CI can regenerate the corpus from a bare checkout with no Python
environment.

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
hand-written SIMD, or Accelerate's BLAS if you opt in (see below).

Input is raw text; output is `NamedEntity` with **scalar character offsets**,
which is what a PII pipeline actually needs.

`SpacyNER(modelDirectory:)` takes an unpacked model directory. A trimmed
`en_core_web_sm` (12 MB) ships in the separate `PresidioModelEnglish` product —
`EnglishModel.directory` — so callers who want names do not have to find and
unpack one, and callers who do not are not carrying weights. The parity suite is
gated on `SPACY_MODEL_DIR` and reports when unset rather than passing vacuously,
because it needs the untrimmed **3.7.1** the gold corpus was built from.

### Parity is exact

Measured end to end over 2,028 texts / 2,915 entities from `en_core_web_sm`:

| | |
|---|---:|
| Matched | 2,915 |
| Missed | 0 |
| Spurious | 0 |
| Recall, precision | 100% |

Every layer is exact and each was measured separately: tokenization (0/2,028
divergences on this very corpus), NORMs (0/2,028), the forward pass, and the
sentence boundaries the transition system consults.

The corpus has an adversarial half now — 29 texts that are not prose: empty,
whitespace-only, 2,000 tokens of one word, 500 bare sentence terminators, zero
width characters, combining marks past a token's suffix window, extraposed
relative clauses for the deprojectivisation path, and the markup tables where the
sentence-boundary divergences actually lived. They were written by probing the
port for crashes; it did not crash, and it agreed with spaCy, which is exactly the
kind of thing worth pinning before someone optimises the state machine.

It took two wrong explanations to get here, and both are worth recording because
both were plausible.

It first read 98.92%, blamed on float accumulation order. That was a guess: 24 of
the 28 misses came from the reserved string-store symbols, whose table was read
from a relative `symbols.tsv` that never existed, so every shape like `"X"`
hashed instead of resolving to its symbol id. Bundling the table took recall to
99.85% and left 4.

Those 4 got the same treatment — "plausible spans, probably arithmetic" — and
that was wrong too. Accumulation order was ruled out by the next section, where
an entirely different summation order changes none of them. They were **sentence
boundaries**: spaCy's `Begin.is_valid` and `In.is_valid` refuse to open or extend
an entity when the next token starts a sentence, and it takes those boundaries
from the dependency parser. Running spaCy with `exclude=["parser"]` over the same
2,000 texts changed exactly those 4. With the parser ported the corpus is exact,
and the parser itself is measured against spaCy directly: 50,731/50,731 heads,
50,731/50,731 labels, 2,414/2,414 boundaries.

### Two matrix kernels, one set of outcomes

The matrix multiply has two implementations, and which one runs depends on the
platform: Accelerate's `cblas_sgemm` where it exists, the hand-written SIMD
kernel everywhere else. BLAS blocks and reduces in a completely different order,
so this is a natural experiment on how much the arithmetic actually matters
here — and, since both are shipped, one this project has to answer rather than
speculate about.

Over the full corpora, it does not matter at all:

| | portable SIMD | Accelerate |
|---|---:|---:|
| Fine-grained tags | 5,513/5,513 | 5,513/5,513 |
| Coarse POS | 5,513/5,513 | 5,513/5,513 |
| Lemmas | 5,513/5,513 | 5,513/5,513 |
| NER entities | 2,915/2,915 | 2,915/2,915 |
| Dependency heads | 50,731/50,731 | 50,731/50,731 |
| Sentence boundaries | 2,414/2,414 | 2,414/2,414 |

Not one `argmax` flips across 5,513 tagged tokens, 2,915 entities and 50,731
parser decisions. Meanwhile ~93% of the individual intermediate floats *do*
differ, with a maximum absolute delta of 3.6e-05 at the shapes this model uses.

The parser is the strongest version of this test, and it was added after the
claim rather than before it: it takes ~2N sequential argmaxes over 106 classes,
each one changing the state that produces the next, so a single flip early in a
sentence would cascade into different heads and a different boundary. None
flips. This was also how accumulation order was ruled out as an explanation for
the NER gap that turned out to be sentence boundaries — a different summation
order would have moved it, and did not. The margins in this network are wide
enough that last-bit differences do not reach the output — which is what makes Accelerate the default on Apple platforms
rather than something to opt into.

It is still a trait (`PresidioAccelerate`, on by default, `traits: []` to
disable), for one case only: needing macOS and Linux to produce bit-identical
intermediates, not merely identical answers. "No divergence on this corpus" is
not "never diverges", and anyone with a cross-platform golden-output test has a
legitimate reason to want the same kernel everywhere.

CI runs the parity suites under both kernels and asserts from the test output
which kernel each job compiled — a trait that silently did nothing would
otherwise look exactly like a trait that worked. The Linux canary separately
asserts that a default build there lands on the portable kernel, since a default
trait is enabled on every platform and `canImport(Accelerate)` is the only thing
standing between that and a broken Android build.

Worth stating plainly, because the history reads better than it went: an early
prototype measured 0 FP / 0 FN, but that was with **spaCy supplying the tokens and
norms** and the `tok2vec` component excluded. Composed end to end it first
measured 98.9%, and getting back to exact took three separate findings — the
reserved symbol table, the sentence boundaries, and the parser that produces
them. None of them was the explanation offered at the time.

## Recognizer definitions

[`Tools/extract_patterns.py`](../Tools/extract_patterns.py) lifts recognizers into
data — 84 recognizers, **161 patterns**, 84 entity types, 56 needing a Swift
checksum validator, and **none** needing a hand port. Three recognizers are
outside the catalogue entirely, because they declare no patterns at all and
delegate to libphonenumber.

Pattern feature census, which is why the port is tractable: `\b` 133, `\d` 116,
negative lookahead 28, `\s` 21, negative lookbehind 19 (all fixed-width
single-character), inline `(?i)` 12 — and **zero** named groups, atomic groups,
possessive quantifiers, conditionals, `\p{...}` or `\B`.
