# swift-pii

Find and remove personal data from text, in pure Swift.

Credit cards, IBANs, emails, phone numbers, national identifiers, names, places
— detected with a confidence score, then redacted, masked, hashed or encrypted.
No Apple-only frameworks, so the same code runs on macOS, Linux, and anywhere
else Swift does.

```swift
.package(url: "https://github.com/andriydruk/swift-pii.git", from: "0.1.0")
```

## Quick start

```swift
import PresidioEngine

let detector = try PIIDetector()

for finding in try detector.findings(in: "Card 4095-2609-9393-4932, call 212-555-5555") {
    print(finding.type, finding.text, finding.confidence)
}
// CREDIT_CARD  4095-2609-9393-4932  1.0
// PHONE_NUMBER 212-555-5555         0.4
```

Redact it:

```swift
import PresidioAnonymizer

let text = "Card 4095-2609-9393-4932, call 212-555-5555"
let clean = try Anonymizer().redact(text, using: detector)
// "Card <CREDIT_CARD>, call <PHONE_NUMBER>"
```

That is the whole setup. No model download, no configuration file, no network.

## What it finds

**Out of the box**, anything recognisable from its own shape — 17 recognizers,
no model required:

| | |
|---|---|
| Payment | `CREDIT_CARD`, `IBAN_CODE`, `US_BANK_NUMBER`, `CRYPTO` |
| Contact | `EMAIL_ADDRESS`, `PHONE_NUMBER`, `URL`, `IP_ADDRESS` |
| Identity | `US_SSN`, `US_ITIN`, `US_PASSPORT`, `US_DRIVER_LICENSE`, `UK_NHS`, `MEDICAL_LICENSE` |
| Other | `DATE_TIME`, `MAC_ADDRESS`, `UUID` |

A further **71 country-specific recognizers** ship disabled — German tax IDs,
Indian Aadhaar, Australian Medicare, South African IDs, Korean RRNs and so on.
Enable the ones you need (see [Choosing recognizers](#choosing-recognizers)).

Detection is not just pattern matching. A candidate that passes its checksum
scores higher than one that merely looks right — the card above is 1.0 because
its Luhn checksum holds, while the phone number is 0.4 on shape alone. A
supporting word nearby raises the score further:

```swift
try detector.findings(in: "12345678")               // US_BANK_NUMBER 0.05
try detector.findings(in: "bank account 12345678")  // US_BANK_NUMBER 0.4
```

Only words spaCy does not treat as stop words count, which is why `"call"`
above does not help — it is in the stop list, and Presidio ignores it for the
same reason.

### When you need the language model

Everything above is found from the text's own shape — a checksum, a format, a
nearby keyword. Some personal data has no shape: a name is only a name because
of how it is used. That needs a trained model.

```
Dr. Sarah Chen from Northwind Health called on March 3rd about invoice
4095-2609-9393-4932. Reach her at sarah.chen@example.com or +1 415 555 0132.
She lives in Portland.
```

| | without the model | with it |
|---|---|---|
| `CREDIT_CARD`, `EMAIL_ADDRESS`, `PHONE_NUMBER`, `URL` | found | found |
| `PERSON` "Sarah Chen" | — | found |
| `ORGANIZATION` "Northwind Health" | — | found |
| `LOCATION` "Portland" | — | found |
| `DATE_TIME` "March 3rd" | — | found |

So: **add the model if free text is involved** — support tickets, emails, chat
logs, medical or legal notes. **Skip it for structured data** — form fields,
database columns, CSV exports, logs — where the things you are looking for are
cards, emails, phone numbers and national IDs.

It is not free in either direction. The model also labelled the card number as
a `DATE_TIME` in the example above, a false positive the pattern-only pipeline
does not make, and it roughly doubles processing time. Statistical recall costs
some precision.

**Adding it.** One product:

```swift
.product(name: "PresidioModelEnglish", package: "swift-pii")
```

```swift
import PresidioModelEnglish

let detector = try PIIDetector(
    nlpEngine: try SpacyNlpEngine(modelDirectory: EnglishModel.directory)
)
try detector.findings(in: "David Johnson lives in Seattle")
// PERSON David Johnson 0.85
// LOCATION Seattle 0.85
```

The weights are spaCy's **`en_core_web_sm`** — English, general-purpose,
trained on web text, *small*. It is **bundled in the package**: 12 MB, no
download, no file paths, works offline. A separate product so that callers who
never ask for names do not carry it.

Two neural networks are in there, and they are the only ones in this library:

| | size | what it does |
|---|---:|---|
| `ner/model` | 5.9 MB | the entity recognizer — names, places, organisations, dates |
| `tok2vec/model` + `tagger/model` | 6.0 MB | part-of-speech tags, which the lemmatizer needs |

Everything else — the tokenizer, the lemmatizer, all 88 recognizers — is rules
and lookup tables with no weights at all, and ships in the core package.

The tagger is there for a second reason worth knowing: Presidio scores a
candidate higher when a *supporting word* sits near it, and it compares those
words by dictionary form. Deciding that "identities" is "identity" needs
part-of-speech tags. Without the model that step is approximated, and the
approximation is exact for all but six of the 523 context words in the
catalogue — see
[Lemmas and context scoring](docs/presidio-parity.md#lemmas-and-context-scoring).

## Removing it

`Anonymizer` rewrites the spans a detector found. Every operator can be applied
to all findings or per entity type:

```swift
let anonymizer = Anonymizer()

try anonymizer.redact(text, using: detector)
// "Card <CREDIT_CARD>"

try anonymizer.mask(text, using: detector, character: "*")
// "Card *******************"

try anonymizer.mask(text, using: detector, character: "*", keepingLast: 4)
// "Card ***************4932"

try anonymizer.replace(text, using: detector, with: ["CREDIT_CARD": "[removed]"])
// "Card [removed]"

try anonymizer.hash(text, using: detector, salt: mySalt)
// "Card 8f14e45fceea167a..."
```

Encryption is reversible, so a pseudonymized document can be restored:

```swift
import PresidioAnonymizerCrypto

// AnonymizerEngine + DeanonymizeEngine, with the AES operators registered.
let sealed = try AnonymizerEngine(operators: CryptoOperators.all)
    .anonymize(text: text, analyzerResults: results,
               operators: ["DEFAULT": OperatorConfig("encrypt", ["key": .string(key)])])
let restored = try DeanonymizeEngine(operators: CryptoOperators.all)
    .deanonymize(text: sealed.text, entities: sealed.items,
                 operators: ["DEFAULT": OperatorConfig("decrypt", ["key": .string(key)])])
```

## Tuning what you get

```swift
// Only these types.
try detector.findings(in: text, types: ["EMAIL_ADDRESS", "PHONE_NUMBER"])

// Drop low-confidence guesses.
try detector.findings(in: text, minimumConfidence: 0.6)

// Never flag your own test data.
try detector.findings(in: text, allowing: ["support@example.com"])

// Cheap boolean.
try detector.containsPII(text)
```

Each finding carries a range you can slice with:

```swift
if let range = finding.range(in: text) {
    print(text[range])
}
```

Offsets are **Unicode scalar** offsets, not UTF-16 and not grapheme indices, and
`range(in:)` is the conversion. Getting this wrong silently produces wrong spans
— a PII-leak class of bug — so nothing in this package does index arithmetic on
a `String` by hand.

## Choosing recognizers

The 71 disabled recognizers are country-specific and off by default because
enabling them all reports entities most callers do not want. Load exactly what
you need — this adds Australian Medicare numbers to an English engine:

```swift
import PresidioRecognizers

var registry = try RecognizerRegistry.loadPredefined()   // the default 17
let name = "AuMedicareRecognizer"
if let definition = try Catalog.definitions().first(where: { $0.class == name }),
   let recognizer = Catalog.makeRecognizer(
       definition, logic: ValidatorRegistry.logic(for: name)) {
    registry.add(recognizer)
}
let detector = try PIIDetector(engine: AnalyzerEngine(registry: registry))
```

Or load everything:

```swift
let registry = try RecognizerRegistry.loadPredefined(configuration: nil)
```

A recognizer is only selected when its language matches the one you analyze
with, so adding a German recognizer to an English engine does nothing. See
[Other languages](#other-languages).

### Your own recognizer

```swift
let employeeID = PatternRecognizer(
    name: "EmployeeID",
    entity: "EMPLOYEE_ID",
    patterns: [Pattern(name: "emp", regex: #"EMP-\d{6}"#, score: 0.8)],
    context: ["employee", "staff", "badge"]
)
registry.add(employeeID)
```

A fixed list of terms works too:

```swift
PatternRecognizer.denyList(
    name: "Projects", entity: "PROJECT", terms: ["Bluebird", "Halcyon"]
)
```

### From a config file

```swift
import PresidioEngineYAML

let registry = try YAMLConfiguration.registry(atPath: "recognizers.yaml")
```

```yaml
recognizers:
  - name: EmailRecognizer
    type: predefined
  - name: "Employee ID"
    supported_entity: EMPLOYEE_ID
    type: custom
    patterns:
      - name: employee id
        regex: "EMP-\\d{6}"
        score: 0.8
    context: [employee, staff]
```

## Other languages

The recognizer catalogue is **not English-only**: 37 of its 88 entries are for
other languages, and they detect national identifiers the English set never
would.

| | recognizers | examples |
|---|---:|---|
| German | 13 | tax ID, ID card, health insurance, driving licence, KFZ plate |
| Italian | 5 | fiscal code, VAT, passport, driving licence, identity card |
| Korean | 5 | RRN, BRN, FRN, driving licence, passport |
| Spanish | 3 | NIF, NIE, passport |
| Swedish | 2 | personnummer, organisationsnummer |
| Turkish | 2 | national ID, licence plate |
| Polish, Thai, Finnish | 1 each | PESEL, TNIN, henkilötunnus |

They ship disabled, as they do upstream, because enabling every country at once
reports entities most callers do not want. Opt in by language:

```swift
let registry = try RecognizerRegistry.loadPredefined(
    languages: ["de"], configuration: nil
)
let engine = try AnalyzerEngine(
    registry: registry,
    nlpEngine: try TokenizerOnlyNlpEngine(supportedLanguages: ["de"]),
    supportedLanguages: ["de"]
)
try engine.analyze(text: "Die Steuer-ID lautet 65929970489.", language: "de")
// DE_TAX_ID 1.0
```

### Every language gets the universal recognizers

Ten recognizers belong to no country — e-mail, IP, URL, IBAN, phone, crypto
wallet, date, MAC address, UUID, medical licence — and asking for *any*
language gets all ten, with no configuration:

```swift
let registry = try RecognizerRegistry.loadPredefined(languages: ["es"])
// 13: the ten above, plus CreditCard, EsNif and EsNie
```

| language asked for | recognizers |
|---|---:|
| English | 17 |
| Italian | 16 |
| Spanish | 13 |
| German, French, Russian, Ukrainian, Portuguese, Japanese, Chinese | 10 |

These numbers are asserted against upstream's own loader
([`Tools/registry_reference.py`](Tools/registry_reference.py)) for all ten
languages, on every push — not read off its documentation. It is worth being
explicit because this was wrong until recently: those ten declare no
`supported_languages` in Presidio's config, and reading a missing key as
"English" left every non-English engine with only its country-specific
recognizers. A Spanish engine found NIFs and no e-mail addresses.

### Seven languages, end to end

Each verified layer by layer against spaCy's own output, on a corpus built for
it:

| | de | es | fr | it | pt | ru | uk |
|---|---|---|---|---|---|---|---|
| Tokens, offsets, NORMs | **699** | **560** | **624** | **446** | **368** | **489** | **352** |
| Fine-grained tags | **699/699** | — | — | **446/446** | — | — | — |
| Lemmas | **699/699** | — | — | **446/446** | **368/368** | — | — |
| NER recall | **66/66** | **65/65** | 40/42 | **47/47** | **36/36** | **41/41** | **24/24** |
| NER precision | 0.985 | **1.0** | 0.930 | **1.0** | **1.0** | **1.0** | **1.0** |

Tokenization is exact in all seven. The dashes are structural, not unfinished:
only German and Italian ship a **tagger** at all, and only German, Italian and
Portuguese lemmatize with the edit-tree classifier this port implements. Spanish
and French use bespoke hand-written lemmatizers; Russian and Ukrainian use
`pymorphy3`, a full morphological analyser backed by a compiled dictionary.
Heavily inflected languages are where that gap costs most.

Portuguese is the useful proof that the edit-tree lemmatizer never needed a
tagger — it has no tagger and lemmatizes exactly.

French's NER is not exact by default, and the cause is now known exactly: **spaCy
forbids entities from spanning a sentence boundary**, and takes those boundaries
from the dependency parser — a component this port does not implement. All three
French divergences span a boundary. Supply the boundaries and French is exact:

```swift
ner.entities(in: text, tokens: tokens, sentenceStarts: [0, 2, 9])  // 42/42
```

The same gap accounts for **English's residual 4 of 2,592**: running spaCy with
`exclude=["parser"]` changes exactly 4 of those 2,000 texts, and they are the
same 4. So the port reproduces spaCy's NER *without* the parser exactly, and
differs from the full pipeline only where an entity would otherwise cross a
sentence boundary — measurably 0.2% of English texts and 4% of the French
corpus, which is dense with sentence fragments harvested from spaCy's own tests.

Tokenization, the lexical features and the arithmetic were each ruled out by
measurement before this was found.

None of this affects identifier detection; what degrades without lemmas is
context scoring, which matches supporting words by lemma. Every absence is
asserted by a gap test, so it fails loudly if someone later assumes it closed.

```swift
let nlp = try SpacyNlpEngine(modelDirectory: germanModel, language: "de")
var registry = try RecognizerRegistry.loadPredefined(languages: ["de"])
registry.add(SpacyRecognizer(supportedLanguage: "de"))

let engine = try AnalyzerEngine(
    registry: registry, nlpEngine: nlp, supportedLanguages: ["de"]
)
try engine.analyze(
    text: "Dr. Anna Müller arbeitet bei der Siemens AG in München.",
    language: "de"
)
// PERSON Anna Müller · ORGANIZATION Siemens AG · LOCATION München
```

Weights for these seven are **not bundled** — only English ships with the
package. Download the model once and pass its path:

```bash
curl -sSL -o de.whl https://github.com/explosion/spacy-models/releases/download/de_core_news_sm-3.7.0/de_core_news_sm-3.7.0-py3-none-any.whl
unzip -q de.whl -d de   # de/de_core_news_sm/de_core_news_sm-3.7.0
```

A Swift package is fetched by cloning its repository, so weights committed here
would be downloaded by everyone — including the majority of callers who never
load a model at all. English is bundled because it is what `PIIDetector()` uses
with no arguments; the rest are a path.

Their licences differ, and four of the seven are not MIT — Italian in particular
is **NonCommercial**. See
[Licence and commercial use](#licence-and-commercial-use) before building on
one. The German
national-identifier recognizers ship disabled, as they do upstream; add them
with `configuration: nil` as shown earlier. Spanish's and Italian's are enabled
already.

Almost none of this needed language-specific code. What it needed was English
constants *removed*: the NER loader hard-coded 74 transition classes, so any
other model crashed in the loader, and the tokenizer and stop-word tables were
`en_`-prefixed resources rather than a language parameter. Once German was done,
Italian was exact on the first run and Spanish needed nothing but its tables —
which is the real evidence that what was ported is the *pipeline* rather than
one language's version of it.

The one genuinely new component is the lemmatizer. English lemmatizes by rule —
suffix tables keyed by coarse POS — and German does not: it uses a trained
classifier over **edit trees**, a different pipeline component that happens to
share the name. A lookup table stands in for it at only 67% accuracy, and
sometimes confidently wrongly (it maps "er" to "ich"), so
[`EditTreeLemmatizer`](Sources/PresidioNLP/EditTreeLemmatizer.swift) ports the
real one. It reuses the tagger's forward pass unchanged — the classifier is the
same architecture, differing only in what its 1,311 output classes mean.

The one deliberate asymmetry: a **model** for a language with no bundled
tokenizer rules is refused, because wrong token boundaries corrupt the entity
offsets the model produces. A **tokenizer-only** engine falls back to English
rules and says so through `warnings`, because there the only cost is context
scoring, and refusing would take away the Spanish and Italian recognizers to
avoid an approximation.

### What is English-only

Pattern and checksum detection is language-agnostic — a German tax ID validates
the same way whatever language surrounds it. The **linguistic** layer is not:

- **Only bundled weights are English.** `en_core_web_sm` ships in the package;
  German, Spanish and Italian work fully but you supply the model directory.
- **Tokenizer rules and stop words** are bundled for **en, de, es, fr, it, pt,
  ru, uk**. French's table is 1.7 MB — spaCy's French `token_match` alone is a
  1.45 MB alternation of hyphenated compounds — and costs ~0.08 s to compile the
  first time a French tokenizer is built. Every other language is under 110 KB.
  Another language needs two extractions and no code — but only if spaCy
  tokenizes it by rule. Japanese and Chinese do not: they segment with SudachiPy and pkuseg,
  which are models rather than tables, and nothing here can stand in for them.
- **Fewer entity types outside English.** The `*_core_news_sm` models carry
  **4 NER labels** against English's 18 — `PER`, `LOC`, `ORG`, `MISC`. So no
  `DATE_TIME` and no `NRP` from the model in German, Spanish, French, Italian or
  Portuguese, whatever the tokenizer does.
- **Context words.** Most recognizers list English context words. A handful
  carry Spanish, Italian and Polish ones.

`LexicalTables.hasStopWords(for:)` tells you which case a language is in, rather
than leaving "not a stop word" to mean both "no" and "no idea".

## Many documents at once

```swift
let batch = BatchAnalyzerEngine(analyzer: engine)

try batch.analyze(texts: ["first document", "second document"])

try batch.analyzeDictionary([
    ("customer_email", .text("a@example.com")),
    ("notes", .text("called them back")),
])
```

Dictionary keys become context, so digits under `"credit_card"` score higher
than the same digits under `"notes"`.

## Command line

```bash
swift-pii analyze   file.txt          # exits 1 if it finds PII
swift-pii anonymize -o mask file.txt
cat notes.txt | swift-pii analyze -
```

Formats: `standard`, `colored`, `github`, `parsable` (JSON per finding), and
`auto`, which picks GitHub Actions annotations on CI, colour on a terminal, and
plain otherwise. Options: `--entities`, `--threshold`, `--language`, `--config`
(a YAML recognizer configuration), `--operator`, `--salt`.

**Exit status is meaningful**, which upstream's is not. `presidio-cli` computes
`max_level = 0`, never updates it, and exits on that — so it exits 0 whatever it
finds, and cannot gate CI. This exits **1** when PII is found, **2** on a usage
or I/O error, **0** when clean.

## Shipping it

The data this library needs — recognizer patterns, tokenizer rules, lemma
tables, model weights — travels as SwiftPM **resource bundles**. They are *not*
linked into your binary.

**Building an app** (Xcode, or an SPM package consumed by an app target): there
is nothing to do. The bundles are copied into `YourApp.app/Contents/Resources`
automatically.

**Shipping a standalone executable** (a CLI, a Docker image, a server binary):
copy the `.bundle` directories next to the executable.

```bash
swift build -c release
cp .build/release/my-tool                        /dist/
cp -R .build/release/*_Presidio*.bundle          /dist/
```

Copying only the binary appears to work on the machine that built it — the
generated accessor falls back to the absolute build path — and then **crashes**
with `could not load resource bundle` anywhere else. It is a fatal error, not a
degraded mode, so it fails loudly rather than silently detecting nothing.

Take only the bundles you use:

| Bundle | Size | Needed for |
|---|---:|---|
| `PresidioRecognizers` | 884 KB | always |
| `PresidioNLP` | 1.5 MB | always |
| `PresidioEngine` | 1.0 MB | always |
| `PresidioModelEnglish` | 12 MB | only for `PERSON` / `LOCATION` / `ORGANIZATION` |

A pattern-only CLI ships in **6.4 MB** total, binary included; with the model,
25 MB.

To check a deployment at runtime:

```swift
print(Diagnostics.report())   // one line per resource, with what it decoded
```

## Platform support

Needs **Swift 6.1 or later** — that is where SwiftPM traits arrive, and the
package declares one.

| | |
|---|---|
| macOS | supported, CI |
| Linux | builds and tests green in CI |
| Windows, Android | no Apple-only APIs are **required**, but **neither has been built** |

`PresidioCore` imports no Foundation at all; the regex engine, the analyzer and
the anonymizer are stdlib-only. A CI lint bans `NaturalLanguage`, `CoreML`,
`Vision` and `CryptoKit` outright, so the portability claim is enforced rather
than asserted.

`Accelerate` is the one exception, and it is a *preference*, not a dependency:
on Apple platforms it runs the model's matrix multiply
([why](#the-model-runs-on-accelerate-where-it-exists)), and everywhere else the
same build falls back to the portable kernel. The lint checks it stays in one
file behind its `#if`, and that the portable kernel is always compiled — so
"portable" never quietly becomes "compiles, untested, on the platform nobody
runs CI for". Linux CI asserts the fallback actually happens.

Two dependencies exist, each confined to its own product so you link it only if
you use it: **swift-crypto** for `PresidioAnonymizerCrypto`, and **Yams** for
`PresidioEngineYAML`.

## Performance

Measured on the engine's real workload: 200 documents (~390 bytes each) through
all 17 default recognizers, release build, M-series.

| | per document |
|---|---:|
| `analyze` | **5.7 ms** |
| engine construction | 28 ms — build once, share it |

`PhoneRecognizer` is **72%** of that, and the reason is structural rather than a
defect: it scans the whole text once per configured region, so the region list is
the biggest lever a caller has.

| regions | cost over the same corpus |
|---|---:|
| 8 (default) | 791 ms |
| 2 | 222 ms |
| 1 | 120 ms |

```swift
PhoneRecognizer(regions: ["US"])   // ~6.5x cheaper than the default eight
```

Reproduce any of this with
`swift run -c release presidio-bench Tests/PresidioConformance/Fixtures/regex_reference.json`.

An earlier pass made the engine **1.8× faster** (6.1 → 3.3 ms/document) by
fixing one thing: the phone matcher re-sliced the entire remaining text on every
iteration *and* computed every remaining match only to take `.first`.
`PureRegex` gained `firstMatch(inScalars:from:)`, which stops at the first hit
and scans from an offset.

Some of that has since been spent, deliberately: 3.3 → 5.7 ms/document, and
almost all of it inside the phone matcher, which went from 441 to 791 ms over
this corpus when it gained libphonenumber's `STRICT_GROUPING`/`EXACT_GROUPING`
checks and full metadata coverage. That was the trade the project chose — the
phone matcher now agrees with Python on 4,031 of 4,032 adversarial cases. The
regex engine underneath it did not change: it still sweeps this corpus in 0.455 s
single-threaded, against 0.406 s when that figure was first recorded.

### The model runs on Accelerate where it exists

If you use the language model, most of its time goes into one matrix multiply.
On Apple platforms that is Accelerate's BLAS; everywhere else it is a
hand-written SIMD kernel that ships in the same source. You do not configure
this and there is no extra product to add — the fallback is a `canImport`, so
one build does the right thing on each platform.

| same corpus, same binary, only the kernel differs | portable | Accelerate |
|---|---:|---:|
| NLP stage (tokenize + NER + tagger + lemmas) | 6.06 ms/doc | **2.38 ms/doc** |
| end-to-end `analyze` with the model | 11.8 ms/doc | **8.2 ms/doc** |
| end-to-end `analyze` without it | 5.58 ms/doc | 5.63 ms/doc — unchanged, as expected |

**The gain grows with document length**, because that is what makes the matrices
tall: on a single short sentence it is nearer 25%, and on paragraph-length
documents like the ones above the inference stage is 2.5× faster. It does
nothing at all for pattern-only detection, which is the last row — for most of
the corpus above the phone matcher is still the expensive part.

**Turning it off.** There is one reason to, and it is not correctness: with
Accelerate in play, macOS does not run bit-identical arithmetic to Linux and
Android. If you need one number everywhere — a cross-platform golden-output
test, say, or a reproducibility requirement you have to argue in writing:

```swift
.package(url: "https://github.com/andriydruk/swift-pii.git", from: "0.1.0",
         traits: [])          // portable kernel on every platform
```

Working in this repo directly, that is `swift build --disable-default-traits`
(likewise `swift test`).

What that buys you is *sameness*, not accuracy. Measured over the full parity
corpora the **outcomes are already identical** — 5,513/5,513 tags, 5,513/5,513
lemmas, 2,588/2,592 entities either way, and not one argmax flips across 5,513
tokens — while ~93% of the intermediate floats differ in their last bits. CI
runs both kernels against the same gold corpora on every push, because both are
configurations someone ships.

### Regex features

`PureRegex` implements what Presidio's patterns and spaCy's tokenizer rules
need: capture groups, alternation, backreferences, lookahead, fixed-width
lookbehind, lazy and possessive quantifiers, Unicode classes from generated
tables, and inline flag groups.

**Inline flags** follow Python: `(?i)` applies to the whole pattern wherever it
appears, `(?i:...)` and `(?-i:...)` are scoped to their group. `i`, `s`, `m` and
`u` are supported. `a`, `L` and `x` are **rejected with an error** rather than
ignored — each changes what a pattern means, and a silently dropped flag is a
pattern that matches the wrong thing forever. Scoped `(?m:...)` is also rejected,
because `^` and `$` consult multiline at match time and it cannot vary per
subexpression.

That strictness is not theoretical: the engine used to accept every flag and
apply none of them, which made French's `(?iu)` tokenizer pattern
case-sensitive and split `Saint-Louis` while leaving `franco-italienne` whole.

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

## Where this comes from

swift-pii is a behavioural port of
[Microsoft Presidio](https://github.com/data-privacy-stack/presidio), which is
Python and depends on spaCy. The recognizer patterns, context words, score
constants and entity names are Presidio's; so are the test expectations, which
are harvested from its own test suite rather than rewritten.

Fidelity is measured, not claimed. Against **16,671 recorded cases** the port
agrees exactly on the recognizers, the engine's whole option matrix, the
tokenizer, the regex substrate, the anonymizer and the lemmatizer; NER is
99.85%. The evidence, the deliberate divergences and the remaining gaps are in
[docs/presidio-parity.md](docs/presidio-parity.md).

You do not need to know any of that to use this library, and nothing in the API
requires you to think in Presidio's terms.

Not affiliated with or endorsed by the Presidio project. The package is
deliberately not named after it — MIT grants no trademark rights, and a
`swift-presidio` would read as the official port. Module names keep the
`Presidio` prefix because there they describe what the code is compatible with.

## Known gaps

- **Names need the model.** Without it there is no `PERSON`, `LOCATION` or
  `DATE_TIME` from context — only what patterns can find.
- **Names are English only.** Identifier detection works in every language the
  catalogue covers, but `PERSON`/`LOCATION` need a model and only the English
  one is ported — see [Other languages](#other-languages).
- **No image redaction, structured-data support, or REST server.** This is a
  library, not a service.
- **Windows and Android are unverified.** Nothing Apple-specific is used and
  Linux is green, but neither has been built.

## Contributing

```bash
swift build && swift test && ./Tools/check_portability.sh
```

The NER, tagger and lemmatizer parity suites need a spaCy model and are skipped
without one; CI runs them in their own job. Everything else runs offline.

**Build release when you use the model.** The forward pass is a hand-written
matrix multiply — there is no BLAS to call, because Accelerate is Apple-only and
this package does not use it — and a tight numeric loop is the worst case for an
unoptimised build: nothing is inlined, every array element is bounds-checked, and
`SIMD8<Float>` never becomes a vector instruction. Measured here:

| | debug | release |
|---|---:|---:|
| 100 NER inferences | 15.4 s | 0.061 s |
| 100 tagger inferences | 15.7 s | 0.060 s |
| loading the weights | 0.6 s | 0.033 s |

That is **~250x on the arithmetic** and only 18x on loading, so it really is the
matrix math. Ordinary Swift is 2–10x slower in debug; numeric kernels are the
pathological case. Pattern-only detection has no such gap.

## Licence and commercial use

**Yes, you can use this in a commercial product**, including closed-source. No
component here is copyleft in a way that reaches your code.

This is not legal advice, and the summary below is a reading of the licence
files rather than a substitute for them — the authoritative list is
[NOTICE](NOTICE).

| What | Licence | What it asks of you |
|---|---|---|
| This library | MIT | keep the copyright notice |
| Presidio patterns, context words, test expectations | MIT | keep the notice |
| spaCy model `en_core_web_sm` (bundled) | MIT | keep the notice |
| spaCy models for the other seven languages (**not** bundled) | varies — see below | varies |
| spaCy tokenizer rules | MIT | keep the notice |
| libphonenumber metadata | Apache 2.0 | keep the notice |
| Yams / libyaml | MIT | keep the notice |
| swift-crypto | Apache 2.0 | keep the notice |
| Unicode character data | Unicode | keep the notice |
| WordNet 3.0 lemma tables | WordNet | keep the notice; Princeton's name may not be used to promote your product |
| **Public Suffix List** | **MPL 2.0** | see below |

In practice: ship the contents of `NOTICE` with your product — the usual
"acknowledgements" or "open-source licences" screen — and you are done.

### Language models are not all MIT

Only English ships with the package. Every other language works identically, but
you supply the weights — and their licences differ enough that it is worth
checking before you build on one.

| model | licence | notes |
|---|---|---|
| `en_core_web_sm` | MIT | **bundled** |
| `de_core_news_sm` | MIT | |
| `ru_core_news_sm` | MIT | |
| `uk_core_news_sm` | MIT | |
| `es_core_news_sm` | **GPL 3.0** | strong copyleft |
| `fr_core_news_sm` | **LGPL-LR** | copyleft for linguistic resources |
| `pt_core_news_sm` | **CC BY-SA 4.0** | ShareAlike |
| `it_core_news_sm` | **CC BY-NC-SA 3.0** | **NonCommercial — no commercial use** |

The Italian one deserves a second look before you build on it: CC BY-NC-SA 3.0
forbids commercial use, so a commercial product cannot ship Italian name
detection on that model at all. None of this touches the library, the
recognizers, the tokenizer rules or the stop-word tables — those come from
spaCy's *language modules*, which are MIT, and are bundled.

Why none of the other seven are bundled, including the three MIT ones: a Swift
package is fetched by cloning its repository, so weights in the repo are
downloaded by everyone — including the majority of callers who never load a
model, because pattern and checksum detection needs none. Four of the seven
could not be bundled regardless, so "you supply the model" is one rule instead
of two. English is the exception because it is what `PIIDetector()` uses with no
arguments.

Getting one is a download and a path:

```bash
curl -sSL -o de.whl https://github.com/explosion/spacy-models/releases/download/de_core_news_sm-3.7.0/de_core_news_sm-3.7.0-py3-none-any.whl
unzip -q de.whl -d de && echo de/de_core_news_sm/de_core_news_sm-3.7.0
```

```swift
let nlp = try SpacyNlpEngine(modelDirectory: thatPath, language: "de")
```

### The two worth reading properly

**The Public Suffix List is MPL 2.0**, which is the only copyleft licence in
here. MPL 2.0 is *file-level*: the obligation attaches to the file, not to
anything that links it. Your own code is unaffected. It lives in its own file
with its notice preserved, deliberately, so the boundary is obvious:

```
Sources/PresidioRecognizers/Resources/public_suffix_list.json
```

If you redistribute that file **modified**, MPL asks you to make the modified
version available under MPL. Shipping it unchanged — which is what you get —
asks nothing beyond keeping the notice.

**The model's training data.** `en_core_web_sm` is MIT, but it was trained on
OntoNotes 5, which is itself licensed from the LDC. The model's own
`LICENSES_SOURCES` records that as "commercial (licensed by Explosion)" — an
obligation Explosion discharged when they trained and released the weights, and
one that does not propagate to you. Both files travel with the model in this
package so you can read them yourself:

```
Sources/PresidioModelEnglish/Resources/model/LICENSE
Sources/PresidioModelEnglish/Resources/model/LICENSES_SOURCES
```

If you would rather not carry that question at all, do not add the
`PresidioModelEnglish` product. The core library ships no trained weights.

### What none of this does

No component requires you to open-source your application, pay a royalty, share
modifications to your own code, or grant patent rights beyond the standard
Apache-2.0 terms on swift-crypto and the phone metadata.

## Attribution

MIT. Recognizer patterns, context words, score constants, entity names and test
expectations derive from Presidio, MIT (c) Presidio Contributors. The bundled
English model is spaCy's `en_core_web_sm`, MIT (c) ExplosionAI GmbH. Other
bundled data — including the MPL-2.0 Public Suffix List and WordNet-derived
lemma tables — is itemized in [NOTICE](NOTICE).
