/// A named span produced by an NLP pipeline's entity recognizer.
///
/// Distinct from `RecognizerResult`: this is the raw NER output, before any
/// recognizer has mapped a model label onto a Presidio entity type.
public struct NlpEntity: Sendable, Hashable {
    public let text: String
    public let label: String
    /// Unicode scalar offsets, like everything else in this package.
    public let start: Int
    public let end: Int

    public init(text: String, label: String, start: Int, end: Int) {
        self.text = text
        self.label = label
        self.start = start
        self.end = end
    }
}

/// Port of `NlpArtifacts` — one NLP pipeline run over one text.
///
/// Carried through the engine so every recognizer sees the same tokenization
/// rather than each running its own, and so the context enhancer can look at
/// the words surrounding a match.
public struct NlpArtifacts: Sendable {

    public let tokens: [String]
    /// Start offset of each token, in Unicode scalars.
    public let tokenIndices: [Int]
    public let lemmas: [String]
    /// Lemmas kept for context matching — see `makeKeywords`.
    public let keywords: [String]
    public let entities: [NlpEntity]
    public let scores: [Double]
    public let language: String

    public init(
        tokens: [String],
        tokenIndices: [Int],
        lemmas: [String],
        keywords: [String]? = nil,
        entities: [NlpEntity] = [],
        scores: [Double]? = nil,
        language: String = "en",
        isStopWord: (String) -> Bool = { _ in false }
    ) {
        self.tokens = tokens
        self.tokenIndices = tokenIndices
        self.lemmas = lemmas
        self.keywords = keywords ?? Self.makeKeywords(lemmas, isStopWord: isStopWord)
        self.entities = entities
        // `scores if scores else [0.85] * len(entities)` — upstream's default
        // confidence for a model that reports none.
        self.scores = scores ?? Array(repeating: 0.85, count: entities.count)
        self.language = language
    }

    /// Port of `NlpArtifacts.set_keywords`.
    ///
    /// Note the two hardcoded exclusions alongside the stopword and
    /// punctuation filters: `-PRON-` is spaCy v2's pronoun lemma placeholder,
    /// and `be` is dropped explicitly because it is the lemma of every form of
    /// "is"/"was"/"are" and would otherwise match any recognizer context word
    /// containing it.
    public static func makeKeywords(
        _ lemmas: [String], isStopWord: (String) -> Bool
    ) -> [String] {
        var out: [String] = []
        for lemma in lemmas {
            let lowered = lemma.lowercased()
            guard !isStopWord(lemma), !isPunctuation(lemma),
                  lemma != "-PRON-", lemma != "be"
            else { continue }
            // "best effort, try even further to break tokens into sub tokens":
            // upstream splits on ":" and flattens, so "key:value" contributes
            // both halves.
            out.append(contentsOf: lowered.split(separator: ":", omittingEmptySubsequences: false)
                .map(String.init))
        }
        return out
    }

    /// spaCy's `is_punct`: every character is in a Unicode `P*` category.
    ///
    /// Verified against the model's vocabulary rather than assumed — which
    /// matters because it makes `$`, `+`, `<`, `=`, `>`, `^`, `|` and `~`
    /// *not* punctuation. Those are category `S*`.
    public static func isPunctuation(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return text.unicodeScalars.allSatisfy {
            switch $0.properties.generalCategory {
            case .connectorPunctuation, .dashPunctuation, .openPunctuation,
                 .closePunctuation, .initialPunctuation, .finalPunctuation,
                 .otherPunctuation:
                return true
            default:
                return false
            }
        }
    }
}
