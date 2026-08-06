import PresidioCore
import PresidioRegex

/// Detects one entity type using a list of regex patterns plus optional
/// checksum logic.
///
/// Ported from `presidio_analyzer.PatternRecognizer.__analyze_patterns`. The
/// scoring and deduplication order is reproduced exactly; where Python's
/// behaviour is nondeterministic, the divergence is documented at the point it
/// occurs.
///
/// `Sendable`: immutable after construction, and `PureRegex` keeps no match
/// state (each call builds its own VM). One recognizer can therefore be shared
/// across tasks, which is what makes a concurrent sweep possible — measured at
/// 7.3x on 14 cores.
public final class PatternRecognizer: Sendable {

    public let name: String
    public let entity: String
    public let patterns: [Pattern]
    public let context: [String]
    public let logic: RecognizerLogic
    public let flags: RegexFlags
    public let strategy: MatchStrategy
    /// Language this recognizer is for, as an ISO code.
    ///
    /// The registry filters on it, so a recognizer that reports the wrong one
    /// is simply never selected. It has to be carried explicitly: the protocol
    /// default is "en", and inheriting that silently made every non-English
    /// recognizer unreachable.
    public let language: String

    private let compiled: [(pattern: Pattern, regex: PureRegex)]

    /// Patterns that failed to compile. Surfaced rather than swallowed: a
    /// recognizer silently missing half its patterns looks like it works.
    ///
    /// The reason is stored as text rather than as an `Error`, which is not
    /// `Sendable` and would cost the whole type its conformance for a field
    /// that only ever gets printed.
    public let compilationFailures: [(pattern: Pattern, reason: String)]

    public init(
        name: String,
        entity: String,
        patterns: [Pattern],
        context: [String] = [],
        logic: RecognizerLogic = RecognizerLogic(),
        flags: RegexFlags = .presidioDefault,
        strategy: MatchStrategy = .wholeMatch,
        language: String = "en"
    ) {
        self.name = name
        self.entity = entity
        self.patterns = patterns
        self.context = context
        self.logic = logic
        self.flags = flags
        self.strategy = strategy
        self.language = language

        var compiled: [(Pattern, PureRegex)] = []
        var failures: [(Pattern, String)] = []
        for pattern in patterns {
            do {
                compiled.append((
                    pattern,
                    try PureRegex(
                        pattern.regex,
                        ignoreCase: flags.ignoreCase,
                        dotAll: flags.dotAll,
                        multiline: flags.multiline
                    )
                ))
            } catch {
                failures.append((pattern, String(describing: error)))
            }
        }
        self.compiled = compiled
        self.compilationFailures = failures
    }

    /// All matches in `text`, scored, validated and deduplicated.
    ///
    /// Offsets are Unicode scalar indices.
    public func analyze(_ text: String) -> [RecognizerResult] {
        let document = TextDocument(text)
        var results: [RecognizerResult] = []

        for (pattern, regex) in compiled {
            for match in regex.matchesWithGroups(in: text) {
                // Each candidate is tried in order; the first that survives
                // scoring wins and the rest are abandoned. With .wholeMatch
                // there is exactly one candidate, so this reduces to Presidio's
                // default path.
                for (start, end) in candidateSpans(for: match) {
                    guard let matched = document.substring(start: start, end: end),
                          !matched.isEmpty  // Python: `if current_match == "": continue`
                    else { continue }

                    var score = pattern.score

                    // validate_result: tri-state. `nil` (no validator) leaves
                    // the pattern score alone; .unknown does the same but is a
                    // deliberate "checksum failed, structure is fine" signal.
                    if let validate = logic.validate {
                        switch validate(matched) {
                        case .valid: score = Score.max
                        case .invalid: score = Score.min
                        case .unknown: break
                        }
                    }

                    // invalidate_result runs after, and can veto a valid checksum.
                    if logic.invalidate?(matched) == true {
                        score = Score.min
                    }

                    // Python appends only when score > MIN_SCORE, so a zeroed
                    // result never reaches deduplication.
                    guard score > Score.min else { continue }

                    results.append(
                        RecognizerResult(
                            entityType: entity,
                            start: start,
                            end: end,
                            score: score,
                            recognitionMetadata: [
                                RecognizerResult.MetadataKey.recognizerName: name
                            ]
                        )
                    )
                    break
                }
            }
        }

        return Self.removeDuplicates(results)
    }

    /// Candidate spans for a match, in the order they should be tried.
    private func candidateSpans(for match: PureRegex.Match) -> [(Int, Int)] {
        switch strategy {
        case .wholeMatch:
            return [(match.start, match.end)]

        case .shortestValidGroupPrefix:
            guard match.groupCount >= 1 else { return [(match.start, match.end)] }
            // Upstream: `for grp_num in reversed(range(1, len(groups) + 1))`,
            // with `end = span(grp)[1] if span(grp)[1] > 0 else span(0)[1]`.
            // Note the `> 0` rather than `>= 0`: a group ending at offset 0, or
            // one that did not participate (Python reports -1), both fall back
            // to the full match end. That quirk is reproduced deliberately.
            return (1...match.groupCount).reversed().map { group in
                let groupEnd = match.span(group)?.upperBound ?? -1
                return (match.start, groupEnd > 0 ? groupEnd : match.end)
            }
        }
    }

    /// Port of `EntityRecognizer.remove_duplicates`.
    ///
    /// Python does `list(set(results))` first, which dedupes on
    /// (entity_type, start, end, score) but leaves the surviving order
    /// dependent on `PYTHONHASHSEED`. It then sorts by
    /// `(-score, start, -(end - start))` — a key that omits `entity_type`, so
    /// ties stay nondeterministic upstream.
    ///
    /// We dedupe deterministically and sort with `entity_type` as the final
    /// tie-break (see `RecognizerResult.totalOrderIsLess`). For a single
    /// recognizer every result shares one entity type, so this cannot diverge
    /// from Python here; it matters once results from several recognizers are
    /// merged.
    public static func removeDuplicates(
        _ results: [RecognizerResult]
    ) -> [RecognizerResult] {
        var seen = Set<RecognizerResult>()
        var unique: [RecognizerResult] = []
        for result in results where seen.insert(result).inserted {
            unique.append(result)
        }

        var kept: [RecognizerResult] = []
        for result in unique.sortedDeterministically() {
            if result.score == 0 { continue }

            // Drop anything wholly inside an already-kept span of the same
            // entity type. Because the sort puts higher scores and longer spans
            // first, the survivor is the strongest enclosing match.
            let contained = kept.contains {
                result.containedIn($0) && result.entityType == $0.entityType
            }
            if !contained { kept.append(result) }
        }
        return kept
    }
}

public extension PatternRecognizer {
    /// A copy with different context words.
    ///
    /// The registry configuration can override a recognizer's context per
    /// language — `CreditCardRecognizer` gets Spanish context words under
    /// `es` — and `PatternRecognizer` is immutable, so the override has to
    /// rebuild rather than mutate.
    func withContext(_ context: [String]) -> PatternRecognizer {
        PatternRecognizer(
            name: name, entity: entity, patterns: patterns, context: context,
            logic: logic, flags: flags, strategy: strategy, language: language
        )
    }

    /// A copy that answers to a different language.
    ///
    /// Upstream instantiates one recognizer object *per language* — the same
    /// patterns, tagged differently — which is why `CreditCardRecognizer`
    /// appears four times in a registry configured for en, es, it and pl. The
    /// language is a property of the instantiation, not of the pattern data,
    /// so it belongs here rather than in the catalogue.
    func withLanguage(_ language: String) -> PatternRecognizer {
        PatternRecognizer(
            name: name, entity: entity, patterns: patterns, context: context,
            logic: logic, flags: flags, strategy: strategy, language: language
        )
    }
}

public extension PatternRecognizer {
    /// A copy compiled with different regex flags.
    ///
    /// The registry configuration carries `global_regex_flags`, and upstream's
    /// loader applies it to every recognizer it builds — overriding the flags
    /// a recognizer sets for itself. `IbanRecognizer` is the case that makes
    /// this visible: it defaults to `DOTALL | MULTILINE`, so on its own it is
    /// case-sensitive, but inside an `AnalyzerEngine` the default config's
    /// flags (26, which adds `IGNORECASE`) replace that. Both behaviours are
    /// upstream's; which one applies depends on how the recognizer was built.
    func withFlags(_ flags: RegexFlags) -> PatternRecognizer {
        PatternRecognizer(
            name: name, entity: entity, patterns: patterns, context: context,
            logic: logic, flags: flags, strategy: strategy, language: language
        )
    }
}

public extension RegexFlags {
    /// Decode Python `re` module flag bits.
    ///
    /// `re.IGNORECASE == 2`, `re.MULTILINE == 8`, `re.DOTALL == 16`; the
    /// default config ships 26, which is all three.
    init(pythonFlags bits: Int) {
        self.init(
            ignoreCase: bits & 2 != 0,
            dotAll: bits & 16 != 0,
            multiline: bits & 8 != 0
        )
    }
}

// MARK: - Deny lists

public extension PatternRecognizer {

    /// `PatternRecognizer`'s default `deny_list_score`.
    static let defaultDenyListScore = 1.0

    /// Build a recognizer that matches a fixed list of terms.
    ///
    /// Port of `PatternRecognizer(deny_list:)`, which compiles the terms into a
    /// single pattern rather than matching them literally. The boundary
    /// assertions are upstream's and are not `\b`: a term ending in `.` — the
    /// "Titles recognizer" in Presidio's own example config is `Mr.`, `Dr.` —
    /// has no word boundary after it, so `\b` would never match it.
    static func denyList(
        name: String,
        entity: String,
        terms: [String],
        context: [String] = [],
        score: Double = PatternRecognizer.defaultDenyListScore,
        flags: RegexFlags = .presidioDefault
    ) -> PatternRecognizer {
        PatternRecognizer(
            name: name, entity: entity,
            patterns: [denyListPattern(terms, score: score)],
            context: context, flags: flags
        )
    }

    /// Port of `_deny_list_to_regex`.
    static func denyListPattern(
        _ terms: [String], score: Double = PatternRecognizer.defaultDenyListScore
    ) -> Pattern {
        let escaped = terms.map(regexEscape).joined(separator: "|")
        return Pattern(
            name: "deny_list",
            regex: #"(?:^|(?<=\W))("# + escaped + #")(?:(?=\W)|$)"#,
            score: score
        )
    }

    /// Port of Python's `re.escape`.
    ///
    /// Since Python 3.7 this escapes *only* characters that can be special in a
    /// pattern, so it is a specific set rather than "everything non-alphanumeric":
    /// letters, digits, `_`, and every non-ASCII scalar are left alone. Escaping
    /// more than Python does would still match, but the generated pattern would
    /// stop being comparable to upstream's — and escaping less would change what
    /// a deny list matches.
    static func regexEscape(_ text: String) -> String {
        // CPython's `_special_chars_map`, verbatim.
        let special = Set<Unicode.Scalar>(
            "()[]{}?*+-|^$\\.&~# \t\n\r\u{0B}\u{0C}".unicodeScalars
        )
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if special.contains(scalar) { out.append("\\") }
            out.append(scalar)
        }
        return String(out)
    }
}
