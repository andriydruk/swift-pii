import Foundation
import PresidioCore
import PresidioAnalyzer
import PresidioAnonymizer

/// Removes personal data from text.
///
/// The companion to `PIIDetector`: it takes the findings and rewrites those
/// spans. Each method is one call.
///
/// ```swift
/// let text = "Card 4095-2609-9393-4932"
/// try Anonymizer().redact(text, using: detector)   // "Card <CREDIT_CARD>"
/// ```
///
/// Every method takes an optional per-entity override, so one document can be
/// redacted in one place and masked in another.
public struct Anonymizer: Sendable {

    private let engine = AnonymizerEngine()

    public init() {}

    /// Replace each finding with its type in angle brackets.
    public func redact(
        _ text: String, using detector: PIIDetector,
        overrides: [String: String] = [:]
    ) throws -> String {
        try replace(text, using: detector, with: overrides, default: nil)
    }

    /// Replace each finding with a fixed string.
    ///
    /// `with` is keyed by entity type; anything not listed falls back to
    /// `default`, or to `<TYPE>` when that is nil too.
    public func replace(
        _ text: String, using detector: PIIDetector,
        with replacements: [String: String] = [:],
        default fallback: String? = nil
    ) throws -> String {
        var configs: [String: OperatorConfig] = [
            "DEFAULT": fallback.map { OperatorConfig("replace", ["new_value": .string($0)]) }
                ?? OperatorConfig("replace")
        ]
        for (type, value) in replacements {
            configs[type] = OperatorConfig("replace", ["new_value": .string(value)])
        }
        return try run(text, detector: detector, configs: configs)
    }

    /// Delete each finding, leaving nothing behind.
    public func remove(_ text: String, using detector: PIIDetector) throws -> String {
        try run(text, detector: detector, configs: ["DEFAULT": OperatorConfig("redact")])
    }

    /// Replace each finding's characters with a mask.
    ///
    /// - Parameter keepingLast: leave this many characters visible at the end,
    ///   the usual "last four digits" treatment.
    public func mask(
        _ text: String, using detector: PIIDetector,
        character: Character = "*", keepingLast visible: Int = 0
    ) throws -> String {
        // Upstream masks a fixed count from one end; masking "everything but
        // the last n" means masking a large number from the front.
        let config = OperatorConfig("mask", [
            "masking_char": .string(String(character)),
            "chars_to_mask": .int(visible > 0 ? 1_000 : 1_000),
            "from_end": .bool(false),
        ])
        guard visible > 0 else {
            return try run(text, detector: detector, configs: ["DEFAULT": config])
        }
        // Mask from the start, leaving `visible` characters: apply per finding
        // so the count can depend on its length.
        let findings = try detector.findings(in: text)
        var entities: [PIIEntity] = []
        var configs: [String: OperatorConfig] = [:]
        for finding in findings {
            let maskable = max(finding.end - finding.start - visible, 0)
            entities.append(
                PIIEntity(start: finding.start, end: finding.end,
                          entityType: finding.type, score: finding.confidence)
            )
            configs[finding.type] = OperatorConfig("mask", [
                "masking_char": .string(String(character)),
                "chars_to_mask": .int(maskable),
                "from_end": .bool(false),
            ])
        }
        configs["DEFAULT"] = config
        return try engine.anonymize(
            text: text, analyzerResults: entities.map(Self.recognizerResult),
            operators: configs
        ).text
    }

    /// Replace each finding with a salted SHA-256 of its text.
    ///
    /// The salt is required: a random one would make the output irreproducible
    /// and silently unlinkable across runs, so it is the caller's to choose and
    /// to keep.
    public func hash(
        _ text: String, using detector: PIIDetector, salt: String
    ) throws -> String {
        try run(text, detector: detector, configs: [
            "DEFAULT": OperatorConfig("hash", [
                "salt": .string(salt), "hash_type": .string("sha256"),
            ])
        ])
    }

    /// Rewrite findings with a function of your own.
    public func transform(
        _ text: String, using detector: PIIDetector,
        _ body: @escaping @Sendable (String) -> String
    ) throws -> String {
        try run(text, detector: detector, configs: [
            "DEFAULT": OperatorConfig("custom", ["lambda": .function(body)])
        ])
    }

    private func run(
        _ text: String, detector: PIIDetector, configs: [String: OperatorConfig]
    ) throws -> String {
        let findings = try detector.findings(in: text)
        let results = findings.map {
            RecognizerResult(
                entityType: $0.type, start: $0.start, end: $0.end, score: $0.confidence
            )
        }
        return try engine.anonymize(
            text: text, analyzerResults: results, operators: configs
        ).text
    }

    private static func recognizerResult(_ entity: PIIEntity) -> RecognizerResult {
        RecognizerResult(
            entityType: entity.entityType, start: entity.start,
            end: entity.end, score: entity.score
        )
    }
}
