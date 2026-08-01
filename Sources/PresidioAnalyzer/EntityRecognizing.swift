import PresidioCore

/// What `AnalyzerEngine` needs from anything that can find entities.
///
/// Port of the parts of `EntityRecognizer` the engine actually uses. The
/// engine has to drive three quite different kinds of recognizer — pattern
/// recognizers built from data, hand-written ones like `PhoneRecognizer`, and
/// the NER model — so the protocol is what they have in common rather than a
/// transliteration of upstream's base class.
public protocol EntityRecognizing: Sendable {

    /// Stable identity used to route context enhancement back to the
    /// recognizer that produced a result.
    ///
    /// Upstream builds this as `f"{name}_{id(self)}"` — the CPython object
    /// address, so it is neither stable across runs nor meaningful outside the
    /// process. It is only ever used as a join key within a single `analyze`
    /// call, so this port uses a deterministic equivalent instead.
    var id: String { get }

    var name: String { get }
    var supportedEntities: [String] { get }
    var supportedLanguage: String { get }

    /// Context words that boost this recognizer's results when found nearby.
    var context: [String] { get }

    /// Per-entity minimum scores, plus an optional `"default"` key.
    /// Empty means "fall back to the engine default".
    var scoreThresholds: [String: Double] { get }

    /// `entities` is the set the caller asked for; a recognizer that supports
    /// several may need to filter. `artifacts` is nil when no NLP engine ran.
    func analyze(
        _ text: String, entities: [String], artifacts: NlpArtifacts?
    ) -> [RecognizerResult]
}

public extension EntityRecognizing {
    var supportedLanguage: String { "en" }
    var scoreThresholds: [String: Double] { [:] }
}

/// Validation port of `normalize_score_thresholds`.
public enum ScoreThresholds {
    public enum Invalid: Error, Equatable {
        case emptyOrPaddedKey(String)
        case outOfRange(entity: String, value: Double)
    }

    public static func validate(_ thresholds: [String: Double]) throws -> [String: Double] {
        for (entity, value) in thresholds {
            guard !entity.isEmpty, entity.trimmedForThresholdKey() == entity else {
                throw Invalid.emptyOrPaddedKey(entity)
            }
            guard value >= 0, value <= 1 else {
                throw Invalid.outOfRange(entity: entity, value: value)
            }
        }
        return thresholds
    }
}

private extension String {
    /// `str.strip()` — Python strips Unicode whitespace, not just spaces.
    func trimmedForThresholdKey() -> String {
        var scalars = Array(unicodeScalars)
        while let first = scalars.first, first.properties.isWhitespace {
            scalars.removeFirst()
        }
        while let last = scalars.last, last.properties.isWhitespace {
            scalars.removeLast()
        }
        return String(String.UnicodeScalarView(scalars))
    }
}

/// `PatternRecognizer` participates in the engine directly.
///
/// It ignores both arguments, deliberately. `artifacts` because pattern
/// matching is purely lexical — the NLP artifacts matter only to the context
/// enhancer that runs afterwards. And `entities` because upstream's
/// `PatternRecognizer.analyze` ignores it too: entity filtering happens when
/// the registry *selects* recognizers, not inside them.
///
/// Filtering here as well looks harmless and is not. `AnalyzerEngine` derives
/// the entity list from the registry alone, so an ad-hoc recognizer passed to
/// a single request contributes an entity nobody has heard of — and a
/// self-filtering recognizer would discard its own results.
extension PatternRecognizer: EntityRecognizing {
    public var id: String { "\(name)#\(ObjectIdentifier(self).hashValue)" }
    public var supportedEntities: [String] { [entity] }

    public func analyze(
        _ text: String, entities: [String], artifacts: NlpArtifacts?
    ) -> [RecognizerResult] {
        analyze(text)
    }
}
