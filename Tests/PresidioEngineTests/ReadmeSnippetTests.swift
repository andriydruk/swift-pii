import Testing
import PresidioEngine
import PresidioAnalyzer
import PresidioRecognizers
import PresidioAnonymizer
import PresidioModelEnglish
import PresidioNLP

@Suite("README snippets")
struct ReadmeSnippetTests {
    @Test("quick start") func quickStart() throws {
        let detector = try PIIDetector()
        let findings = try detector.findings(in: "Card 4095-2609-9393-4932, call 212-555-5555")
        let described = findings.map { "\($0.type) \($0.text) \($0.confidence)" }
        #expect(described.contains { $0.hasPrefix("CREDIT_CARD 4095-2609-9393-4932 1.0") }, "\(described)")
        #expect(described.contains { $0.hasPrefix("PHONE_NUMBER 212-555-5555 0.4") }, "\(described)")
        // The README's context-scoring claim.
        let bank = try detector.findings(in: "bank account 12345678")
        #expect(bank.first { $0.type == "US_BANK_NUMBER" }?.confidence == 0.4)
        let bare = try detector.findings(in: "12345678")
        #expect(bare.first { $0.type == "US_BANK_NUMBER" }?.confidence == 0.05)
    }

    @Test("redact") func redact() throws {
        let detector = try PIIDetector()
        let text = "Card 4095-2609-9393-4932, call 212-555-5555"
        #expect(try Anonymizer().redact(text, using: detector)
                == "Card <CREDIT_CARD>, call <PHONE_NUMBER>")
    }

    @Test("operators") func operators() throws {
        let detector = try PIIDetector()
        let a = Anonymizer()
        let text = "Card 4095-2609-9393-4932"
        #expect(try a.mask(text, using: detector, character: "*") == "Card *******************")
        #expect(try a.replace(text, using: detector, with: ["CREDIT_CARD": "[removed]"]) == "Card [removed]")
        #expect(try a.remove(text, using: detector) == "Card ")
        #expect(try a.mask(text, using: detector, character: "*", keepingLast: 4).hasSuffix("4932"))
        let hashed = try a.hash(text, using: detector, salt: "0123456789abcdef")
        #expect(hashed.hasPrefix("Card ") && !hashed.contains("4095"))
    }

    @Test("tuning") func tuning() throws {
        let detector = try PIIDetector()
        let text = "Card 4095-2609-9393-4932 and support@example.com"
        #expect(try detector.findings(in: text, types: ["EMAIL_ADDRESS"]).allSatisfy { $0.type == "EMAIL_ADDRESS" })
        #expect(try detector.findings(in: text, minimumConfidence: 0.6).allSatisfy { $0.confidence >= 0.6 })
        #expect(try !detector.findings(in: text, allowing: ["support@example.com"]).contains { $0.type == "EMAIL_ADDRESS" })
        #expect(try detector.containsPII(text))
        let finding = try #require(detector.findings(in: text).first)
        let range = try #require(finding.range(in: text))
        #expect(String(text[range]) == finding.text)
    }

    /// The README's Errors section, and the taxonomy claim behind it.
    ///
    /// Four component loaders used to throw four enums with identical cases.
    /// They are aliases now, so a single `catch` covers the whole domain — which
    /// is the claim the README makes and therefore the one worth testing.
    @Test("errors") func errors() throws {
        var caught: String?
        do {
            _ = try SpacyNER(modelDirectory: "/nonexistent/model/path")
        } catch let error as ComponentLoadError {
            caught = "\(error)"
        }
        let message = try #require(caught)
        #expect(message.contains("/nonexistent/model/path"))
        // The remediation NERError carried before the merge, kept rather than
        // flattened to the shorter message the other three had.
        #expect(message.contains("unpacked spaCy model directory"))

        // The aliases really are the same type, not four that happen to agree.
        #expect(NERError.self == ComponentLoadError.self)
        #expect(TaggerModel.LoadError.self == ComponentLoadError.self)
        #expect(DependencyParser.LoadError.self == ComponentLoadError.self)
        #expect(EditTreeLemmatizer.LoadError.self == ComponentLoadError.self)

        // The bundled-resource domain stays separate, which is the other half
        // of the claim: it is a different failure with a different audience.
        #expect(throws: SpacyTokenizer.LoadError.self) {
            _ = try SpacyTokenizer.forLanguage("qq")
        }
    }

    @Test("model product") func modelProduct() throws {
        let detector = try PIIDetector(
            nlpEngine: try SpacyNlpEngine(modelDirectory: EnglishModel.directory)
        )
        let findings = try detector.findings(in: "David Johnson lives in Seattle")
        #expect(findings.contains { $0.type == "PERSON" })
        #expect(findings.contains { $0.type == "LOCATION" })
    }
}

/// The README's "choosing recognizers" and "custom recognizer" snippets.
@Suite("README customization")
struct ReadmeCustomizationTests {

    @Test("enabling a disabled country recognizer")
    func enableCountryRecognizer() throws {
        var registry = try RecognizerRegistry.loadPredefined()
        #expect(registry.recognizers.count == 17)
        // An English-language recognizer that ships disabled. A German one
        // would be built and then never selected, because the registry filters
        // on language — see LanguageTests.
        let name = "AuMedicareRecognizer"
        if let definition = try Catalog.definitions().first(where: { $0.class == name }),
           let recognizer = Catalog.makeRecognizer(
               definition, logic: ValidatorRegistry.logic(for: name)
           ) {
            registry.add(recognizer)
        }
        #expect(registry.recognizers.count == 18)
        let detector = try PIIDetector(engine: AnalyzerEngine(registry: registry))
        #expect(detector.supportedTypes.contains("AU_MEDICARE"))
    }

    @Test("loading every recognizer")
    func loadEverything() throws {
        let all = try RecognizerRegistry.loadPredefined(configuration: nil)
        #expect(all.recognizers.count > 50)
    }

    @Test("a custom pattern recognizer")
    func customRecognizer() throws {
        var registry = try RecognizerRegistry.loadPredefined()
        registry.add(PatternRecognizer(
            name: "EmployeeID",
            entity: "EMPLOYEE_ID",
            patterns: [Pattern(name: "emp", regex: #"EMP-\d{6}"#, score: 0.8)],
            context: ["employee", "staff", "badge"]
        ))
        let detector = try PIIDetector(engine: AnalyzerEngine(registry: registry))
        let findings = try detector.findings(in: "Badge EMP-004821 issued")
        #expect(findings.contains { $0.type == "EMPLOYEE_ID" })
    }

    @Test("a deny list recognizer")
    func denyListRecognizer() throws {
        var registry = try RecognizerRegistry.loadPredefined()
        registry.add(PatternRecognizer.denyList(
            name: "Projects", entity: "PROJECT", terms: ["Bluebird", "Halcyon"]
        ))
        let detector = try PIIDetector(engine: AnalyzerEngine(registry: registry))
        let findings = try detector.findings(in: "Project Bluebird is late")
        #expect(findings.contains { $0.type == "PROJECT" && $0.text == "Bluebird" })
    }

    @Test("batch analysis over a dictionary")
    func batch() throws {
        let detector = try PIIDetector()
        let batch = BatchAnalyzerEngine(analyzer: detector.engine)
        let results = try batch.analyzeDictionary([
            ("customer_email", .text("a@example.com")),
            ("notes", .text("called them back")),
        ])
        #expect(results.count == 2)
        #expect(results[0].results.flattened.contains { $0.entityType == "EMAIL_ADDRESS" })
        let lists = try batch.analyze(texts: ["first a@example.com", "second"])
        #expect(lists.count == 2)
    }
}
