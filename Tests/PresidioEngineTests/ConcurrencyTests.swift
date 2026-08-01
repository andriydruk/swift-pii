import Testing
import PresidioCore
import PresidioAnalyzer
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
    @Test("a shared tokenizer-backed engine is safe under concurrent use")
    func sharedEngineWithTokenizer() async throws {
        var registry = try RecognizerRegistry.loadPredefined()
        registry.add(SpacyRecognizer())
        let engine = try AnalyzerEngine(
            registry: registry, nlpEngine: try TokenizerOnlyNlpEngine()
        )
        let expected = try Self.texts.map { try engine.analyze(text: $0) }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    for _ in 0..<20 {
                        for (index, text) in Self.texts.enumerated() {
                            let got = try engine.analyze(text: text)
                            #expect(got == expected[index])
                        }
                    }
                }
            }
            try await group.waitForAll()
        }
    }
}
