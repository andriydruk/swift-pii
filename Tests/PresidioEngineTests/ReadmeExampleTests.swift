import Testing
import PresidioEngine
import PresidioAnonymizer

/// Pins the README's quick-start example.
///
/// A README example that no longer works is worse than none, and the offsets in
/// this one were wrong when first written — guessed rather than run. Making the
/// snippet a test is what stops it drifting.
@Suite("README example")
struct ReadmeExampleTests {

    @Test("the quick-start example produces exactly what the README claims")
    func quickStart() throws {
        let text = "card 4095-2609-9393-4932, mail a@example.com"

        let engine = try AnalyzerEngine.makeDefault()
        let found = try engine.analyze(text: text)

        let described = found.map {
            "\($0.entityType) \($0.start)..<\($0.end) (\($0.score))"
        }
        #expect(
            described == [
                "CREDIT_CARD 5..<24 (1.0)",
                "EMAIL_ADDRESS 31..<44 (1.0)",
                "URL 33..<44 (0.5)",
            ],
            "\(described)"
        )

        let clean = try AnonymizerEngine().anonymize(text: text, analyzerResults: found)
        #expect(clean.text == "card <CREDIT_CARD>, mail <EMAIL_ADDRESS>")
    }

    /// The README claims a default engine needs no model weights. If that
    /// stopped being true, the quick start would fail for every new reader.
    @Test("the default engine loads without model weights")
    func noWeightsNeeded() throws {
        let engine = try AnalyzerEngine.makeDefault()
        #expect(engine.registry.recognizers.count == 17)
        #expect(try !engine.analyze(text: "4095-2609-9393-4932").isEmpty)
    }
}
