import PresidioCore
import PresidioAnalyzer

/// Port of `ContextAwareEnhancer`.
public protocol ContextAwareEnhancing: Sendable {
    func enhance(
        text: String,
        results: [RecognizerResult],
        artifacts: NlpArtifacts?,
        recognizers: [any EntityRecognizing],
        context: [String]?
    ) -> [RecognizerResult]
}

/// Port of `LemmaContextAwareEnhancer`.
///
/// Raises the score of a result when a word near it, or a word the caller
/// passed as explicit context, matches one of the recognizer's declared
/// context words.
public struct LemmaContextAwareEnhancer: ContextAwareEnhancing {

    /// `ContextAwareEnhancer.MAX_SCORE`.
    public static let maxScore = 1.0

    public enum MatchingMode: String, Sendable {
        /// Default upstream. `'card'` matches `'creditcard'`.
        case substring
        /// `'lic'` matches `'lic'` but not `'duplicate'`.
        case wholeWord = "whole_word"
    }

    public let contextSimilarityFactor: Double
    public let minScoreWithContextSimilarity: Double
    public let contextPrefixCount: Int
    public let contextSuffixCount: Int
    public let matchingMode: MatchingMode

    public init(
        contextSimilarityFactor: Double = 0.35,
        minScoreWithContextSimilarity: Double = 0.4,
        contextPrefixCount: Int = 5,
        contextSuffixCount: Int = 0,
        matchingMode: MatchingMode = .substring
    ) {
        self.contextSimilarityFactor = contextSimilarityFactor
        self.minScoreWithContextSimilarity = minScoreWithContextSimilarity
        self.contextPrefixCount = contextPrefixCount
        self.contextSuffixCount = contextSuffixCount
        self.matchingMode = matchingMode
    }

    public func enhance(
        text: String,
        results rawResults: [RecognizerResult],
        artifacts: NlpArtifacts?,
        recognizers: [any EntityRecognizing],
        context: [String]?
    ) -> [RecognizerResult] {
        var results = rawResults
        let byID = Dictionary(
            recognizers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        let explicitContext = (context ?? []).map { $0.lowercased() }

        // Upstream returns the results untouched when no artifacts were
        // produced, rather than falling back to explicit context only.
        guard let artifacts else { return results }

        let document = TextDocument(text)

        for index in results.indices {
            let result = results[index]
            guard let recognizerID = result.recognitionMetadata[
                    RecognizerResult.MetadataKey.recognizerIdentifier],
                  let recognizer = byID[recognizerID],
                  !recognizer.context.isEmpty
            else { continue }

            // A recognizer that boosted its own result is left alone.
            if result.recognitionMetadata[
                RecognizerResult.MetadataKey.isScoreEnhancedByContext] != nil {
                continue
            }

            guard let word = document.substring(start: result.start, end: result.end)
            else { continue }

            var surrounding = surroundingWords(
                artifacts: artifacts, word: word, start: result.start
            )
            surrounding.append(contentsOf: explicitContext)

            guard let supportive = Self.findSupportiveWord(
                in: surrounding, recognizerContext: recognizer.context, mode: matchingMode
            ) else { continue }

            var score = result.score + contextSimilarityFactor
            score = max(score, minScoreWithContextSimilarity)
            score = min(score, Self.maxScore)
            results[index].score = score
            results[index].recognitionMetadata[
                RecognizerResult.MetadataKey.isScoreEnhancedByContext] = "true"
            results[index].supportiveContextWord = supportive
        }
        return results
    }

    /// Port of `_find_supportive_word_in_context`.
    ///
    /// Returns the *recognizer's* context word, not the matching surrounding
    /// word — and iterates the recognizer's list on the outside, so the result
    /// is the first declared context word with any match, not the nearest one.
    static func findSupportiveWord(
        in contextList: [String], recognizerContext: [String], mode: MatchingMode
    ) -> String? {
        for candidate in recognizerContext {
            let lowered = candidate.lowercased()
            let matched: Bool
            switch mode {
            case .substring:
                matched = contextList.contains { $0.lowercased().contains(lowered) }
            case .wholeWord:
                matched = contextList.contains { $0.lowercased() == lowered }
            }
            if matched { return candidate }
        }
        return nil
    }

    /// Port of `_extract_surrounding_words`.
    func surroundingWords(
        artifacts: NlpArtifacts, word: String, start: Int
    ) -> [String] {
        guard !artifacts.tokens.isEmpty else { return [""] }
        guard let tokenIndex = Self.indexOfMatchToken(
            start: start, tokens: artifacts.tokens, tokenIndices: artifacts.tokenIndices
        ) else { return [""] }

        var words = addWords(
            from: tokenIndex, count: contextPrefixCount,
            lemmas: artifacts.lemmas, keywords: artifacts.keywords, backward: true
        )
        words.append(contentsOf: addWords(
            from: tokenIndex, count: contextSuffixCount,
            lemmas: artifacts.lemmas, keywords: artifacts.keywords, backward: false
        ))
        // `list(set(context_list))` upstream. Order is irrelevant: the caller
        // iterates the recognizer's context words, not this list.
        return Array(Set(words))
    }

    /// Port of `_find_index_of_match_token`.
    ///
    /// Matches by offset, not by text: a match's span rarely lines up with a
    /// token boundary — "555-124564" tokenizes with "555" first — so the token
    /// wanted is the one whose extent covers the match start.
    static func indexOfMatchToken(
        start: Int, tokens: [String], tokenIndices: [Int]
    ) -> Int? {
        for (i, token) in tokens.enumerated() {
            let tokenStart = tokenIndices[i]
            if tokenStart == start || start < tokenStart + token.unicodeScalars.count {
                return i
            }
        }
        // Upstream raises here. Returning nil instead: a missing token means no
        // context enhancement, which is not worth failing an entire request
        // over, and the caller falls back to `[""]`.
        return nil
    }

    /// Port of `_add_n_words`.
    ///
    /// Note `remaining = n_words + 1`: the entity's own token counts against
    /// the budget, deliberately, so that a context word glued to the entity
    /// with no space still gets considered.
    func addWords(
        from index: Int, count: Int, lemmas: [String], keywords: [String],
        backward: Bool
    ) -> [String] {
        let keywordSet = Set(keywords)
        var words: [String] = []
        var i = index
        var remaining = count + 1
        while i >= 0, i < lemmas.count, remaining > 0 {
            let lowered = lemmas[i].lowercased()
            if keywordSet.contains(lowered) {
                words.append(lowered)
                remaining -= 1
            }
            i += backward ? -1 : 1
        }
        return words
    }
}
