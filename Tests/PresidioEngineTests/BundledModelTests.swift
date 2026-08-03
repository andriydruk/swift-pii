import Testing
import PresidioCore
import PresidioNLP
import PresidioModelEnglish
@testable import PresidioEngine

/// The bundled model needs no setup at all — no env var, no download, no path.
@Suite("Bundled English model")
struct BundledModelTests {

    @Test("the model is in the bundle")
    func modelIsBundled() {
        #expect(EnglishModel.directoryIfPresent != nil)
        #expect(EnglishModel.version == "en_core_web_sm-3.7.1")
    }

    @Test("named entities work with no configuration")
    func entitiesWorkOutOfTheBox() throws {
        let nlp = try SpacyNlpEngine(modelDirectory: EnglishModel.directory)
        let artifacts = nlp.process(
            text: "David Johnson lives in Seattle and works at Microsoft.",
            language: "en"
        )
        let labels = Set(artifacts.entities.map(\.label))
        #expect(labels.contains("PERSON"))
        #expect(labels.contains("LOCATION"))
        #expect(labels.contains("ORGANIZATION"))
    }

    @Test("the bundled model gives exact lemmas by default")
    func lemmasAreExact() throws {
        let nlp = try SpacyNlpEngine(modelDirectory: EnglishModel.directory)
        #expect(nlp.lemmatizerKind == "spaCy rule-mode (exact)")
        #expect(nlp.warnings.isEmpty)
        // "was" -> "be" needs the tagger; the lookup table cannot do it.
        let artifacts = nlp.process(text: "The delivery was late", language: "en")
        #expect(artifacts.lemmas.contains("be"), "\(artifacts.lemmas)")
    }

    @Test("a full engine finds people alongside pattern-based entities")
    func endToEnd() throws {
        var registry = try RecognizerRegistry.loadPredefined()
        registry.add(SpacyRecognizer())
        let engine = try AnalyzerEngine(
            registry: registry,
            nlpEngine: try SpacyNlpEngine(modelDirectory: EnglishModel.directory)
        )
        let results = try engine.analyze(
            text: "David Johnson paid with card 4095-2609-9393-4932."
        )
        let types = Set(results.map(\.entityType))
        #expect(types.contains("PERSON"))
        #expect(types.contains("CREDIT_CARD"))
    }
}

/// The friendly entry point, which is what most callers should reach for.
@Suite("PIIDetector")
struct PIIDetectorTests {

    @Test("finds pattern-based data with no model")
    func worksWithoutAModel() throws {
        let detector = try PIIDetector()
        let findings = try detector.findings(
            in: "Card 4095-2609-9393-4932, email a@example.com, call 212-555-5555"
        )
        let types = Set(findings.map(\.type))
        #expect(types.contains("CREDIT_CARD"))
        #expect(types.contains("EMAIL_ADDRESS"))
        #expect(types.contains("PHONE_NUMBER"))
        // No warning: a tokenizer-only pipeline is the documented default, not
        // something the engine settled for. It simply finds no PERSON.
        #expect(detector.warnings.isEmpty)
        #expect(!types.contains("PERSON"))
    }

    @Test("a finding carries usable text and a real range")
    func findingsAreUsable() throws {
        let text = "Card 4095-2609-9393-4932 expires soon"
        let detector = try PIIDetector()
        let card = try #require(
            detector.findings(in: text).first { $0.type == "CREDIT_CARD" }
        )
        #expect(card.text == "4095-2609-9393-4932")
        #expect(card.confidence == 1.0)
        #expect(card.recognizer == "CreditCardRecognizer")
        let range = try #require(card.range(in: text))
        #expect(String(text[range]) == "4095-2609-9393-4932")
    }

    @Test("filters do what they say")
    func filters() throws {
        let text = "Card 4095-2609-9393-4932 and a@example.com"
        let detector = try PIIDetector()
        let emails = try detector.findings(in: text, types: ["EMAIL_ADDRESS"])
        #expect(emails.allSatisfy { $0.type == "EMAIL_ADDRESS" })
        let allowed = try detector.findings(in: text, allowing: ["a@example.com"])
        #expect(!allowed.contains { $0.type == "EMAIL_ADDRESS" })
        #expect(try detector.containsPII(text))
        #expect(try !detector.containsPII("nothing here at all"))
    }

    @Test("with the bundled model it also finds people")
    func withModel() throws {
        let detector = try PIIDetector(
            nlpEngine: try SpacyNlpEngine(modelDirectory: EnglishModel.directory)
        )
        let findings = try detector.findings(in: "David Johnson lives in Seattle")
        #expect(findings.contains { $0.type == "PERSON" })
        #expect(detector.warnings.isEmpty, "nothing degraded with a model")
    }
}
