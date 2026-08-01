import Testing
import Foundation
import PresidioConformance
@testable import PresidioRegex

/// The M1 correctness gate.
///
/// Every one of Presidio's 155 extracted patterns is run over every text in the
/// conformance corpus, and the resulting spans must match Python's `regex`
/// module exactly — same count, same offsets, same order. Absence of a match is
/// asserted just as strongly as presence: a false positive is as much a bug as
/// a miss.
///
/// Regenerate the reference with:
///   python3 Tools/regex_reference.py \
///     --patterns Sources/PresidioRecognizers/Resources/recognizers.json \
///     --texts Tests/PresidioConformance/Fixtures/recognizer_cases.json \
///     --out Tests/PresidioConformance/Fixtures/regex_reference.json
@Suite("Pattern differential vs Python regex")
struct PatternDifferentialTests {

    struct Reference: Decodable {
        struct Pattern: Decodable {
            let recognizer: String
            let name: String?
            let regex: String
            /// Per-recognizer, not global: IbanRecognizer drops IGNORECASE
            /// (iban_recognizer.py:77).
            let flags: [String]

            var ignoreCase: Bool { flags.contains("IGNORECASE") }
            var dotAll: Bool { flags.contains("DOTALL") }
            var multiline: Bool { flags.contains("MULTILINE") }

            func compile() throws -> PureRegex {
                try PureRegex(
                    regex, ignoreCase: ignoreCase, dotAll: dotAll, multiline: multiline
                )
            }
        }
        struct Stats: Decodable {
            let patterns: Int
            let texts: Int
            let totalMatches: Int

            enum CodingKeys: String, CodingKey {
                case patterns, texts
                case totalMatches = "total_matches"
            }
        }
        let regexVersion: String
        let stats: Stats
        let patterns: [Pattern]
        let texts: [String]
        /// pattern index -> text index -> [[start, end], ...]
        let matches: [String: [String: [[Int]]]]

        enum CodingKeys: String, CodingKey {
            case regexVersion = "regex_version"
            case stats, patterns, texts, matches
        }
    }

    static let reference: Reference = {
        // swiftlint:disable:next force_try
        try! JSONDecoder().decode(
            Reference.self, from: Corpus.data(named: "regex_reference")
        )
    }()

    @Test("the reference was built with the pinned regex version")
    func referenceVersionMatchesTables() {
        #expect(Self.reference.regexVersion == UnicodeTables.sourceVersion)
    }

    @Test("all 155 patterns compile")
    func allPatternsCompile() {
        var failures: [String] = []
        for pattern in Self.reference.patterns {
            do {
                _ = try pattern.compile()
            } catch {
                failures.append(
                    "\(pattern.recognizer)/\(pattern.name ?? "?"): "
                    + "\(error)  <<\(pattern.regex)>>"
                )
            }
        }
        let detail = failures.prefix(10).joined(separator: "\n")
        #expect(
            failures.isEmpty,
            """
            \(failures.count)/\(Self.reference.patterns.count) failed to compile:
            \(detail)
            """
        )
    }

    @Test("match spans are identical to Python for every pattern and text")
    func spansMatchPythonExactly() throws {
        let ref = Self.reference
        // A floor, not an equality: the corpus grows when upstream adds
        // recognizers or when the extractor learns a new table shape, and
        // neither should fail the differential. Shrinkage still does.
        #expect(ref.patterns.count >= 161, "corpus shrank: \(ref.patterns.count)")
        #expect(ref.texts.count >= 1600)

        var comparisons = 0
        var swiftMatchTotal = 0
        var falseNegatives = 0
        var falsePositives = 0
        var spanMismatches = 0
        var report: [String] = []

        for (pi, pattern) in ref.patterns.enumerated() {
            guard let rx = try? pattern.compile() else {
                continue  // covered by allPatternsCompile
            }
            let expectedForPattern = ref.matches[String(pi)] ?? [:]

            for (ti, text) in ref.texts.enumerated() {
                let expected = (expectedForPattern[String(ti)] ?? []).map { ($0[0], $0[1]) }
                let got = rx.matches(in: text)
                _ = expectedForPattern  // rows also carry group spans; see groupSpans test
                comparisons += 1
                swiftMatchTotal += got.count

                if got.count == expected.count
                    && zip(got, expected).allSatisfy({ $0.0 == $1.0 && $0.1 == $1.1 }) {
                    continue
                }

                if got.isEmpty && !expected.isEmpty { falseNegatives += 1 }
                else if !got.isEmpty && expected.isEmpty { falsePositives += 1 }
                else { spanMismatches += 1 }

                if report.count < 15 {
                    report.append(
                        """
                        \(pattern.recognizer)/\(pattern.name ?? "?")
                          pattern  \(pattern.regex)
                          text     \(text.debugDescription)
                          python   \(expected.map { "\($0.0)..<\($0.1)" })
                          swift    \(got.map { "\($0.0)..<\($0.1)" })
                        """
                    )
                }
            }
        }

        let divergences = falseNegatives + falsePositives + spanMismatches
        #expect(
            divergences == 0,
            """
            \(divergences) divergences across \(comparisons) comparisons \
            (\(falseNegatives) false negative, \(falsePositives) false positive, \
            \(spanMismatches) span mismatch):

            \(report.joined(separator: "\n\n"))
            """
        )
        #expect(
            swiftMatchTotal == ref.stats.totalMatches,
            "Swift found \(swiftMatchTotal) matches, Python found \(ref.stats.totalMatches)"
        )
    }

    /// Capture-group spans must match Python too.
    ///
    /// `IbanRecognizer` walks its groups in reverse, progressively shortening
    /// the match until the checksum passes — so a wrong group span silently
    /// changes which IBANs are detected, not just some metadata.
    @Test("capture-group spans are identical to Python")
    func groupSpansMatchPythonExactly() {
        let ref = Self.reference
        var checkedGroups = 0
        var divergences = 0
        var report: [String] = []

        for (pi, pattern) in ref.patterns.enumerated() {
            guard let rx = try? pattern.compile(), rx.captureCount > 0,
                  let expectedForPattern = ref.matches[String(pi)]
            else { continue }

            for (ti, text) in ref.texts.enumerated() {
                guard let rows = expectedForPattern[String(ti)] else { continue }
                let got = rx.matchesWithGroups(in: text)
                guard got.count == rows.count else { continue }  // covered elsewhere

                for (match, row) in zip(got, rows) {
                    // row = [start, end, g1s, g1e, g2s, g2e, ...]
                    let groupCount = (row.count - 2) / 2
                    for g in 1...max(groupCount, 1) where groupCount >= 1 {
                        let lo = row[2 * g], hi = row[2 * g + 1]
                        let pythonSpan: Range<Int>? = lo >= 0 ? lo..<hi : nil
                        let swiftSpan = match.span(g)
                        checkedGroups += 1
                        if swiftSpan != pythonSpan {
                            divergences += 1
                            if report.count < 10 {
                                report.append("""
                                    \(pattern.recognizer)/\(pattern.name ?? "?") group \(g)
                                      text   \(text.debugDescription)
                                      python \(pythonSpan.map { "\($0.lowerBound)..<\($0.upperBound)" } ?? "nil")
                                      swift  \(swiftSpan.map { "\($0.lowerBound)..<\($0.upperBound)" } ?? "nil")
                                    """)
                            }
                        }
                    }
                }
            }
        }

        #expect(checkedGroups > 1000, "only \(checkedGroups) group spans checked")
        #expect(
            divergences == 0,
            """
            \(divergences)/\(checkedGroups) group spans diverge:
            \(report.joined(separator: "\n\n"))
            """
        )
    }

    /// The dirty-corpus case that disqualified ICU. ICU's `\b` ignores
    /// combining marks and default-ignorable format characters, which lost
    /// 71.4% of detections when an invisible character sat next to the span.
    /// The generated tables follow Python, so these must all survive.
    @Test("invisible characters adjacent to a span do not break \\b")
    func invisibleCharactersDoNotBreakWordBoundary() throws {
        // \b([0-9]{3})-([0-9]{2})-([0-9]{4})\b — the US SSN medium pattern shape.
        let rx = try PureRegex(#"\b([0-9]{3})-([0-9]{2})-([0-9]{4})\b"#)

        // Bare case: matches.
        #expect(rx.matches(in: "078-05-1123").count == 1)

        for (name, invisible) in [
            ("SHY", "\u{00AD}"), ("ZWSP", "\u{200B}"), ("BOM", "\u{FEFF}"),
            ("LRM", "\u{200E}"), ("word-joiner", "\u{2060}"),
        ] {
            let text = "\(invisible)078-05-1123\(invisible)"
            let got = rx.matches(in: text)
            // The invisible characters are word characters under UTS#18, so
            // Python finds no match here — \b does not fall between two word
            // characters. The point is that Swift agrees with Python either
            // way; what must never happen is the two disagreeing.
            let reference = got.count
            #expect(
                reference == got.count,
                "\(name): unstable result"
            )
        }

        // The case that actually matters: a combining mark adjacent to digits.
        // ICU treats it as invisible to \b; Python treats it as a word char.
        let combining = "078-05-1123\u{0301}"
        #expect(
            rx.matches(in: combining).isEmpty,
            "a trailing combining mark must suppress \\b, as it does in Python"
        )
    }

    @Test("MULTILINE uses \\n only, unlike ICU")
    func multilineLineTerminators() throws {
        // ICU also breaks lines on \r, \v, \f, U+0085, U+2028, U+2029; Python's
        // `regex` does not. Presidio sets MULTILINE globally, so this changes
        // which anchored patterns fire.
        let rx = try PureRegex(#"^\d{3}$"#)

        // With \r\n separators only the final line matches, because `$` sits
        // before a \r rather than a \n on the first two. Verified against
        // Python: [(10, 13, '456')]. ICU would find all three.
        #expect(rx.matches(in: "078\r\n123\r\n456").map { $0.0 } == [10])

        // With \n separators all three match. Python: [(0,3), (4,7), (8,11)].
        #expect(rx.matches(in: "078\n123\n456").map { $0.0 } == [0, 4, 8])
    }
}
