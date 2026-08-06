import Foundation
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

    /// What the NLP layer knows per language, and where it stops.
    ///
    /// Stop words are now bundled for German as well as English, and the lists
    /// are genuinely separate — "the" is not a German stop word, and asking
    /// about a language with no bundled list still answers `false`, but
    /// `hasStopWords(for:)` distinguishes that from a real answer.
    @Test("stop words are per language, and their absence is visible")
    func stopWordsPerLanguage() {
        #expect(LexicalTables.isStopWord("the", language: "en"))
        #expect(LexicalTables.isStopWord("der", language: "de"))
        #expect(LexicalTables.isStopWord("und", language: "de"))
        #expect(!LexicalTables.isStopWord("the", language: "de"))
        #expect(!LexicalTables.isStopWord("der", language: "en"))
        #expect(LexicalTables.germanStopWords.count == 543)

        #expect(LexicalTables.hasStopWords(for: "de"))
        #expect(!LexicalTables.hasStopWords(for: "fr"),
                "French has none bundled; that is a gap, not a claim about French")
        #expect(!LexicalTables.isStopWord("le", language: "fr"))
    }
}

/// German end to end: the whole stack in one language.
///
/// The layers were each verified against spaCy separately — tokenizer 699/699,
/// tagger 699/699, lemmas 699/699, NER 66/66 recall — and this is where they
/// have to agree simultaneously, with the recognizers and the context enhancer
/// on top.
@Suite("German end to end", .enabled(if: germanEngineModelDirectory() != nil))
struct GermanEngineTests {

    /// A German engine assembled the way a caller actually would.
    ///
    /// Two sources, because upstream splits them: the *default* registry for
    /// German supplies the ten language-agnostic recognizers (e-mail, IP, IBAN,
    /// phone...), while the 13 German national-identifier recognizers ship
    /// `enabled: false` and have to be asked for. Loading only the catalogue
    /// would give the second group and lose the first.
    static func engine() throws -> AnalyzerEngine {
        var registry = try RecognizerRegistry.loadPredefined(languages: ["de"])
        let catalogue = try RecognizerRegistry.loadPredefined(
            languages: ["de"], configuration: nil
        )
        for recognizer in catalogue.recognizers { registry.add(recognizer) }

        let nlp = try SpacyNlpEngine(
            modelDirectory: germanEngineModelDirectory()!, language: "de"
        )
        registry.add(SpacyRecognizer(supportedLanguage: "de"))
        return try AnalyzerEngine(
            registry: registry, nlpEngine: nlp, supportedLanguages: ["de"]
        )
    }

    @Test("the German pipeline reports exact lemmas, not an approximation")
    func usesEditTreeLemmatizer() throws {
        let nlp = try SpacyNlpEngine(
            modelDirectory: germanEngineModelDirectory()!, language: "de"
        )
        #expect(nlp.lemmatizerKind == "spaCy edit-tree (exact)", "\(nlp.lemmatizerKind)")
        #expect(nlp.warnings.isEmpty, "\(nlp.warnings)")
    }

    @Test("names, places and identifiers are found in one German text")
    func endToEnd() throws {
        let engine = try Self.engine()
        let found = try engine.analyze(
            text: "Dr. Anna Müller arbeitet bei der Siemens AG in München. "
                + "Ihre Steuer-ID lautet 65929970489 und ihre E-Mail "
                + "anna.mueller@example.de.",
            language: "de"
        )
        let types = Set(found.map(\.entityType))
        #expect(types.contains("PERSON"), "\(found)")
        #expect(types.contains("LOCATION"), "\(found)")
        #expect(types.contains("DE_TAX_ID"), "\(found)")
        #expect(types.contains("EMAIL_ADDRESS"), "\(found)")
    }

    /// German stop words now exist, so the context enhancer can tell an
    /// evidence word from a function word.
    ///
    /// `keywords` is what context matching actually consults — lemmas with stop
    /// words and punctuation removed. Before German stop words were bundled,
    /// `isStopWord` answered `false` for every German word, so "die" and "und"
    /// arrived here as evidence.
    @Test("German stop words are filtered out of the context keywords")
    func stopWordsInArtifacts() throws {
        let nlp = try SpacyNlpEngine(
            modelDirectory: germanEngineModelDirectory()!, language: "de"
        )
        let artifacts = nlp.process(
            text: "Die Steuer-ID lautet 65929970489.", language: "de"
        )
        #expect(!artifacts.keywords.contains("die"), "\(artifacts.keywords)")
        #expect(!artifacts.keywords.contains("."), "\(artifacts.keywords)")
        #expect(artifacts.keywords.contains { $0.lowercased().contains("steuer") },
                "\(artifacts.keywords)")
    }
}

func germanEngineModelDirectory() -> String? {
    ProcessInfo.processInfo.environment["SPACY_DE_MODEL_DIR"]
}
