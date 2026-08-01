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
