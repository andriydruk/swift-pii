import Testing
import PresidioNLP
import PresidioAnalyzer
import PresidioRecognizers
@testable import PresidioEngine

/// Languages other than English.
///
/// The recognizer catalogue is not English-only — 37 of its 88 entries declare
/// another language — but the registry filters on the recognizer's own
/// `supportedLanguage`, and `PatternRecognizer` used to inherit the protocol's
/// default of `"en"`. Every non-English recognizer was therefore built, held in
/// the registry, and never selected. These tests exist so that cannot recur.
@Suite("Non-English languages")
struct LanguageTests {

    @Test("the catalogue really is multilingual")
    func catalogueIsMultilingual() throws {
        let definitions = try Catalog.definitions()
        let byLanguage = Dictionary(grouping: definitions, by: \.language)
        #expect(byLanguage["en"]!.count == 51)
        #expect(byLanguage.keys.count >= 10, "\(byLanguage.keys.sorted())")
        for language in ["de", "es", "it", "pl", "ko", "sv", "th", "tr", "fi"] {
            #expect(byLanguage[language]?.isEmpty == false, "no \(language) recognizers")
        }
    }

    @Test("a recognizer reports the language it was built for")
    func recognizerCarriesItsLanguage() throws {
        let definitions = try Catalog.definitions()
        let german = try #require(definitions.first { $0.class == "DeTaxIdRecognizer" })
        let recognizer = try #require(Catalog.makeRecognizer(
            german, logic: ValidatorRegistry.logic(for: "DeTaxIdRecognizer")
        ))
        #expect(recognizer.language == "de")
        #expect(recognizer.supportedLanguage == "de", "the registry filters on this")
    }

    @Test("German recognizers detect German identifiers")
    func germanEndToEnd() throws {
        let registry = try RecognizerRegistry.loadPredefined(
            languages: ["de"], configuration: nil
        )
        #expect(registry.recognizers.count >= 13)

        let engine = try AnalyzerEngine(
            registry: registry,
            nlpEngine: try TokenizerOnlyNlpEngine(supportedLanguages: ["de"]),
            supportedLanguages: ["de"]
        )
        let found = try engine.analyze(
            text: "Die Steuer-ID lautet 65929970489.", language: "de"
        )
        #expect(found.contains { $0.entityType == "DE_TAX_ID" }, "\(found)")
    }

    /// A default non-English registry is not empty, and this test used to
    /// assert that it was.
    ///
    /// That was the bug written down as a specification. The 13 German
    /// recognizers do ship `enabled: false` upstream, which is what the old
    /// assertion was reasoning from — but the ten *language-agnostic* entries
    /// (e-mail, IP, URL, IBAN, phone, crypto, date, MAC, UUID, medical licence)
    /// declare no `supported_languages` at all, and upstream builds those for
    /// whatever language you ask for. See `RegistryLanguageTests` for the
    /// differential against upstream's own loader.
    @Test("a default non-English registry holds the language-agnostic set")
    func defaultForOtherLanguages() throws {
        let german = try RecognizerRegistry.loadPredefined(languages: ["de"])
        #expect(german.recognizers.count == 10)
        #expect(german.recognizers.allSatisfy { $0.supportedLanguage == "de" })
        // None of the German-specific ones: those really are disabled upstream.
        #expect(!german.recognizers.contains { $0.name.hasPrefix("De") })

        #expect(try RecognizerRegistry.loadPredefined().recognizers.count == 17)
    }

    /// The user-visible point of the language expansion: a Spanish engine, set
    /// up the ordinary way, finds the things that are not Spanish-specific.
    ///
    /// Before the fix this returned Spanish national IDs and nothing else — no
    /// e-mail, no IP, no URL — because those recognizers declare no language
    /// and were therefore treated as English-only.
    @Test("a default Spanish engine finds language-agnostic PII")
    func spanishEndToEnd() throws {
        let registry = try RecognizerRegistry.loadPredefined(languages: ["es"])
        let engine = try AnalyzerEngine(
            registry: registry,
            nlpEngine: try TokenizerOnlyNlpEngine(supportedLanguages: ["es"]),
            supportedLanguages: ["es"]
        )
        let found = try engine.analyze(
            text: "Escríbele a ana.lopez@example.com desde 192.168.0.14. "
                // Check letter is "TRWAGMYFPDXBNJZSQVHLCKE"[n % 23]; the
                // recognizer validates it, so an invented one is not detected.
                + "Su NIF es 20899533P.",
            language: "es"
        )
        let types = Set(found.map(\.entityType))
        #expect(types.contains("EMAIL_ADDRESS"), "\(found)")
        #expect(types.contains("IP_ADDRESS"), "\(found)")
        #expect(types.contains("ES_NIF"), "\(found)")
    }

    /// What is genuinely English-only, so the limits are stated rather than
    /// discovered.
    @Test("the NLP layer is English")
    func nlpLayerIsEnglish() {
        #expect(LexicalTables.isStopWord("the", language: "en"))
        #expect(!LexicalTables.isStopWord("der", language: "de"),
                "no German stop words are bundled")
        #expect(!LexicalTables.isStopWord("the", language: "de"),
                "the table is not consulted for other languages at all")
    }
}
