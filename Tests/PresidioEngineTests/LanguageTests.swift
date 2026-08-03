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

    /// The default registry is English, as it is upstream — the non-English
    /// entries ship `enabled: false`. Opting in is `configuration: nil` or a
    /// config of your own.
    @Test("the default registry is English only")
    func defaultIsEnglish() throws {
        #expect(try RecognizerRegistry.loadPredefined(languages: ["de"]).recognizers.isEmpty)
        #expect(try RecognizerRegistry.loadPredefined().recognizers.count == 17)
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
