// Benchmark harness for the regex substrate.
//
// ADR 0001 accepted a slower engine in exchange for cross-platform-identical
// `\b` semantics. That trade is only defensible with a number attached, so this
// measures the real workload: all 155 Presidio patterns swept over the full
// conformance corpus.
//
// Usage:
//   swift run -c release presidio-bench Tests/PresidioConformance/Fixtures/regex_reference.json

import Foundation
import PresidioRegex

struct Reference: Decodable {
    struct Pattern: Decodable {
        let recognizer: String
        let name: String?
        let regex: String
        /// Per-recognizer: IbanRecognizer drops IGNORECASE.
        let flags: [String]
    }
    let patterns: [Pattern]
    let texts: [String]
}

func now() -> Double {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return Double(ts.tv_sec) + Double(ts.tv_nsec) * 1e-9
}

let args = CommandLine.arguments
guard args.count > 1 else {
    FileHandle.standardError.write(Data("usage: presidio-bench <regex_reference.json>\n".utf8))
    exit(2)
}

let reference = try JSONDecoder().decode(
    Reference.self, from: Data(contentsOf: URL(fileURLWithPath: args[1]))
)

let corpusScalars = reference.texts.reduce(0) { $0 + $1.unicodeScalars.count }
print("patterns  \(reference.patterns.count)")
print("texts     \(reference.texts.count)  (\(corpusScalars) scalars)")

// --- Compilation ---------------------------------------------------------

var compiled: [PureRegex] = []
let compileStart = now()
for pattern in reference.patterns {
    guard let rx = try? PureRegex(
        pattern.regex,
        ignoreCase: pattern.flags.contains("IGNORECASE"),
        dotAll: pattern.flags.contains("DOTALL"),
        multiline: pattern.flags.contains("MULTILINE")
    ) else {
        print("FAILED TO COMPILE: \(pattern.recognizer)/\(pattern.name ?? "?")")
        continue
    }
    compiled.append(rx)
}
let compileTime = now() - compileStart
print("compile   \(String(format: "%.1f", compileTime * 1000)) ms "
      + "for \(compiled.count) patterns "
      + "(\(String(format: "%.2f", compileTime * 1000 / Double(compiled.count))) ms each)")

// --- Sweep ---------------------------------------------------------------

// Warm up so the first pass does not pay for lazy prefilter construction.
var warm = 0
for rx in compiled { for text in reference.texts { warm += rx.matches(in: text).count } }

var best = Double.infinity
var matchCount = 0
let rounds = 5
for _ in 0..<rounds {
    var found = 0
    let start = now()
    for rx in compiled {
        for text in reference.texts { found += rx.matches(in: text).count }
    }
    best = min(best, now() - start)
    matchCount = found
}

let sweptScalars = Double(corpusScalars * compiled.count)
print("sweep     \(String(format: "%.3f", best)) s  (best of \(rounds))")
print("matches   \(matchCount)")
print("throughput \(String(format: "%.1f", sweptScalars / best / 1_000_000)) M scalar-comparisons/s")

// --- Concurrent sweep -----------------------------------------------------
// PureRegex is Sendable, so one compiled pattern can be shared across tasks.
// The 155 patterns are independent, which makes this embarrassingly parallel.
let cores = ProcessInfo.processInfo.activeProcessorCount
let sendablePatterns = compiled
let texts = reference.texts

func concurrentSweep() -> Int {
    let counter = NSLock()
    nonisolated(unsafe) var found = 0
    DispatchQueue.concurrentPerform(iterations: sendablePatterns.count) { index in
        let rx = sendablePatterns[index]
        var local = 0
        for text in texts { local += rx.matches(in: text).count }
        counter.lock(); found += local; counter.unlock()
    }
    return found
}

_ = concurrentSweep()   // warm
var bestConcurrent = Double.infinity
var concurrentMatches = 0
for _ in 0..<rounds {
    let start = now()
    concurrentMatches = concurrentSweep()
    bestConcurrent = min(bestConcurrent, now() - start)
}
print("")
print("cores      \(cores)")
print("concurrent \(String(format: "%.3f", bestConcurrent)) s  (best of \(rounds))  matches \(concurrentMatches)")
print("speedup    \(String(format: "%.2f", best / bestConcurrent))x")
print("           \(String(format: "%.1f", Double(corpusScalars) / bestConcurrent / 1024)) KB/s")
print("          \(String(format: "%.1f", Double(corpusScalars) / best / 1024)) KB/s of corpus "
      + "through all \(compiled.count) patterns")

// --- AnalyzerEngine -------------------------------------------------------
//
// The regex sweep above measures the substrate. This measures what a caller
// actually pays for: 17 recognizers, context enhancement, thresholds and dedup
// over one document. Reported per document and per KB, because the engine is
// usually called on many small texts rather than one big one.

import PresidioEngine
import PresidioAnalyzer
import PresidioRecognizers
import PresidioCore

func benchmarkEngine() {
    let paragraph = """
        Dear Dr. Smith, please find the updated records for patient David \
        Johnson (DOB 12/03/1978). His contact number is (415) 555-0132 and his \
        e-mail is d.johnson@example.com. Payment was taken from card \
        4095-2609-9393-4932, settled against IBAN GB82 WEST 1234 5698 7654 32. \
        The office IP was 192.168.0.14 and the record URL is \
        https://records.example.com/patients/8891. Please confirm by Friday.
        """
    let documents = (0..<200).map { "Record \($0). " + paragraph }
    let bytes = documents.reduce(0) { $0 + $1.utf8.count }

    guard let engine = try? AnalyzerEngine.makeDefault() else {
        print("engine: could not load"); return
    }
    // Warm up: first call pays for catalogue decode and pattern compilation.
    _ = try? engine.analyze(text: documents[0])

    let start = now()
    var found = 0
    for document in documents {
        found += (try? engine.analyze(text: document))?.count ?? 0
    }
    let elapsed = now() - start

    print("")
    print("AnalyzerEngine (17 recognizers, no NLP model)")
    print(String(format: "  %d documents, %.1f KB, %d entities", documents.count,
                 Double(bytes) / 1024, found))
    print(String(format: "  %.3f s total, %.2f ms/document, %.2f MB/s",
                 elapsed, elapsed / Double(documents.count) * 1000,
                 Double(bytes) / elapsed / 1_048_576))

    // Construction cost matters separately: a caller that builds an engine per
    // request pays it every time, and it is not small.
    let buildStart = now()
    for _ in 0..<10 { _ = try? AnalyzerEngine.makeDefault() }
    let buildElapsed = (now() - buildStart) / 10
    print(String(format: "  engine construction: %.1f ms (build once, share it)",
                 buildElapsed * 1000))
}

benchmarkEngine()

func benchmarkRecognizerBreakdown() {
    let paragraph = """
        Dear Dr. Smith, please find the updated records for patient David \
        Johnson (DOB 12/03/1978). His contact number is (415) 555-0132 and his \
        e-mail is d.johnson@example.com. Payment was taken from card \
        4095-2609-9393-4932, settled against IBAN GB82 WEST 1234 5698 7654 32. \
        The office IP was 192.168.0.14 and the record URL is \
        https://records.example.com/patients/8891. Please confirm by Friday.
        """
    let documents = (0..<200).map { "Record \($0). " + paragraph }
    guard let registry = try? RecognizerRegistry.loadPredefined() else { return }

    var timings: [(String, Double)] = []
    for recognizer in registry.recognizers {
        _ = recognizer.analyze(documents[0], entities: [], artifacts: nil)
        let start = now()
        for document in documents {
            _ = recognizer.analyze(document, entities: [], artifacts: nil)
        }
        timings.append((recognizer.name, now() - start))
    }
    let total = timings.reduce(0) { $0 + $1.1 }
    print("")
    print("Per-recognizer cost over the same 200 documents:")
    for (name, seconds) in timings.sorted(by: { $0.1 > $1.1 }).prefix(8) {
        let padded = name.padding(toLength: 26, withPad: " ", startingAt: 0)
        print(String(format: "  %@ %6.1f ms  %5.1f%%", padded,
                     seconds * 1000, seconds / total * 100))
    }
    print(String(format: "  %@ %6.1f ms", "TOTAL".padding(toLength: 26, withPad: " ", startingAt: 0), total * 1000))

    // PhoneRecognizer scans the text once per configured region, so the region
    // list is the single biggest performance lever a caller has.
    print("")
    print("PhoneRecognizer by region count:")
    for regions in [PhoneRecognizer.defaultRegions, ["US", "GB"], ["US"]] {
        let recognizer = PhoneRecognizer(regions: regions)
        _ = recognizer.analyze(documents[0])
        let start = now()
        for document in documents { _ = recognizer.analyze(document) }
        let elapsed = now() - start
        print(String(format: "  %d region(s): %6.1f ms", regions.count, elapsed * 1000))
    }
}

import Foundation
benchmarkRecognizerBreakdown()

// --- The NLP stage --------------------------------------------------------
//
// The model is the other half of the cost, and it moves for different reasons
// than the recognizers do: it is dominated by one matrix multiply, so it scales
// with document length rather than with the number of patterns. Reported in
// three configurations because each is a decision a caller makes.
//
// `parseSentences` is the newest of them. It buys exact agreement with spaCy's
// full pipeline — entities stop at sentence boundaries — and it costs a second
// tok2vec pass plus roughly 2N scored transitions. This is where that trade gets
// a number instead of an adjective.
//
// One negative result, left here so nobody repeats it. The transition loop
// allocates two small `[Float]` scratch arrays per step -- ~2N heap allocations
// per document -- and hoisting them out changed nothing measurable: 0.77/0.80/
// 0.75 ms against 0.78 before, on a machine whose run-to-run spread is wider than
// that. The reason is arithmetic. One step is 1,024 adds for the affine, 128 for
// the maxout, and 6,784 multiply-accumulates for the upper layer over 106
// classes -- the upper layer is 85% of the step, and two 64-float allocations are
// nowhere near it. If the parse is ever worth optimising, that matrix-vector
// product is the only thing in it that matters, and it does not batch, because
// each step's state depends on the last.

import PresidioModelEnglish
import PresidioNLP

func benchmarkNLP() {
    let paragraph = """
        Dear Dr. Smith, please find the updated records for patient David \
        Johnson (DOB 12/03/1978). His contact number is (415) 555-0132 and his \
        e-mail is d.johnson@example.com. Payment was taken from card \
        4095-2609-9393-4932, settled against IBAN GB82 WEST 1234 5698 7654 32. \
        The office IP was 192.168.0.14 and the record URL is \
        https://records.example.com/patients/8891. Please confirm by Friday.
        """
    let documents = (0..<200).map { "Record \($0). " + paragraph }

    guard let directory = EnglishModel.directoryIfPresent else {
        print("")
        print("NLP: the English model is not bundled in this build")
        return
    }

    print("")
    print("NLP stage over the same 200 documents (bundled \(EnglishModel.version))")

    func time(_ label: String, _ body: (String) -> Int) {
        _ = body(documents[0])
        let start = now()
        var found = 0
        for document in documents { found += body(document) }
        let elapsed = now() - start
        print(String(format: "  %@ %6.1f ms  %5.2f ms/doc  (%d entities)",
                     label.padding(toLength: 30, withPad: " ", startingAt: 0),
                     elapsed * 1000, elapsed / Double(documents.count) * 1000, found))
    }

    guard let parsed = try? SpacyNER(modelDirectory: directory),
          let unparsed = try? SpacyNER(modelDirectory: directory, parseSentences: false)
    else { print("  could not load the model"); return }

    time("tokenize only") { parsed.tokenize($0).count }
    time("tokenize + NER") { unparsed.entities(in: $0).count }
    time("tokenize + NER + parser") { parsed.entities(in: $0).count }

    // The tagger and the parser listen to the *same* shared network, so these
    // two rows differ only by the transitions -- `SpacyLemmatizer` encodes once
    // and hands the vectors to both. Subtracting them from the parser row above
    // is how the cost of a duplicated encode becomes visible.
    guard let tags = try? SpacyLemmatizer(
            modelDirectory: directory, parseDependencies: false
          ),
          let tagsAndDeps = try? SpacyLemmatizer(modelDirectory: directory)
    else { return }
    time("tokenize + tags + lemmas") {
        tags.lemmas(for: parsed.tokenize($0), text: $0).count
    }
    time("  ...+ deps, one encode") {
        tagsAndDeps.lemmas(for: parsed.tokenize($0), text: $0).count
    }
}

benchmarkNLP()

// --- The engine with the model ------------------------------------------
//
// The rows above measure components. This measures the composition, which is
// where duplicated work hides: `SpacyNlpEngine` runs NER (with its own tok2vec),
// the parser and the tagger, and two of those three listen to the *same* shared
// network. Whether that network is encoded once or twice per document is not
// visible from any single component's number.

func benchmarkModelEngine() {
    let paragraph = """
        Dear Dr. Smith, please find the updated records for patient David \
        Johnson (DOB 12/03/1978). His contact number is (415) 555-0132 and his \
        e-mail is d.johnson@example.com. Payment was taken from card \
        4095-2609-9393-4932, settled against IBAN GB82 WEST 1234 5698 7654 32. \
        The office IP was 192.168.0.14 and the record URL is \
        https://records.example.com/patients/8891. Please confirm by Friday.
        """
    let documents = (0..<200).map { "Record \($0). " + paragraph }

    guard let directory = EnglishModel.directoryIfPresent,
          let shared = try? SpacyNlpEngine(modelDirectory: directory),
          // The same pipeline with the sharing defeated: a caller-supplied rule
          // lemmatizer that does not parse, so NER loads a parser of its own and
          // the shared tok2vec is encoded twice per document. A/B in one run,
          // because the absolute numbers move more between machines than the
          // difference being measured.
          let unshared = try? SpacyNlpEngine(
              modelDirectory: directory,
              lemmatizer: try SpacyRuleLemmatizer(modelDirectory: directory)
          )
    else { return }

    print("")
    print("SpacyNlpEngine.process (NER + parser + tagger + lemmas)")
    for (label, engine) in [("one tok2vec pass", shared), ("two passes", unshared)] {
        _ = engine.process(text: documents[0], language: "en")
        let start = now()
        var entities = 0
        for document in documents {
            entities += engine.process(text: document, language: "en").entities.count
        }
        let elapsed = now() - start
        print(String(format: "  %@ %6.1f ms  %5.2f ms/doc  (%d entities)",
                     label.padding(toLength: 30, withPad: " ", startingAt: 0),
                     elapsed * 1000, elapsed / Double(documents.count) * 1000,
                     entities))
    }
    print("  shares the lemmatizer's parse: \(shared.sharesLemmatizerParse), "
          + "\(unshared.sharesLemmatizerParse)")
}

benchmarkModelEngine()
