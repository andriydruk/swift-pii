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

**Names, places and organisations** need a language model. Add one product:

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

The model is **bundled in the package** — 12 MB, no download, no file paths,
works offline. It is a separate product so that callers who only need
pattern-based detection do not pay for weights they never load.

Two neural networks are in there, and they are the only ones this library has:

| | size | what it does |
|---|---:|---|
| `ner/model` | 5.9 MB | finds names, places, organisations, dates |
| `tok2vec/model` + `tagger/model` | 6.0 MB | part-of-speech tags, which the lemmatizer needs |

Everything else — the tokenizer, the lemmatizer, every recognizer — is rules and
lookup tables, and ships in the core package with no weights at all.

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
you need:

```swift
import PresidioRecognizers

var registry = try RecognizerRegistry.loadPredefined()   // the default 17
if let definition = try Catalog.definitions().first(where: { $0.class == "DeTaxIdRecognizer" }),
   let recognizer = Catalog.makeRecognizer(
       definition, logic: ValidatorRegistry.logic(for: "DeTaxIdRecognizer")) {
    registry.add(recognizer)
}
let detector = try PIIDetector(engine: AnalyzerEngine(registry: registry))
```

Or load everything:

```swift
let registry = try RecognizerRegistry.loadPredefined(configuration: nil)
```

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

## Platform support

| | |
|---|---|
| macOS | supported, CI |
| Linux | builds and tests green in CI |
| Windows, Android | no Apple-only APIs are used, but **neither has been built** |

`PresidioCore` imports no Foundation at all; the regex engine, the analyzer and
the anonymizer are stdlib-only. A CI lint bans `NaturalLanguage`, `CoreML`,
`Vision`, `CryptoKit` and `Accelerate` outright, so the portability claim is
enforced rather than asserted.

Two dependencies exist, each confined to its own product so you link it only if
you use it: **swift-crypto** for `PresidioAnonymizerCrypto`, and **Yams** for
`PresidioEngineYAML`.

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
- **English only.** The recognizers carry Spanish, Italian and Polish context
  words, but the bundled model and the lemmatizer are English.
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

## Licence

MIT. Recognizer patterns, context words, score constants, entity names and test
expectations derive from Presidio, MIT (c) Presidio Contributors. The bundled
English model is spaCy's `en_core_web_sm`, MIT (c) ExplosionAI GmbH. Other
bundled data — including the MPL-2.0 Public Suffix List and WordNet-derived
lemma tables — is itemized in [NOTICE](NOTICE).
