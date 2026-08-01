import PresidioCore
import PresidioAnalyzer
import PresidioRegex

/// Port of `AnalyzerEngine` — the entry point that runs every recognizer over
/// a text, boosts scores from context, applies thresholds, and deduplicates.
public struct AnalyzerEngine: Sendable {

    /// How `allowList` entries are interpreted.
    public enum AllowListMatch: String, Sendable {
        case exact
        case regex
    }

    public enum EngineError: Error, Equatable, CustomStringConvertible {
        case languageNotSupported(String)
        case registryLanguageMismatch(registry: [String], engine: [String])
        case invalidAllowListRegex(String)

        public var description: String {
            switch self {
            case .languageNotSupported(let language):
                return "language '\(language)' is not in the engine's supported set"
            case .registryLanguageMismatch(let registry, let engine):
                return "registry supports \(registry) but the engine supports \(engine); "
                    + "recognizers for a language the engine cannot process would never fire"
            case .invalidAllowListRegex(let pattern):
                return "allow_list is not a valid regular expression: \(pattern)"
            }
        }
    }

    public let registry: RecognizerRegistry
    public let nlpEngine: any NlpEngineProviding
    public let contextEnhancer: any ContextAwareEnhancing
    public let defaultScoreThreshold: Double
    public let supportedLanguages: [String]

    public init(
        registry: RecognizerRegistry,
        nlpEngine: any NlpEngineProviding = NoOpNlpEngine(),
        contextEnhancer: any ContextAwareEnhancing = LemmaContextAwareEnhancer(),
        defaultScoreThreshold: Double = 0,
        supportedLanguages: [String] = ["en"]
    ) throws {
        // Upstream raises when the registry and engine disagree on languages,
        // because a recognizer for a language the engine cannot process would
        // silently never fire.
        guard Set(registry.supportedLanguages) == Set(supportedLanguages) else {
            throw EngineError.registryLanguageMismatch(
                registry: registry.supportedLanguages, engine: supportedLanguages
            )
        }
        self.registry = registry
        self.nlpEngine = nlpEngine
        self.contextEnhancer = contextEnhancer
        self.defaultScoreThreshold = defaultScoreThreshold
        self.supportedLanguages = supportedLanguages
    }

    /// The default engine: every predefined recognizer, no NLP model.
    ///
    /// Without an NLP engine there is no NER, so no PERSON/LOCATION/DATE_TIME,
    /// and the context enhancer can only use context passed to `analyze`.
    /// `configurationWarnings` says so rather than leaving it to be discovered.
    public static func makeDefault(
        nlpEngine: any NlpEngineProviding = NoOpNlpEngine(),
        defaultScoreThreshold: Double = 0
    ) throws -> AnalyzerEngine {
        try AnalyzerEngine(
            registry: try RecognizerRegistry.loadPredefined(),
            nlpEngine: nlpEngine,
            defaultScoreThreshold: defaultScoreThreshold
        )
    }

    /// Port of the `NoOpNlpEngine` + `LemmaContextAwareEnhancer` warning.
    public var configurationWarnings: [String] {
        guard nlpEngine is NoOpNlpEngine,
              contextEnhancer is LemmaContextAwareEnhancer
        else { return [] }
        return [
            """
            LemmaContextAwareEnhancer cannot use context words from the analyzed \
            text with NoOpNlpEngine because no tokens or lemmas are produced. \
            Only context passed explicitly to analyze() can be used.
            """
        ]
    }

    public func supportedEntities(language: String = "en") -> [String] {
        registry.supportedEntities(language: language)
    }

    /// Port of `AnalyzerEngine.analyze`.
    ///
    /// The step order is load-bearing and matches upstream exactly: recognize,
    /// enhance from context, **threshold, then deduplicate**. Thresholding
    /// before dedup is deliberate upstream — filtering after would let a
    /// low-scoring duplicate displace the result that would have survived.
    public func analyze(
        text: String,
        language: String = "en",
        entities: [String]? = nil,
        scoreThreshold: Double? = nil,
        adHocRecognizers: [any EntityRecognizing] = [],
        context: [String]? = nil,
        allowList: [String] = [],
        allowListMatch: AllowListMatch = .exact,
        allowListFlags: RegexFlags = RegexFlags(
            ignoreCase: true, dotAll: true, multiline: true
        ),
        artifacts precomputed: NlpArtifacts? = nil
    ) throws -> [RecognizerResult] {

        guard supportedLanguages.contains(language) else {
            throw EngineError.languageNotSupported(language)
        }

        let allFields = entities == nil || entities?.isEmpty == true
        let selected = try registry.recognizers(
            language: language, entities: entities, allFields: allFields, adHoc: adHocRecognizers
        )
        // With all_fields, upstream expands the request to every entity the
        // selected recognizers support, and passes that list down.
        let requested = allFields ? registry.supportedEntities(language: language) : (entities ?? [])

        let artifacts = precomputed ?? nlpEngine.process(text: text, language: language)

        var results: [RecognizerResult] = []
        for recognizer in selected {
            var found = recognizer.analyze(text, entities: requested, artifacts: artifacts)
            guard !found.isEmpty else { continue }
            // Port of `__add_recognizer_id_if_not_exists`. The identifier is
            // what routes context enhancement back to the recognizer, so a
            // result without one silently cannot be boosted.
            for index in found.indices {
                let key = RecognizerResult.MetadataKey.self
                if found[index].recognitionMetadata[key.recognizerIdentifier] == nil {
                    found[index].recognitionMetadata[key.recognizerIdentifier] = recognizer.id
                }
                if found[index].recognitionMetadata[key.recognizerName] == nil {
                    found[index].recognitionMetadata[key.recognizerName] = recognizer.name
                }
            }
            results.append(contentsOf: found)
        }

        results = contextEnhancer.enhance(
            text: text, results: results, artifacts: artifacts,
            recognizers: selected, context: context
        )

        results = removeLowScores(results, threshold: scoreThreshold, recognizers: selected)
        results = PatternRecognizer.removeDuplicates(results)

        if !allowList.isEmpty {
            results = try removeAllowList(
                results, allowList: allowList, text: text,
                match: allowListMatch, flags: allowListFlags
            )
        }

        // Python returns whatever order `list(set(...))` produced, which is
        // hash-randomized per process. This port defines a total order instead;
        // see RecognizerResult.totalOrderIsLess.
        return results.sorted(by: RecognizerResult.totalOrderIsLess)
    }

    /// Port of `__remove_low_scores` + `__get_result_score_threshold`.
    ///
    /// An explicit `scoreThreshold` bypasses every recognizer-level threshold.
    /// Otherwise the fallback chain is: the recognizer's per-entity threshold,
    /// its `"default"`, then the engine default.
    func removeLowScores(
        _ results: [RecognizerResult],
        threshold: Double?,
        recognizers: [any EntityRecognizing]
    ) -> [RecognizerResult] {
        if let threshold {
            return results.filter { $0.score >= threshold }
        }
        let thresholdsByID = Dictionary(
            recognizers.map { ($0.id, $0.scoreThresholds) },
            uniquingKeysWith: { first, _ in first }
        )
        return results.filter { result in
            result.score >= resolveThreshold(result, thresholdsByID)
        }
    }

    private func resolveThreshold(
        _ result: RecognizerResult, _ thresholdsByID: [String: [String: Double]]
    ) -> Double {
        guard let id = result.recognitionMetadata[
                RecognizerResult.MetadataKey.recognizerIdentifier],
              let thresholds = thresholdsByID[id]
        else { return defaultScoreThreshold }
        if let entityThreshold = thresholds[result.entityType] { return entityThreshold }
        if let recognizerDefault = thresholds["default"] { return recognizerDefault }
        return defaultScoreThreshold
    }

    /// Port of `_remove_allow_list`.
    ///
    /// In regex mode upstream joins the terms with `|` into a single pattern
    /// and *searches* the matched text — so a term matching any substring of
    /// the match allows it, not only a full match.
    func removeAllowList(
        _ results: [RecognizerResult],
        allowList: [String],
        text: String,
        match: AllowListMatch,
        flags: RegexFlags
    ) throws -> [RecognizerResult] {
        let document = TextDocument(text)

        switch match {
        case .exact:
            let allowed = Set(allowList)
            return results.filter { result in
                guard let word = document.substring(start: result.start, end: result.end)
                else { return true }
                return !allowed.contains(word)
            }

        case .regex:
            let terms = allowList.filter { !$0.isEmpty }
            guard !terms.isEmpty else { return results }
            let pattern = terms.joined(separator: "|")
            guard let regex = try? PureRegex(
                pattern, ignoreCase: flags.ignoreCase,
                dotAll: flags.dotAll, multiline: flags.multiline
            ) else {
                // A malformed allow list must not silently allow everything, nor
                // silently allow nothing. Upstream lets `re.compile` raise.
                throw EngineError.invalidAllowListRegex(pattern)
            }
            return results.filter { result in
                guard let word = document.substring(start: result.start, end: result.end)
                else { return true }
                return regex.matches(in: word).isEmpty
            }
        }
    }
}
