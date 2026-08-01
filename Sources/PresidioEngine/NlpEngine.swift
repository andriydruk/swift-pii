import Foundation
import PresidioCore

/// Port of the `NlpEngine` interface: turns text into `NlpArtifacts`.
///
/// Abstracted rather than hardcoded because the engine is useful without a
/// model — pattern recognizers need no NLP at all, and loading spaCy weights
/// to find a credit card number would be absurd.
public protocol NlpEngineProviding: Sendable {
    func process(text: String, language: String) -> NlpArtifacts
    func isStopWord(_ word: String, language: String) -> Bool
    var supportedLanguages: [String] { get }
}

/// spaCy's English lexical attributes, extracted from the loaded model.
///
/// `is_stop` is membership in `spacy.lang.en.stop_words.STOP_WORDS`, matched
/// case-insensitively; `is_punct` is a rule and lives on `NlpArtifacts`.
/// Both were verified against the model's vocabulary by
/// `Tools/extract_nlp_tables.py`, which refuses to emit a table if either
/// check fails.
public enum LexicalTables {

    struct Payload: Decodable {
        let spacyVersion: String
        let stopWords: [String]

        enum CodingKeys: String, CodingKey {
            case spacyVersion = "spacy_version"
            case stopWords = "stop_words"
        }
    }

    private static let payload: Payload? = {
        guard let url = Bundle.module.url(forResource: "en_lexical", withExtension: "json"),
              let bytes = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Payload.self, from: bytes)
        else { return nil }
        return decoded
    }()

    public static let englishStopWords: Set<String> = Set(payload?.stopWords ?? [])

    public static var isLoaded: Bool { !englishStopWords.isEmpty }

    public static func isStopWord(_ word: String, language: String) -> Bool {
        guard language == "en" else { return false }
        return englishStopWords.contains(word.lowercased())
    }
}

/// Port of `NoOpNlpEngine`: tokenizes nothing, produces nothing.
///
/// Upstream warns that a `LemmaContextAwareEnhancer` paired with this can only
/// use context passed explicitly to `analyze`, because there are no tokens to
/// draw surrounding words from. That warning is reproduced by
/// `AnalyzerEngine.configurationWarnings`.
public struct NoOpNlpEngine: NlpEngineProviding {
    public init() {}

    public var supportedLanguages: [String] { ["en"] }

    public func process(text: String, language: String) -> NlpArtifacts {
        NlpArtifacts(tokens: [], tokenIndices: [], lemmas: [], keywords: [],
                     language: language)
    }

    public func isStopWord(_ word: String, language: String) -> Bool { false }
}

/// How a token is reduced before context matching.
///
/// Upstream uses spaCy's rule-based lemmatizer, which needs POS tags, which
/// needs the tagger — a whole additional model component. Measured against
/// Presidio's real engine over 3,241 texts with 177 context boosts, replacing
/// lemmas with lowercased token text changed **nothing**: 3,241/3,241
/// identical results.
///
/// That is structural, not luck. Context matching is *substring* by default,
/// and English lemmatization is nearly always a suffix strip, so the
/// recognizer's context word is a substring of the inflected form either way
/// ("card" matches both "card" and "cards").
///
/// It stops being true in `whole_word` mode, where the same 3,241 texts give 2
/// divergences — "MACs" lemmatizes to "mac", which matches the context word
/// exactly, while the lowercased token does not. So this is a protocol: the
/// default is honest about what it does, and a real lemmatizer can be dropped
/// in without touching the enhancer.
public protocol Lemmatizing: Sendable {
    func lemma(for token: String) -> String
}

/// Lowercasing stands in for lemmatization. See `Lemmatizing`.
public struct LowercaseLemmatizer: Lemmatizing {
    public init() {}
    public func lemma(for token: String) -> String { token.lowercased() }
}
