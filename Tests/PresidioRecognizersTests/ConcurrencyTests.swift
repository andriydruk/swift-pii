import Testing
import Foundation
import PresidioConformance
import PresidioCore
import PresidioAnalyzer
@testable import PresidioRecognizers

/// `Sendable` conformance is a compile-time claim; these check it at run time.
///
/// The 155 patterns are independent, so sweeping them concurrently is the
/// largest speedup available — measured at 7.3× on 14 cores, which is what
/// turns this engine from 4.5× slower than Python into ~1.7× faster. That is
/// only sound if a shared compiled pattern really carries no match state.
@Suite("Concurrent use")
struct ConcurrencyTests {

    @Test("one shared recognizer gives identical results across tasks")
    func sharedRecognizerIsSafe() async throws {
        let corpus = try Corpus.recognizerCases()
        // A recognizer with real patterns and real checksum logic.
        let definitions = try Catalog.definitions()
        guard let definition = definitions.first(where: { $0.class == "IbanRecognizer" }),
              let recognizer = Catalog.makeRecognizer(definition)
        else {
            Issue.record("IbanRecognizer not in the catalogue")
            return
        }

        let texts = corpus.tables
            .first { $0.recognizer == "IbanRecognizer" }?
            .cases.map(\.text) ?? []
        #expect(texts.count > 100)

        // Sequential baseline.
        let expected = texts.map { recognizer.analyze($0) }

        // The same recognizer, hammered from many tasks at once.
        let produced = await withTaskGroup(of: (Int, [RecognizerResult]).self) { group in
            for (index, text) in texts.enumerated() {
                group.addTask { (index, recognizer.analyze(text)) }
            }
            var results = [Int: [RecognizerResult]]()
            for await (index, value) in group { results[index] = value }
            return results
        }

        for (index, want) in expected.enumerated() {
            #expect(produced[index] == want, "task \(index) diverged")
        }
    }

    @Test("many recognizers over one text, concurrently")
    func concurrentRecognizersAgree() async throws {
        let definitions = try Catalog.definitions()
        let recognizers = definitions.compactMap { Catalog.makeRecognizer($0) }
        #expect(recognizers.count >= 80)

        let text = """
            Contact John at john@example.com or 212-555-5555. \
            Card 4095-2609-9393-4932, IBAN DE89370400440532013000, \
            IP 192.168.1.1, SSN 078-05-1123, MAC 00:1A:2B:3C:4D:5E.
            """

        let sequential = recognizers.map { $0.analyze(text) }
        let concurrent = await withTaskGroup(of: (Int, [RecognizerResult]).self) { group in
            for (index, recognizer) in recognizers.enumerated() {
                group.addTask { (index, recognizer.analyze(text)) }
            }
            var results = [Int: [RecognizerResult]]()
            for await (index, value) in group { results[index] = value }
            return results
        }

        for (index, want) in sequential.enumerated() {
            #expect(concurrent[index] == want, "recognizer \(index) diverged")
        }
        // Sanity: this text really does trip several recognizers, so the test
        // is not vacuously comparing empty arrays.
        #expect(sequential.reduce(0) { $0 + $1.count } >= 5)
    }

    /// Repeated concurrent use of a single compiled pattern, which is where a
    /// hidden mutable cache would show up as nondeterminism rather than a crash.
    @Test("a shared pattern is stable under repeated concurrent load")
    func sharedPatternIsStable() async throws {
        let definitions = try Catalog.definitions()
        guard let definition = definitions.first(where: { $0.class == "CreditCardRecognizer" }),
              let recognizer = Catalog.makeRecognizer(definition)
        else {
            Issue.record("CreditCardRecognizer not in the catalogue")
            return
        }
        let text = "cards: 4095-2609-9393-4932 and 4095260993934932 and 1234"
        let expected = recognizer.analyze(text)
        #expect(!expected.isEmpty)

        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<200 {
                group.addTask { recognizer.analyze(text) == expected }
            }
            for await same in group { #expect(same) }
        }
    }
}
