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

    /// What the lemmas came from, and why.
    public let lemmatizerKind: String
    private let fallbackReason: String?

    public var warnings: [String] {
        guard let fallbackReason else { return [] }
        return [
            "Lemmas are approximate: \(fallbackReason). Context matching will "
            + "differ from Presidio on inflected context words."
        ]
    }

    /// - Parameters:
    ///   - modelDirectory: an unpacked spaCy model directory, e.g.
    ///     `.../en_core_web_sm-3.7.1`.
    ///   - lemmatizer: omit it to get spaCy's own rule-mode lemmatizer, built
    ///     from the same model. There is a model here by construction, so the
    ///     exact lemmatizer is the sensible default and the approximation is
    ///     the thing you should have to ask for.
    ///
    ///     A model without a tagger falls back to `LookupLemmatizer`, and says
    ///     so through `warnings` rather than quietly producing worse lemmas.
    ///
    ///     It costs throughput: the tagger runs a second tok2vec pass over
    ///     every text, so NLP processing roughly doubles (1.1 -> 2.2 ms per
    ///     text) and end-to-end `analyze` goes from 2.7 to 3.9 ms, about 45%.
    ///     Construction is unaffected. Pass `LookupLemmatizer()` explicitly to
    ///     trade the exactness back for the speed.
    public init(
        modelDirectory: String,
        configuration: NerModelConfiguration = NerModelConfiguration(),
        lemmatizer: (any Lemmatizing)? = nil,
        supportedLanguages: [String] = ["en"]
    ) throws {
        self.ner = try SpacyNER(modelDirectory: modelDirectory)
        self.configuration = configuration
        self.supportedLanguages = supportedLanguages

        if let lemmatizer {
            self.lemmatizer = lemmatizer
            self.lemmatizerKind = "\(type(of: lemmatizer)) (caller-supplied)"
            self.fallbackReason = nil
        } else if let rule = try? SpacyRuleLemmatizer(modelDirectory: modelDirectory) {
            self.lemmatizer = rule
            self.lemmatizerKind = "spaCy rule-mode (exact)"
            self.fallbackReason = nil
        } else {
            self.lemmatizer = LookupLemmatizer()
            self.lemmatizerKind = "lookup table (approximate)"
            self.fallbackReason =
                "\(modelDirectory) has no usable tagger, so rule-mode "
                + "lemmatization is unavailable"
        }
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
            lemmas: lemmatizer.lemmas(for: tokens, text: text),
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
        lemmatizer: any Lemmatizing = LookupLemmatizer(),
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
            lemmas: lemmatizer.lemmas(for: tokens, text: text),
            language: language,
            isStopWord: { LexicalTables.isStopWord($0, language: language) }
        )
    }

    public func isStopWord(_ word: String, language: String) -> Bool {
        LexicalTables.isStopWord(word, language: language)
    }
}

/// spaCy's own lemmatizer, wired into the engine.
///
/// The exact thing Presidio's context enhancer compares against, rather than an
/// approximation of it: **lemmas are exact** over 5,513 measured tokens.
///
/// Needs model weights, so it is not the package default — `LookupLemmatizer`
/// still is, for callers with no model. Supply this when you have a model and
/// want context matching to agree with Presidio exactly:
///
/// ```swift
/// let nlp = try SpacyNlpEngine(
///     modelDirectory: path,
///     lemmatizer: try SpacyRuleLemmatizer(modelDirectory: path)
/// )
/// ```
public struct SpacyRuleLemmatizer: Lemmatizing {

    private let chain: SpacyLemmatizer

    public init(modelDirectory: String) throws {
        self.chain = try SpacyLemmatizer(modelDirectory: modelDirectory)
    }

    /// Attribute-ruler rules that need the dependency parser and are therefore
    /// not applied. None of them changes a lemma — see `SpacyLemmatizer`.
    public var parserDependentRuleCount: Int {
        SpacyLemmatizer.parserDependentRuleCount
    }

    /// Without a sentence there is no tag, so this degrades to lowercasing.
    /// `lemmas(for:text:)` is the real entry point.
    public func lemma(for token: String) -> String { token.lowercased() }

    public func lemmas(for tokens: [Token], text: String) -> [String] {
        chain.lemmas(for: tokens, text: text)
    }
}
