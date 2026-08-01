import Foundation
import PresidioCore
import PresidioAnalyzer

/// A value in a batch request.
///
/// Python passes `Any` and branches on `type(value)`. Swift needs the shape up
/// front, so the four primitive cases upstream accepts — `str`, `int`, `float`,
/// `bool` — plus the two containers it recurses into are modelled explicitly.
/// Anything else raises there and is simply unrepresentable here.
public indirect enum BatchValue: Sendable, Equatable {
    case text(String)
    case integer(Int)
    case number(Double)
    case boolean(Bool)
    case list([BatchValue])
    /// Ordered, because the output order follows the input and Swift
    /// dictionaries have no order to follow. See `analyzeDictionary`.
    case dictionary([(key: String, value: BatchValue)])

    /// `str(value)` for the primitives.
    ///
    /// Note `True`/`False` rather than `true`/`false`: Python stringifies bools
    /// with a capital letter, and the analyzer sees that text.
    public var asText: String? {
        switch self {
        case .text(let value): return value
        case .integer(let value): return String(value)
        case .number(let value):
            // Python prints a float without a trailing `.0` only when it has
            // a fractional part; `str(3.0)` is "3.0".
            return String(value)
        case .boolean(let value): return value ? "True" : "False"
        case .list, .dictionary: return nil
        }
    }

    /// Python's truthiness, which decides whether a key is analyzed at all.
    ///
    /// `if not value` skips empty strings, zero, `False` and empty containers
    /// alike — so a field holding `0` or `False` is never analyzed.
    public var isFalsy: Bool {
        switch self {
        case .text(let value): return value.isEmpty
        case .integer(let value): return value == 0
        case .number(let value): return value == 0
        case .boolean(let value): return !value
        case .list(let values): return values.isEmpty
        case .dictionary(let pairs): return pairs.isEmpty
        }
    }

    public static func == (lhs: BatchValue, rhs: BatchValue) -> Bool {
        switch (lhs, rhs) {
        case (.text(let a), .text(let b)): return a == b
        case (.integer(let a), .integer(let b)): return a == b
        case (.number(let a), .number(let b)): return a == b
        case (.boolean(let a), .boolean(let b)): return a == b
        case (.list(let a), .list(let b)): return a == b
        case (.dictionary(let a), .dictionary(let b)):
            return a.count == b.count
                && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: return false
        }
    }
}

/// Port of `DictAnalyzerResult`.
public struct DictAnalyzerResult: Sendable {
    public let key: String
    public let value: BatchValue
    public let results: BatchResults
}

/// What analysis produced for one value, mirroring its shape.
public indirect enum BatchResults: Sendable {
    /// A single value.
    case single([RecognizerResult])
    /// A list of values: one result list per element.
    case list([[RecognizerResult]])
    /// A nested dictionary.
    case nested([DictAnalyzerResult])

    /// Every result, flattened — for callers that only want the findings.
    public var flattened: [RecognizerResult] {
        switch self {
        case .single(let results): return results
        case .list(let lists): return lists.flatMap { $0 }
        case .nested(let entries): return entries.flatMap(\.results.flattened)
        }
    }
}

/// Port of `BatchAnalyzerEngine`: runs the analyzer over lists and dictionaries.
///
/// The interesting part is not the iteration but what the keys do — a
/// dictionary key is passed to `analyze` as context, so a value under
/// `"credit_card"` scores higher than the same digits under `"notes"`.
public struct BatchAnalyzerEngine: Sendable {

    public let analyzer: AnalyzerEngine

    public init(analyzer: AnalyzerEngine) {
        self.analyzer = analyzer
    }

    /// Port of `analyze_iterator`.
    ///
    /// `batchSize` and `nProcess` are absent deliberately: upstream forwards
    /// them to spaCy's `nlp.pipe` purely as throughput tuning, and upstream's
    /// own test for them asserts only that results are unchanged. Accepting
    /// parameters that cannot affect the answer would be noise.
    public func analyze(
        texts: [BatchValue],
        language: String = "en",
        entities: [String]? = nil,
        scoreThreshold: Double? = nil,
        context: [String]? = nil,
        allowList: [String] = [],
        allowListMatch: AnalyzerEngine.AllowListMatch = .exact
    ) throws -> [[RecognizerResult]] {
        try texts.map { value in
            guard let text = value.asText else {
                throw BatchError.unsupportedValue(
                    "analyze(texts:) accepts primitives only; "
                    + "lists of objects are not supported"
                )
            }
            return try analyzer.analyze(
                text: text, language: language, entities: entities,
                scoreThreshold: scoreThreshold, context: context,
                allowList: allowList, allowListMatch: allowListMatch
            )
        }
    }

    /// Convenience for the common case of plain strings.
    public func analyze(
        texts: [String], language: String = "en", context: [String]? = nil
    ) throws -> [[RecognizerResult]] {
        try analyze(texts: texts.map(BatchValue.text), language: language, context: context)
    }

    public enum BatchError: Error, Equatable, CustomStringConvertible {
        case unsupportedValue(String)

        public var description: String {
            switch self {
            case .unsupportedValue(let detail): return detail
            }
        }
    }

    /// Port of `analyze_dict`.
    ///
    /// Two upstream behaviours are reproduced that look like bugs and are not
    /// mine to fix:
    ///
    /// * A falsy value is skipped entirely — a field holding `0`, `false` or
    ///   `""` is never analyzed, and yields an empty result rather than being
    ///   examined.
    /// * A primitive value is analyzed with `context: [key]` — just its own
    ///   key — while a nested dictionary or list receives the *accumulated*
    ///   path context. So `{"a": {"b": "..."}}` analyzes with `["a", "b"]`
    ///   but `{"b": "..."}` analyzes with `["b"]`.
    public func analyzeDictionary(
        _ input: [(key: String, value: BatchValue)],
        language: String = "en",
        keysToSkip: [String] = [],
        entities: [String]? = nil,
        scoreThreshold: Double? = nil,
        context: [String] = []
    ) throws -> [DictAnalyzerResult] {
        var out: [DictAnalyzerResult] = []

        for (key, value) in input {
            guard !value.isFalsy, !keysToSkip.contains(key) else {
                out.append(
                    DictAnalyzerResult(key: key, value: value, results: .single([]))
                )
                continue
            }

            var specificContext = context
            specificContext.append(key)

            let results: BatchResults
            switch value {
            case .text, .integer, .number, .boolean:
                results = .single(
                    try analyzer.analyze(
                        text: value.asText ?? "", language: language,
                        entities: entities, scoreThreshold: scoreThreshold,
                        context: [key]
                    )
                )
            case .dictionary(let nested):
                results = .nested(
                    try analyzeDictionary(
                        nested, language: language,
                        keysToSkip: Self.nestedKeysToSkip(key, keysToSkip),
                        entities: entities, scoreThreshold: scoreThreshold,
                        context: specificContext
                    )
                )
            case .list(let values):
                results = .list(
                    try analyze(
                        texts: values, language: language, entities: entities,
                        scoreThreshold: scoreThreshold, context: specificContext
                    )
                )
            }
            out.append(DictAnalyzerResult(key: key, value: value, results: results))
        }
        return out
    }

    /// Unordered convenience. Swift dictionaries have no order, and the output
    /// follows the input, so keys are sorted to make the result deterministic —
    /// Python yields in insertion order, which has no Swift equivalent.
    public func analyzeDictionary(
        _ input: [String: BatchValue],
        language: String = "en",
        keysToSkip: [String] = [],
        context: [String] = []
    ) throws -> [DictAnalyzerResult] {
        try analyzeDictionary(
            input.keys.sorted().map { (key: $0, value: input[$0]!) },
            language: language, keysToSkip: keysToSkip, context: context
        )
    }

    /// Port of `_get_nested_keys_to_skip`.
    ///
    /// Note this is `startswith(key)` and a plain `replace`, not a path split:
    /// `"a.b"` under key `"a"` becomes `"b"`, but so does `"ab.b"` under
    /// `"ab"`, and a key merely *prefixed* by another is caught too. Ported as
    /// written.
    static func nestedKeysToSkip(_ key: String, _ keysToSkip: [String]) -> [String] {
        keysToSkip
            .filter { $0.hasPrefix(key) }
            .map { $0.replacingOccurrences(of: "\(key).", with: "") }
    }
}
