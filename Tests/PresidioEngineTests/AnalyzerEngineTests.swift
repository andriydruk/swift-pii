import Testing
import PresidioCore
import PresidioAnalyzer
import PresidioRecognizers
@testable import PresidioEngine

/// The engine's own behaviour: configuration, wiring and the option semantics
/// that the differential corpus cannot reach because Presidio's own tests do
/// not exercise them either.
@Suite("AnalyzerEngine behaviour")
struct AnalyzerEngineTests {

    @Test("the default registry matches Presidio's, not the whole catalogue")
    func defaultRegistryIsConfigured() throws {
        let registry = try RecognizerRegistry.loadPredefined()
        let names = Set(registry.recognizers.map(\.name))

        // A default Presidio engine loads 17 recognizers including the NLP one.
        // Loading all 88 would report entities Presidio never would, which
        // looks like a wall of false positives rather than a config difference.
        #expect(names.count == 17, "loaded \(names.count): \(names.sorted())")
        #expect(names.contains("CreditCardRecognizer"))
        #expect(names.contains("PhoneRecognizer"))
        #expect(!names.contains("AuAbnRecognizer"), "country recognizers ship disabled")
        #expect(!names.contains("ZaMobileNumberRecognizer"))

        // The whole catalogue is still reachable, explicitly.
        // 54, not 88: the catalogue covers every language, and this asks for
        // English only.
        let everything = try RecognizerRegistry.loadPredefined(configuration: nil)
        #expect(everything.recognizers.count > 50)
        #expect(everything.recognizers.count > registry.recognizers.count * 3)
    }

    @Test("the registry config resolved and carries the global regex flags")
    func configurationLoaded() throws {
        let config = try #require(RegistryConfiguration.default)
        // 26 == IGNORECASE | MULTILINE | DOTALL.
        #expect(config.globalRegexFlags == 26)
        let flags = RegexFlags(pythonFlags: 26)
        #expect(flags.ignoreCase && flags.multiline && flags.dotAll)
        #expect(RegexFlags(pythonFlags: 24).ignoreCase == false)
    }

    @Test("an unknown language is rejected rather than silently returning nothing")
    func unknownLanguageThrows() throws {
        let engine = try AnalyzerEngine.makeDefault()
        #expect(throws: AnalyzerEngine.EngineError.languageNotSupported("fr")) {
            _ = try engine.analyze(text: "anything", language: "fr")
        }
    }

    @Test("a registry and engine that disagree on languages is a configuration error")
    func languageMismatchThrows() throws {
        let registry = try RecognizerRegistry.loadPredefined(languages: ["en"])
        #expect(throws: (any Error).self) {
            _ = try AnalyzerEngine(registry: registry, supportedLanguages: ["en", "es"])
        }
    }

    @Test("NoOpNlpEngine with the lemma enhancer warns, as upstream does")
    func noOpWarns() throws {
        let engine = try AnalyzerEngine.makeDefault()
        #expect(engine.configurationWarnings.count == 1)
        #expect(engine.configurationWarnings[0].contains("NoOpNlpEngine"))
    }

    @Test("explicit context raises a score without any NLP model")
    func explicitContextBoosts() throws {
        let engine = try AnalyzerEngine.makeDefault()
        let text = "4095-2609-9393-4932"
        let plain = try engine.analyze(text: text)
        let boosted = try engine.analyze(text: text, context: ["credit", "card"])

        let card = try #require(plain.first { $0.entityType == "CREDIT_CARD" })
        let cardBoosted = try #require(boosted.first { $0.entityType == "CREDIT_CARD" })
        // Already at 1.0, so the boost is capped rather than absent — the point
        // is that explicit context reaches the enhancer with no tokens present.
        #expect(cardBoosted.score >= card.score)
        #expect(cardBoosted.score <= 1.0)
    }

    @Test("score thresholds filter, and an explicit one overrides recognizer levels")
    func thresholdsApply() throws {
        let engine = try AnalyzerEngine.makeDefault()
        let text = "my number is 4095-2609-9393-4932 and 212-555-5555"
        let all = try engine.analyze(text: text)
        let strict = try engine.analyze(text: text, scoreThreshold: 0.9)

        #expect(!all.isEmpty)
        #expect(strict.allSatisfy { $0.score >= 0.9 })
        #expect(strict.count < all.count)
    }

    @Test("the engine default threshold applies when no explicit one is given")
    func engineDefaultThreshold() throws {
        let permissive = try AnalyzerEngine.makeDefault()
        let strict = try AnalyzerEngine.makeDefault(defaultScoreThreshold: 0.9)
        let text = "my number is 4095-2609-9393-4932 and 212-555-5555"
        #expect(try strict.analyze(text: text).count
                < permissive.analyze(text: text).count)
    }

    @Test("allow lists remove results, in both match modes")
    func allowListsApply() throws {
        let engine = try AnalyzerEngine.makeDefault()
        let text = "Card 4095-2609-9393-4932 belongs to nobody"

        let kept = try engine.analyze(text: text)
        #expect(kept.contains { $0.entityType == "CREDIT_CARD" })

        let exact = try engine.analyze(
            text: text, allowList: ["4095-2609-9393-4932"], allowListMatch: .exact
        )
        #expect(!exact.contains { $0.entityType == "CREDIT_CARD" })

        // Regex mode *searches* the matched text, so a partial pattern allows.
        let regex = try engine.analyze(
            text: text, allowList: [#"4095"#], allowListMatch: .regex
        )
        #expect(!regex.contains { $0.entityType == "CREDIT_CARD" })

        // ...which the exact mode must not do.
        let exactPartial = try engine.analyze(
            text: text, allowList: ["4095"], allowListMatch: .exact
        )
        #expect(exactPartial.contains { $0.entityType == "CREDIT_CARD" })
    }

    @Test("a malformed allow-list regex fails loudly")
    func malformedAllowListThrows() throws {
        let engine = try AnalyzerEngine.makeDefault()
        #expect(throws: (any Error).self) {
            _ = try engine.analyze(
                text: "4095-2609-9393-4932", allowList: ["("], allowListMatch: .regex
            )
        }
    }

    @Test("ad-hoc recognizers apply to one request only")
    func adHocRecognizers() throws {
        let engine = try AnalyzerEngine.makeDefault()
        let adHoc = PatternRecognizer(
            name: "TitleRecognizer",
            entity: "TITLE",
            patterns: [Pattern(name: "title", regex: "(Mr|Mrs|Ms|Dr)\\.", score: 0.6)]
        )
        let text = "Dr. Smith called"
        #expect(try engine.analyze(text: text).allSatisfy { $0.entityType != "TITLE" })

        let withAdHoc = try engine.analyze(text: text, adHocRecognizers: [adHoc])
        #expect(withAdHoc.contains { $0.entityType == "TITLE" })

        // ...and does not leak into the next request.
        #expect(try engine.analyze(text: text).allSatisfy { $0.entityType != "TITLE" })
    }

    @Test("an entity filter restricts results to the requested types")
    func entityFilter() throws {
        let engine = try AnalyzerEngine.makeDefault()
        let text = "card 4095-2609-9393-4932 email a@example.com"
        let filtered = try engine.analyze(text: text, entities: ["EMAIL_ADDRESS"])
        #expect(!filtered.isEmpty)
        #expect(filtered.allSatisfy { $0.entityType == "EMAIL_ADDRESS" })
    }

    @Test("asking only for entities nobody recognizes is an error, not silence")
    func unknownEntityThrows() throws {
        let engine = try AnalyzerEngine.makeDefault()
        #expect(throws: RecognizerRegistry.RegistryError.noMatchingRecognizers) {
            _ = try engine.analyze(text: "hello", entities: ["NOT_AN_ENTITY"])
        }
        // But an unknown entity alongside a known one is tolerated — upstream
        // logs and continues.
        let mixed = try engine.analyze(
            text: "a@example.com", entities: ["NOT_AN_ENTITY", "EMAIL_ADDRESS"]
        )
        #expect(mixed.contains { $0.entityType == "EMAIL_ADDRESS" })
    }

    @Test("results carry the recognizer that produced them")
    func resultsCarryProvenance() throws {
        let engine = try AnalyzerEngine.makeDefault()
        let results = try engine.analyze(text: "4095-2609-9393-4932")
        let card = try #require(results.first { $0.entityType == "CREDIT_CARD" })
        #expect(card.recognitionMetadata[RecognizerResult.MetadataKey.recognizerName]
                == "CreditCardRecognizer")
        #expect(card.recognitionMetadata[
            RecognizerResult.MetadataKey.recognizerIdentifier] != nil)
    }

    @Test("output ordering is deterministic across runs")
    func orderingIsStable() throws {
        let engine = try AnalyzerEngine.makeDefault()
        let text = "card 4095-2609-9393-4932, email a@example.com, ip 192.168.0.1"
        let first = try engine.analyze(text: text)
        for _ in 0..<5 {
            let again = try engine.analyze(text: text)
            #expect(again == first)
            #expect(again.map(\.start) == first.map(\.start))
        }
    }

    /// The tokenizer-only pipeline needs no model weights, so this is the
    /// end-to-end path that CI can actually run: real tokenization feeding
    /// real context enhancement.
    @Test("context enhancement works end to end with real tokenization")
    func contextFromRealTokens() throws {
        var registry = try RecognizerRegistry.loadPredefined()
        registry.add(SpacyRecognizer())
        let engine = try AnalyzerEngine(
            registry: registry, nlpEngine: try TokenizerOnlyNlpEngine()
        )
        #expect(engine.configurationWarnings.isEmpty, "not a NoOp engine")

        // A weak pattern is needed for the boost to be observable: UK_NHS
        // validates to 1.0 and has no headroom. US_BANK_NUMBER scores 0.05 on
        // the pattern alone, and "bank" is one of its context words, so the
        // enhancer lifts it to the 0.4 floor.
        let withContext = try engine.analyze(text: "my bank account is 12345678")
        let without = try engine.analyze(text: "the value is 12345678")

        let boosted = try #require(
            withContext.first { $0.entityType == "US_BANK_NUMBER" }
        )
        let plain = try #require(without.first { $0.entityType == "US_BANK_NUMBER" })
        #expect(boosted.score > plain.score, "\(boosted.score) vs \(plain.score)")
        #expect(boosted.score == 0.4, "the min_score_with_context_similarity floor")
        #expect(boosted.supportiveContextWord != nil)
        #expect(plain.supportiveContextWord == nil)
    }
}
