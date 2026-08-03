import Foundation
import PresidioCore
import PresidioAnalyzer
import PresidioRecognizers

/// Finds personal data in text.
///
/// The entry point for the common case. It wraps `AnalyzerEngine` with sensible
/// defaults so that finding PII is one call:
///
/// ```swift
/// let detector = try PIIDetector()
/// for finding in try detector.findings(in: "card 4095-2609-9393-4932") {
///     print(finding.type, finding.text, finding.confidence)
/// }
/// ```
///
/// Out of the box this finds the things that are recognisable from their shape
/// alone — payment cards, IBANs, emails, phone numbers, national identifiers —
/// with no model to download. Names, places and organisations need a language
/// model; see `PIIDetector(nlpEngine:)` and the `PresidioModelEnglish` product.
public struct PIIDetector: Sendable {

    /// One piece of personal data found in a string.
    public struct Finding: Sendable, Hashable {
        /// What kind of data this is, e.g. `"CREDIT_CARD"`, `"EMAIL_ADDRESS"`.
        public let type: String
        /// The matched text.
        public let text: String
        /// Where it is, in Unicode scalars — see `range(in:)` for a Swift range.
        public let start: Int
        public let end: Int
        /// 0…1. Shape alone scores lower than a passing checksum, and a
        /// supporting word nearby ("card", "phone") raises it further.
        public let confidence: Double
        /// Which recognizer produced it.
        public let recognizer: String

        /// The finding's range in the original string.
        public func range(in text: String) -> Range<String.Index>? {
            TextDocument(text).range(start: start, end: end, in: text)
        }
    }

    /// The engine underneath, for anything the convenience API does not cover
    /// — batch analysis, ad-hoc recognizers, per-request allow lists.
    public let engine: AnalyzerEngine

    /// A detector with every default: no model, no configuration.
    ///
    /// Uses the tokenizer, which needs no weights, so words near a candidate
    /// still raise its score — "call 212-555-5555" scores 0.75 where the bare
    /// digits score 0.4. Without a tokenizer there are no surrounding words to
    /// look at and that scoring silently does nothing, which is a poor default
    /// for a few hundred microseconds.
    public init() throws {
        var registry = try RecognizerRegistry.loadPredefined()
        registry.add(SpacyRecognizer())
        self.engine = try AnalyzerEngine(
            registry: registry, nlpEngine: try TokenizerOnlyNlpEngine()
        )
    }

    /// A detector backed by a language model, so names and places are found too.
    ///
    /// ```swift
    /// import PresidioModelEnglish
    /// let detector = try PIIDetector(
    ///     nlpEngine: try SpacyNlpEngine(modelDirectory: EnglishModel.directory)
    /// )
    /// ```
    public init(nlpEngine: any NlpEngineProviding) throws {
        var registry = try RecognizerRegistry.loadPredefined()
        registry.add(SpacyRecognizer())
        self.engine = try AnalyzerEngine(registry: registry, nlpEngine: nlpEngine)
    }

    /// Full control: bring your own engine.
    public init(engine: AnalyzerEngine) {
        self.engine = engine
    }

    /// Anything the detector settled for — a missing tagger, a model-less
    /// pipeline. Empty when nothing was compromised.
    public var warnings: [String] { engine.configurationWarnings }

    /// Every entity type this detector can find.
    public var supportedTypes: [String] { engine.supportedEntities() }

    /// Find personal data.
    ///
    /// - Parameters:
    ///   - text: the text to scan.
    ///   - types: restrict to these entity types; omit for all of them.
    ///   - minimumConfidence: drop findings below this score.
    ///   - allowing: exact strings to treat as safe and never report.
    public func findings(
        in text: String,
        types: [String]? = nil,
        minimumConfidence: Double? = nil,
        allowing allowList: [String] = []
    ) throws -> [Finding] {
        let document = TextDocument(text)
        return try engine.analyze(
            text: text, entities: types,
            scoreThreshold: minimumConfidence, allowList: allowList
        ).map { result in
            Finding(
                type: result.entityType,
                text: document.substring(start: result.start, end: result.end) ?? "",
                start: result.start,
                end: result.end,
                confidence: result.score,
                recognizer: result.recognitionMetadata[
                    RecognizerResult.MetadataKey.recognizerName] ?? ""
            )
        }
    }

    /// True when the text contains any personal data — cheaper to read than
    /// `!findings(in:).isEmpty` and says what it means.
    public func containsPII(_ text: String, minimumConfidence: Double? = nil) throws -> Bool {
        try !findings(in: text, minimumConfidence: minimumConfidence).isEmpty
    }
}
