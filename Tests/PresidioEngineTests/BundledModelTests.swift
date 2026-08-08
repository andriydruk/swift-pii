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

    /// Every snippet in the README's parser section, asserted.
    ///
    /// The bundled model carries `parser/` again after it was once dropped as
    /// "files nothing reads", so this is also the test that would fail if the
    /// trimming script removed it a second time — the parser going missing is
    /// otherwise silent, since NER still works, just not the way spaCy does.
    @Test("the bundled model parses sentences by default")
    func parsesSentencesOutOfTheBox() throws {
        let ner = try SpacyNER(modelDirectory: EnglishModel.directory)
        #expect(ner.parsesSentences, "parser/ is missing from the bundled model")

        let text = "| | KR_PASSPORT| The Korean Passport Number | Pattern match, context."
        #expect(
            ner.entities(in: text).map { "\($0.start),\($0.end),\($0.label)" }
                == ["17,43,ORG"]
        )

        let parse = try #require(ner.parse("She flew to Berlin. Munich was next."))
        #expect(parse.sentenceStarts == [0, 5])
        #expect(parse.heads == [1, 1, 1, 2, 1, 6, 6, 6, 6])
        #expect(parse.deps.prefix(3) == ["nsubj", "ROOT", "prep"])
    }

    /// The one way to build a correct engine that quietly does the work twice.
    ///
    /// `SpacyRuleLemmatizer` defaults to not parsing, which is right standing
    /// alone — no parser-dependent ruler rule changes a lemma, measured over
    /// 5,513 tokens. But the engine wants that parse for NER's boundaries, so
    /// supplying what looks like the default produces an engine ~14% slower with
    /// byte-identical output. Nothing can detect that from the results, which is
    /// exactly why it needs to be said out loud.
    @Test("an engine that parses twice says so")
    func duplicateParseIsWarnedAbout() throws {
        let directory = EnglishModel.directory

        let byDefault = try SpacyNlpEngine(modelDirectory: directory)
        #expect(byDefault.sharesLemmatizerParse)
        #expect(byDefault.warnings.isEmpty)

        let supplied = try SpacyNlpEngine(
            modelDirectory: directory,
            lemmatizer: try SpacyRuleLemmatizer(modelDirectory: directory)
        )
        #expect(!supplied.sharesLemmatizerParse)
        #expect(
            supplied.warnings.contains { $0.contains("second one") },
            "no warning about the duplicate parse: \(supplied.warnings)"
        )

        // Asking for the parse explicitly is the documented fix, and it has to
        // actually work or the warning is pointing at nothing.
        let fixed = try SpacyNlpEngine(
            modelDirectory: directory,
            lemmatizer: try SpacyRuleLemmatizer(
                modelDirectory: directory, parseDependencies: true
            )
        )
        #expect(fixed.sharesLemmatizerParse)
        #expect(fixed.warnings.isEmpty)
    }

    /// The engine gets its sentence boundaries from the lemmatizer's tok2vec
    /// pass rather than from a second parser inside NER, which is worth ~14% of
    /// `process` (5.64 vs 6.55 ms/document, A/B in one `presidio-bench` run) and
    /// 6 MB of duplicate weights.
    ///
    /// That optimisation is only sound if the two paths agree, so this asserts
    /// they do rather than reasoning that they must. They share the weights and
    /// the tokenization, so a divergence would mean the plumbing is wrong — the
    /// boundaries arriving empty, say, which would silently give
    /// spaCy-without-a-parser NER while everything still looked fine.
    @Test("sharing the lemmatizer's parse changes nothing it detects")
    func sharedParseAgreesWithItsOwn() throws {
        let directory = EnglishModel.directory
        let shared = try SpacyNlpEngine(modelDirectory: directory)
        // A caller-supplied rule lemmatizer does not parse, so NER falls back to
        // loading a parser of its own — the other path through `process`.
        let unshared = try SpacyNlpEngine(
            modelDirectory: directory,
            lemmatizer: try SpacyRuleLemmatizer(modelDirectory: directory)
        )
        #expect(shared.sharesLemmatizerParse)
        #expect(!unshared.sharesLemmatizerParse)

        let texts = [
            "Dr. Sarah Chen from Northwind Health called on March 3rd. She lives in Portland.",
            "| | KR_PASSPORT| The Korean Passport Number | Pattern match, context.",
            "I flew to Berlin. Munich was next. Paris after that.",
            "David Johnson works at Microsoft in Seattle and has identities to verify.",
        ]
        for text in texts {
            let a = shared.process(text: text, language: "en")
            let b = unshared.process(text: text, language: "en")
            #expect(
                a.entities.map { "\($0.start),\($0.end),\($0.label)" }
                    == b.entities.map { "\($0.start),\($0.end),\($0.label)" },
                "entities differ on \(text.debugDescription)"
            )
            #expect(a.lemmas == b.lemmas, "lemmas differ on \(text.debugDescription)")
        }
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
