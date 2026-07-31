import Foundation

/// Loader for the conformance corpus harvested from Presidio's own test suite
/// by `Tools/extract_fixtures.py`.
///
/// The corpus is the contract: it encodes upstream's expectations, so a Swift
/// recognizer is "correct" when it reproduces these spans and scores. Nothing
/// here is hand-authored.
public enum Corpus {

    // MARK: - Recognizer (span) cases

    public struct RecognizerCorpus: Codable, Sendable {
        public let schemaVersion: Int
        public let source: Source
        public let stats: Stats
        public let recognizers: [String]
        public let entityTypes: [String]
        public let tables: [Table]
        public let skipped: [Skipped]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case source, stats, recognizers
            case entityTypes = "entity_types"
            case tables, skipped
        }
    }

    public struct Source: Codable, Sendable {
        public let repo: String
        public let commit: String
    }

    public struct Stats: Codable, Sendable {
        public let tables: Int
        public let cases: Int
        public let recognizers: Int
    }

    public struct Skipped: Codable, Sendable {
        public let file: String
        public let reason: String
        public let rows: Int?
    }

    public struct Table: Codable, Sendable {
        public let recognizer: String
        public let entities: [String]
        public let file: String
        public let test: String
        /// Which pytest fixture built the recognizer for this table. Upstream
        /// constructs the same class several ways in one file — notably
        /// `recognizer` (heuristic) vs `strict_recognizer` for DE_VAT_ID —
        /// and their expectations differ.
        public let fixture: String
        public let cases: [Case]
    }

    public struct Case: Codable, Sendable {
        public let text: String
        /// Authoritative number of results upstream asserts.
        public let expectedCount: Int
        /// Enumerated spans. May be shorter than `expectedCount` when the
        /// upstream table asserted a length without listing every position —
        /// Python's `zip()` silently ignores the surplus, so this must not be
        /// treated as the full expectation.
        public let expected: [Span]
        public let spansEnumerated: Bool

        enum CodingKeys: String, CodingKey {
            case text
            case expectedCount = "expected_count"
            case expected
            case spansEnumerated = "spans_enumerated"
        }
    }

    public struct Span: Codable, Sendable {
        public let start: Int
        public let end: Int
        public let entity: String?
        public let scoreMin: Double
        public let scoreMax: Double

        enum CodingKeys: String, CodingKey {
            case start, end, entity
            case scoreMin = "score_min"
            case scoreMax = "score_max"
        }

        /// A public struct's memberwise init is internal, so declare one
        /// explicitly for test targets that build expectations by hand.
        public init(
            start: Int, end: Int, entity: String?, scoreMin: Double, scoreMax: Double
        ) {
            self.start = start
            self.end = end
            self.entity = entity
            self.scoreMin = scoreMin
            self.scoreMax = scoreMax
        }

        /// Upstream compares scores with a 1e-5 epsilon
        /// (`presidio-analyzer/tests/assertions.py`). Reproduce it or you will
        /// chase float-comparison ghosts.
        public func accepts(score: Double) -> Bool {
            score >= max(0.0, scoreMin - 1e-5) && score <= min(1.0, scoreMax + 1e-5)
        }
    }

    // MARK: - Validator cases

    public struct ValidatorCorpus: Codable, Sendable {
        public let schemaVersion: Int
        public let source: Source
        public let tables: [ValidatorTable]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case source, tables
        }
    }

    public struct ValidatorTable: Codable, Sendable {
        public let recognizer: String
        public let file: String
        public let test: String
        public let cases: [ValidatorCase]
    }

    public struct ValidatorCase: Codable, Sendable {
        public let input: String
        public let expected: Outcome

        /// Presidio's `validate_result` is tri-state, and the middle state is
        /// load-bearing: `nil` means "checksum failed but the structure is
        /// valid", which keeps the match at its pattern score instead of
        /// dropping it.
        public enum Outcome: String, Codable, Sendable {
            case valid
            case invalid
            case indeterminate

            /// The Python value this maps to: `True` / `False` / `None`.
            public var asOptionalBool: Bool? {
                switch self {
                case .valid: return true
                case .invalid: return false
                case .indeterminate: return nil
                }
            }
        }
    }

    // MARK: - Loading

    public enum LoadError: Error, CustomStringConvertible {
        case missingResource(String)

        public var description: String {
            switch self {
            case .missingResource(let name):
                return """
                    Fixture '\(name)' not found in the bundle. Regenerate it with:
                      python3 Tools/extract_fixtures.py --presidio <checkout> \
                    --out Tests/PresidioConformance/Fixtures/recognizer_cases.json
                    """
            }
        }
    }

    /// Raw bytes of a bundled fixture.
    ///
    /// Resources live in this target's bundle, so other test targets must go
    /// through here rather than reaching for their own `Bundle.module` — which
    /// resolves to an empty bundle and fails at runtime.
    public static func data(named name: String, extension ext: String = "json") throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext)
        else { throw LoadError.missingResource(name) }
        return try Data(contentsOf: url)
    }

    private static func load<T: Decodable>(_ name: String, as: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: data(named: name))
    }

    public static func recognizerCases() throws -> RecognizerCorpus {
        try load("recognizer_cases", as: RecognizerCorpus.self)
    }

    public static func validatorCases() throws -> ValidatorCorpus {
        try load("validator_cases", as: ValidatorCorpus.self)
    }
}
