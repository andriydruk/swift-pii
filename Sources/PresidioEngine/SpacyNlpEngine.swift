import PresidioCore
import PresidioNLP

/// Port of `SpacyNlpEngine`: runs the tokenizer and NER, and packages the
/// result as `NlpArtifacts`.
///
/// Weights are not bundled — `en_core_web_sm` is 15 MB and `lg` is 619 MB — so
/// this is constructed with a model directory rather than being the default.
/// An engine built without it still finds everything the pattern recognizers
/// find; it just has no PERSON/LOCATION/DATE_TIME, and the context enhancer
/// has no surrounding words to look at.
/// `@unchecked Sendable`: `SpacyNER` holds the tokenizer (thread-safe as of
/// its own audit) and `NERModel`, whose weight arrays are written only during
/// `init` and read-only thereafter. Inference scratch is local to each call.
public final class SpacyNlpEngine: NlpEngineProviding, @unchecked Sendable {

    private let ner: SpacyNER
    private let configuration: NerModelConfiguration
    private let lemmatizer: any Lemmatizing

    public let supportedLanguages: [String]

    /// - Parameter modelDirectory: an unpacked spaCy model directory, e.g.
    ///   `.../en_core_web_sm-3.7.1`.
    public init(
        modelDirectory: String,
        configuration: NerModelConfiguration = NerModelConfiguration(),
        lemmatizer: any Lemmatizing = LowercaseLemmatizer(),
        supportedLanguages: [String] = ["en"]
    ) throws {
        self.ner = try SpacyNER(modelDirectory: modelDirectory)
        self.configuration = configuration
        self.lemmatizer = lemmatizer
        self.supportedLanguages = supportedLanguages
    }

    public func process(text: String, language: String) -> NlpArtifacts {
        let tokens = ner.tokenize(text)
        let entities = ner.entities(in: text, tokens: tokens).map {
            NlpEntity(text: $0.text, label: $0.label, start: $0.start, end: $0.end)
        }
        // spaCy reports no per-entity confidence, so every span gets the
        // configured default before the mapping adjusts it.
        let rawScores = Array(
            repeating: configuration.defaultScore, count: entities.count
        )
        let (mapped, scores) = configuration.applyMapping(entities, scores: rawScores)

        return NlpArtifacts(
            tokens: tokens.map(\.text),
            tokenIndices: tokens.map(\.offset),
            lemmas: tokens.map { lemmatizer.lemma(for: $0.text) },
            entities: mapped,
            scores: scores,
            language: language,
            isStopWord: { LexicalTables.isStopWord($0, language: language) }
        )
    }

    public func isStopWord(_ word: String, language: String) -> Bool {
        LexicalTables.isStopWord(word, language: language)
    }
}

/// A pipeline with the tokenizer but no NER model.
///
/// Between `NoOpNlpEngine` and a full model: there are tokens, so the context
/// enhancer works on surrounding words, but no NER, so no PERSON or LOCATION.
/// Useful when the recognizers you care about are pattern-based and you still
/// want context scoring — which needs no weights at all.
/// `@unchecked Sendable` for the same reason as `SpacyNlpEngine`, minus the
/// model: `SpacyTokenizer` guards its memoization cache with a lock.
public final class TokenizerOnlyNlpEngine: NlpEngineProviding, @unchecked Sendable {

    private let tokenizer: SpacyTokenizer
    private let lemmatizer: any Lemmatizing

    public let supportedLanguages: [String]

    public init(
        lemmatizer: any Lemmatizing = LowercaseLemmatizer(),
        supportedLanguages: [String] = ["en"]
    ) throws {
        self.tokenizer = try SpacyTokenizer.english()
        self.lemmatizer = lemmatizer
        self.supportedLanguages = supportedLanguages
    }

    public func process(text: String, language: String) -> NlpArtifacts {
        let tokens = tokenizer.tokenize(text)
        return NlpArtifacts(
            tokens: tokens.map(\.text),
            tokenIndices: tokens.map(\.offset),
            lemmas: tokens.map { lemmatizer.lemma(for: $0.text) },
            language: language,
            isStopWord: { LexicalTables.isStopWord($0, language: language) }
        )
    }

    public func isStopWord(_ word: String, language: String) -> Bool {
        LexicalTables.isStopWord(word, language: language)
    }
}
