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
        var out: [String] = []
        if let fallbackReason {
            out.append(
                "Lemmas are approximate: \(fallbackReason). Context matching will "
                + "differ from Presidio on inflected context words."
            )
        }
        if let reason = duplicateParseReason { out.append(reason) }
        return out
    }

    /// Set when a caller-supplied lemmatizer *could* have handed over sentence
    /// boundaries and was not built to.
    ///
    /// This is the one way to end up with a correct engine that quietly does the
    /// work twice. `SpacyRuleLemmatizer` defaults to not parsing — measured, and
    /// right for a standalone lemmatizer, since no parser-dependent ruler rule
    /// changes a lemma — but the engine wants that parse for NER's sentence
    /// boundaries. So supplying what looks like the default lemmatizer produces
    /// an engine ~14% slower than the actual default, with identical output.
    ///
    /// Nothing here can fix it: the instance is already built. It can say so,
    /// which is what `warnings` is for.
    private let duplicateParseReason: String?

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
    ///     It costs throughput: the tagger runs the shared tok2vec over every
    ///     text, and the whole NLP stage lands near 5.6 ms/document on the
    ///     benchmark corpus against 2.8 for tokenize-plus-NER-plus-parser alone.
    ///     Construction is unaffected. Pass `LookupLemmatizer()` explicitly to
    ///     trade the exactness back for the speed — `presidio-bench` prints every
    ///     configuration so the trade is a number rather than this sentence.
    ///
    ///     Supplying a lemmatizer also changes where sentence boundaries come
    ///     from. The default rule lemmatizer hands them over from its own pass;
    ///     anything else leaves NER to parse for itself, which is correct but
    ///     encodes the document twice. See `sharesLemmatizerParse`.
    /// - Parameter language: which language's tokenizer rules to use, and which
    ///   lemmatizer the model is expected to carry. It must be the language the
    ///   model was trained for: tokenizing German with English rules is a quiet
    ///   failure, since most sentences survive it and only the exceptions —
    ///   `z.B.`, `Dr.` — come out wrong, shifting every offset after them.
    public init(
        modelDirectory: String,
        configuration: NerModelConfiguration = NerModelConfiguration(),
        lemmatizer: (any Lemmatizing)? = nil,
        language: String = "en",
        supportedLanguages: [String]? = nil
    ) throws {
        let tokenizer = try SpacyTokenizer.forLanguage(language)
        self.configuration = configuration
        self.supportedLanguages = supportedLanguages ?? [language]

        if let lemmatizer {
            self.lemmatizer = lemmatizer
            self.lemmatizerKind = "\(type(of: lemmatizer)) (caller-supplied)"
            self.fallbackReason = nil
        } else if language == "en",
                  // `parseDependencies` here, not in `SpacyRuleLemmatizer`'s
                  // default: the parse is for NER's sentence boundaries, and the
                  // tagger has already encoded the document, so running it here
                  // costs the transitions and nothing else. NER is built below
                  // without a parser of its own because of it.
                  let rule = try? SpacyRuleLemmatizer(
                      modelDirectory: modelDirectory, parseDependencies: true
                  ) {
            // Gated on the language, not merely attempted. `SpacyRuleLemmatizer`
            // combines the model's tagger with the bundled **English** rule
            // tables, and it cannot tell that it has been handed a German model
            // — it loads, it runs, and it returns confident English-rule lemmas
            // for German words. Trying it first and falling through on failure
            // is exactly what produced that, and it is invisible without a
            // German corpus to check against.
            self.lemmatizer = rule
            self.lemmatizerKind = "spaCy rule-mode (exact)"
            self.fallbackReason = nil
        } else if let editTree = try? SpacyEditTreeLemmatizer(modelDirectory: modelDirectory) {
            // German and most other `*_core_news_sm` pipelines: a trained
            // classifier over edit trees, which is a different component
            // entirely rather than a variant of the rule one.
            self.lemmatizer = editTree
            self.lemmatizerKind = "spaCy edit-tree (exact)"
            self.fallbackReason = nil
        } else {
            self.lemmatizer = LookupLemmatizer()
            self.lemmatizerKind = "lookup table (approximate)"
            self.fallbackReason =
                "\(modelDirectory) carries neither a rule lemmatizer nor a "
                + "trainable one, so lemmas are approximated from a table"
        }

        // NER needs sentence boundaries either way; the only question is which
        // component pays for the tok2vec pass that produces them. When the
        // lemmatizer already ran the tagger over that network, NER borrows its
        // parse; otherwise NER loads a parser of its own. Both give identical
        // spans — the weights and the tokens are the same — so this is purely
        // about not encoding the same document twice.
        let boundaryProvider = self.lemmatizer as? SentenceBoundaryProviding
        let sharesParse = boundaryProvider?.providesSentenceStarts ?? false
        self.ner = try SpacyNER(
            modelDirectory: modelDirectory, tokenizer: tokenizer,
            parseSentences: !sharesParse
        )
        self.sharesLemmatizerParse = sharesParse
        // Conforms but was not asked to parse — see `duplicateParseReason`.
        self.duplicateParseReason = (boundaryProvider != nil && !sharesParse)
            ? "\(type(of: self.lemmatizer)) can supply sentence boundaries but "
              + "was built without a parse, so NER runs a second one over the "
              + "same network. Build it with `parseDependencies: true`, or omit "
              + "the `lemmatizer:` argument to get the default."
            : nil
    }

    /// Whether sentence boundaries come from the lemmatizer's tok2vec pass
    /// rather than from a second parser inside NER.
    ///
    /// Exposed because it is not observable from the output — both paths produce
    /// identical spans, which is the point — and a test that could not see which
    /// one ran would be asserting nothing. Also what `presidio-bench` uses to
    /// label its A/B.
    public let sharesLemmatizerParse: Bool

    public func process(text: String, language: String) -> NlpArtifacts {
        let tokens = ner.tokenize(text)

        // One pass where possible: the lemmatizer's tagger and the parser read
        // the same tok2vec, so asking for both together saves encoding the
        // document twice. Falls back to NER's own parser for pipelines whose
        // lemmatizer never runs a tagger.
        let lemmas: [String]
        let named: [NamedEntity]
        if let sharing = lemmatizer as? SentenceBoundaryProviding,
           sharing.providesSentenceStarts {
            let annotation = sharing.lemmasAndSentenceStarts(for: tokens, text: text)
            lemmas = annotation.lemmas
            named = ner.entities(
                in: text, tokens: tokens,
                sentenceStarts: annotation.sentenceStarts
            )
        } else {
            lemmas = lemmatizer.lemmas(for: tokens, text: text)
            named = ner.entities(in: text, tokens: tokens)
        }

        let entities = named.map {
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
            lemmas: lemmas,
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

    /// What the tokenizer is approximating, if anything.
    public var warnings: [String] {
        guard let approximated else { return [] }
        return [
            "No tokenizer rules are bundled for '\(approximated)', so English "
            + "rules are being used. Token boundaries decide the context window, "
            + "so scores near language-specific abbreviations may differ from "
            + "Presidio. Add rules with Tools/extract_tokenizer.py --lang "
            + "\(approximated)."
        ]
    }

    private let approximated: String?

    /// - Parameter supportedLanguages: the first entry also picks the tokenizer
    ///   rules, so a German engine tokenizes German.
    ///
    ///   A language with no bundled rules falls back to English ones and says so
    ///   through `warnings`, rather than refusing. That is the opposite of
    ///   `SpacyNlpEngine`'s choice, deliberately: there, wrong token boundaries
    ///   feed a model and corrupt entity offsets, so it is worth stopping for.
    ///   Here there is no model — tokenization only decides the ±5-token context
    ///   window — and refusing would take away, say, the Polish or Korean
    ///   recognizers entirely to avoid a scoring approximation. (German,
    ///   Spanish and Italian have their own rules bundled, so they never take
    ///   this path.)
    public init(
        lemmatizer: any Lemmatizing = LookupLemmatizer(),
        supportedLanguages: [String] = ["en"]
    ) throws {
        let language = supportedLanguages.first ?? "en"
        if let rules = try? SpacyTokenizer.forLanguage(language) {
            self.tokenizer = rules
            self.approximated = nil
        } else {
            self.tokenizer = try SpacyTokenizer.english()
            self.approximated = language
        }
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

    /// - Parameter parseDependencies: run the dependency parser alongside the
    ///   tagger, over the same tok2vec pass.
    ///
    ///   Off by default *for lemmas*, and that is measured rather than assumed:
    ///   the thirteen ruler rules it enables make coarse POS exact, and
    ///   `RuleLemmatizerTests` runs the whole chain both ways over 5,513 tokens
    ///   with every lemma identical. So a standalone lemmatizer gains nothing
    ///   from a parse.
    ///
    ///   `SpacyNlpEngine` turns it on anyway, because it needs the sentence
    ///   boundaries for NER and this is the cheapest place in the pipeline to
    ///   get them — see `SentenceBoundaryProviding`.
    public init(modelDirectory: String, parseDependencies: Bool = false) throws {
        self.chain = try SpacyLemmatizer(
            modelDirectory: modelDirectory, parseDependencies: parseDependencies
        )
    }

    /// `SentenceBoundaryProviding`. True only when the parser was asked for:
    /// conformance alone does not mean a parse exists.
    public var providesSentenceStarts: Bool { chain.usesDependencies }

    /// Attribute-ruler rules that test `DEP`, and so match nothing unless
    /// `parseDependencies` was requested. None of them changes a lemma — see
    /// `SpacyLemmatizer`.
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

extension SpacyRuleLemmatizer: SentenceBoundaryProviding {
    public func lemmasAndSentenceStarts(
        for tokens: [Token], text: String
    ) -> (lemmas: [String], sentenceStarts: Set<Int>) {
        let annotation = chain.annotate(tokens: tokens, text: text)
        return (annotation.lemmas, annotation.sentenceStarts)
    }
}

/// spaCy's trainable lemmatizer, wired into the engine.
///
/// The counterpart to `SpacyRuleLemmatizer` for pipelines that have no rule
/// lemmatizer at all — German's, and most `*_core_news_sm` models. Exact over
/// the 699-token German corpus.
///
/// The two are not interchangeable and the engine does not guess: it tries the
/// rule one, then this, and says which it got through `lemmatizerKind`.
public struct SpacyEditTreeLemmatizer: Lemmatizing {

    private let model: EditTreeLemmatizer

    public init(modelDirectory: String) throws {
        self.model = try EditTreeLemmatizer(directory: modelDirectory)
    }

    /// Without surrounding tokens there is no prediction, so this degrades to
    /// lowercasing. `lemmas(for:text:)` is the real entry point.
    public func lemma(for token: String) -> String { token.lowercased() }

    public func lemmas(for tokens: [Token], text: String) -> [String] {
        model.lemmas(for: tokens, text: text)
    }
}
