/// A named regex with a confidence score.
///
/// Mirrors `presidio_analyzer.Pattern`.
public struct Pattern: Sendable, Hashable, Codable {
    public let name: String
    public let regex: String
    public let score: Double

    public init(name: String, regex: String, score: Double) {
        self.name = name
        self.regex = regex
        self.score = score
    }
}

/// The outcome of a checksum or structural check on a matched string.
///
/// Presidio's `validate_result` is deliberately tri-state and the middle state
/// is load-bearing — collapsing it into a boolean changes detection behaviour:
///
/// - `.valid`   → score is raised to `Score.max` (1.0)
/// - `.invalid` → score is dropped to `Score.min` (0), which discards the match
/// - `.unknown` → score is left at the pattern's own score
///
/// A recognizer running in "heuristic mode" returns `.unknown` when a checksum
/// fails but the structure is plausible, so the match survives at its pattern
/// score rather than being thrown away.
public enum Validation: Sendable, Hashable {
    case valid
    case invalid
    case unknown
}

/// Regex flags, applied per recognizer.
///
/// Presidio's default is `DOTALL | MULTILINE | IGNORECASE`
/// (`pattern_recognizer.py:59`), but it is not universal: `IbanRecognizer`
/// drops IGNORECASE (`iban_recognizer.py:77`) so its `[A-Z]{2}[0-9]{2}` stays
/// case-sensitive. Applying the default there matches lowercase text upstream
/// would never detect.
public struct RegexFlags: Sendable, Hashable {
    public var ignoreCase: Bool
    public var dotAll: Bool
    public var multiline: Bool

    public init(ignoreCase: Bool = true, dotAll: Bool = true, multiline: Bool = true) {
        self.ignoreCase = ignoreCase
        self.dotAll = dotAll
        self.multiline = multiline
    }

    public static let presidioDefault = RegexFlags()

    /// Build from the flag names carried in the extracted catalogue.
    public init(names: [String]) {
        let set = Set(names.map { $0.uppercased() })
        self.ignoreCase = set.contains("IGNORECASE") || set.contains("I")
        self.dotAll = set.contains("DOTALL") || set.contains("S")
        self.multiline = set.contains("MULTILINE") || set.contains("M")
    }
}

/// How candidate spans are derived from a regex match.
public enum MatchStrategy: Sendable, Hashable {
    /// One candidate per match: the whole match. Presidio's default.
    case wholeMatch

    /// Walk capture groups in reverse, using each group's end as a
    /// progressively shorter match end, and emit the first candidate that
    /// survives validation.
    ///
    /// This is `IbanRecognizer`'s fallback: for
    /// `"I want my deposit in DE89370400440532013000 2 days from today."` the
    /// widest match swallows trailing text and fails the checksum, so it
    /// retries shorter prefixes until one validates.
    case shortestValidGroupPrefix
}

public enum Score {
    /// `EntityRecognizer.MIN_SCORE`
    public static let min: Double = 0
    /// `EntityRecognizer.MAX_SCORE`
    public static let max: Double = 1.0
}

/// Per-recognizer logic that cannot be expressed as a pattern.
///
/// 55 of Presidio's recognizers define `validate_result` and/or
/// `invalidate_result` — Luhn variants, Verhoeff, mod-97/23/11/10 weighted
/// sums, date plausibility, base58/bech32. They are supplied here rather than
/// baked into the recognizer data because they are code, not configuration.
public struct RecognizerLogic: Sendable {
    /// Checksum / structural validation. `nil` means the recognizer defines no
    /// `validate_result`, which is different from returning `.unknown`.
    public var validate: (@Sendable (String) -> Validation)?

    /// `invalidate_result`: returning true forces the score to `Score.min`.
    /// Applied *after* `validate`, so it can veto a passing checksum.
    public var invalidate: (@Sendable (String) -> Bool)?

    public init(
        validate: (@Sendable (String) -> Validation)? = nil,
        invalidate: (@Sendable (String) -> Bool)? = nil
    ) {
        self.validate = validate
        self.invalidate = invalidate
    }
}
