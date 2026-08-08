import Testing
import PresidioCore
import PresidioAnalyzer
import PresidioModelEnglish
@testable import PresidioEngine

/// `AnalyzerEngine` is `Sendable`, so a single instance may be shared across
/// tasks. These run it that way under load; the suite is worth running with
/// `swift test --sanitize=thread`, which is what caught the tokenizer cache
/// being shared without a lock.
@Suite("Concurrency")
struct ConcurrencyTests {

    static let texts = [
        "my card is 4095-2609-9393-4932",
        "call me at 212-555-5555 or email a@example.com",
        "IBAN GB82 WEST 1234 5698 7654 32 and ip 192.168.0.1",
        "my nhs number 401-023-2137, bank account 12345678",
        "Dr. Smith visited on 12/01/2020 — https://example.com/x",
    ]

    @Test("a shared engine with no NLP model is safe under concurrent use")
    func sharedEngineNoNlp() async throws {
        let engine = try AnalyzerEngine.makeDefault()
        let expected = try Self.texts.map { try engine.analyze(text: $0) }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    for (index, text) in Self.texts.enumerated() {
                        let got = try engine.analyze(text: text)
                        #expect(got == expected[index])
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    /// The tokenizer keeps a memoization cache, so this is the path where a
    /// shared pipeline actually mutates state on every call.
    ///
    /// **The text must be novel per task.** An earlier version of this test
    /// reused a fixed corpus and computed the expected results serially first,
    /// which warmed the cache — so the concurrent tasks only ever *read* it and
    /// ThreadSanitizer saw nothing. Verified by deliberately removing the lock
    /// on a branch: the old test passed under TSan with the race present. Each
    /// task now writes cache entries the others are simultaneously reading.
    @Test("a shared tokenizer-backed engine is safe under concurrent use")
    func sharedEngineWithTokenizer() async throws {
        var registry = try RecognizerRegistry.loadPredefined()
        registry.add(SpacyRecognizer())
        let engine = try AnalyzerEngine(
            registry: registry, nlpEngine: try TokenizerOnlyNlpEngine()
        )

        // Unique per (task, round) so every call misses the cache and writes,
        // with enough shared vocabulary that reads and writes collide.
        func text(task: Int, round: Int) -> String {
            "Case \(task)-\(round): Dr. Smith\(round) called D.J. O'Neill-\(task) "
            + "re: acct \(task)\(round)00, N.Y. office, isn't it? e.g. 4095-2609-9393-4932"
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for task in 0..<8 {
                group.addTask {
                    for round in 0..<60 {
                        let subject = text(task: task, round: round)
                        let got = try engine.analyze(text: subject)
                        // Same input must give the same answer whatever else
                        // is running; recomputing serially here would just warm
                        // the cache again, so compare against a second pass.
                        #expect(try engine.analyze(text: subject) == got)
                        #expect(got.contains { $0.entityType == "CREDIT_CARD" })
                    }
                }
            }
            try await group.waitForAll()
        }
    }
}

/// The model path, shared across tasks.
///
/// Ten types in this package are `@unchecked Sendable`, and eight of them are on
/// the model path: the tokenizer, `NERModel`, `Tok2Vec`, the parser, the tagger,
/// both lemmatizers, and the two engines that compose them. `@unchecked` means
/// the compiler is not checking, so what stood behind those annotations was a
/// paragraph of reasoning in each doc comment — including two I wrote myself,
/// one of which says "audited rather than assumed". Auditing is not running.
///
/// The suite above could not cover them: it predates the model being bundled, so
/// it uses `TokenizerOnlyNlpEngine` and the weights were not there to load. They
/// are now, which makes this free of any download.
///
/// **Scoped deliberately small.** ThreadSanitizer multiplies the cost of model
/// inference, and this runs under it in CI. Six tasks of ten short documents
/// exercise every shared component on every iteration; more rounds would buy
/// repetition, not coverage.
/// Gated on the model resolving out of the bundle rather than assumed present.
/// It is compiled in, but this suite runs under ThreadSanitizer on Linux in CI,
/// and a resource bundle that fails to resolve on some platform should skip here
/// rather than fail as if it were a race. CI greps for the line this prints, so
/// a skip cannot pass for a run.
func bundledModelDirectory() -> String? { EnglishModel.directoryIfPresent }

@Suite("Concurrency (model)", .enabled(if: bundledModelDirectory() != nil))
struct ModelConcurrencyTests {

    /// Unique per (task, round) so every call misses the tokenizer's memoization
    /// cache and writes to it while the other tasks are reading — the property
    /// the suite above learned the hard way, having once warmed the cache in a
    /// serial pass first and so tested nothing.
    ///
    /// The shared vocabulary is deliberate: overlapping prefixes make the reads
    /// and writes collide rather than merely coexist.
    static func text(task: Int, round: Int) -> String {
        "Dr. Anna Muller\(round) of Northwind\(task) Ltd. flew to Berlin on "
        + "\(round + 1)/03/2021. Munich was next. Card 4095-2609-9393-4932, "
        + "acct \(task)\(round)00, a\(task)@example.com."
    }

    @Test("a shared SpacyNlpEngine is safe and deterministic under concurrent use")
    func sharedModelEngine() async throws {
        let nlp = try SpacyNlpEngine(modelDirectory: bundledModelDirectory()!)
        // The configuration this actually ships: NER borrows the lemmatizer's
        // parse, so one document drives the tokenizer, tok2vec, tagger, parser,
        // attribute ruler, lemmatizer and NER at once.
        #expect(nlp.sharesLemmatizerParse)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for task in 0..<6 {
                group.addTask {
                    for round in 0..<10 {
                        let subject = Self.text(task: task, round: round)
                        let first = nlp.process(text: subject, language: "en")
                        // Compared against a second concurrent pass rather than
                        // a serial one computed up front: computing it first
                        // would warm every cache and leave the tasks reading.
                        let second = nlp.process(text: subject, language: "en")
                        #expect(first.tokens == second.tokens)
                        #expect(first.lemmas == second.lemmas)
                        #expect(
                            first.entities.map(\.start) == second.entities.map(\.start)
                        )
                        #expect(first.entities.contains { $0.label == "PERSON" })
                    }
                }
            }
            try await group.waitForAll()
        }
        print("Model concurrency: SpacyNlpEngine over 6 tasks x 10 documents")
    }

    @Test("a shared analyzer engine with the model is safe under concurrent use")
    func sharedAnalyzerWithModel() async throws {
        var registry = try RecognizerRegistry.loadPredefined()
        registry.add(SpacyRecognizer())
        let engine = try AnalyzerEngine(
            registry: registry,
            nlpEngine: try SpacyNlpEngine(modelDirectory: bundledModelDirectory()!)
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            for task in 0..<6 {
                group.addTask {
                    for round in 0..<10 {
                        let subject = Self.text(task: task, round: round)
                        let got = try engine.analyze(text: subject)
                        #expect(try engine.analyze(text: subject) == got)
                        #expect(got.contains { $0.entityType == "CREDIT_CARD" })
                        #expect(got.contains { $0.entityType == "PERSON" })
                    }
                }
            }
            try await group.waitForAll()
        }
        print("Model concurrency: AnalyzerEngine over 6 tasks x 10 documents")
    }
}
