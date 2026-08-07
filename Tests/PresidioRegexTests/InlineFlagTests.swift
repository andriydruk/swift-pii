import Testing
import Foundation
import PresidioConformance
import PresidioRegex

/// Inline flag groups, differentially against Python.
///
/// This engine used to parse `(?i)` and `(?iu)` and then ignore them. Nothing
/// failed: patterns compiled and matched, just case-sensitively when they
/// should not have. It surfaced only when French's `token_match` — 1.45 MB of
/// hyphenated compounds behind a leading `(?iu)` — started splitting
/// `Saint-Louis` while leaving `franco-italienne` whole.
///
/// The expectations come from `Tools/inline_flag_reference.py` running Python's
/// own `re`, not from reading this implementation, because an expectation
/// written by hand would only record what I believed.
@Suite("inline flag groups vs Python")
struct RegexInlineFlagTests {

    struct Gold: Decodable {
        struct Case: Decodable {
            struct Text: Decodable {
                let text: String
                let spans: [[Int]]
            }
            let pattern: String
            let ignoreCase: Bool
            let dotAll: Bool
            let multiline: Bool
            let texts: [Text]

            enum CodingKeys: String, CodingKey {
                case pattern, texts, multiline
                case ignoreCase = "ignore_case"
                case dotAll = "dot_all"
            }
        }
        let pythonVersion: String
        let cases: [Case]

        enum CodingKeys: String, CodingKey {
            case cases
            case pythonVersion = "python_version"
        }
    }

    static let gold: Gold = {
        // swiftlint:disable:next force_try
        try! JSONDecoder().decode(
            Gold.self, from: Corpus.data(named: "inline_flag_cases")
        )
    }()

    @Test("match spans are identical to Python")
    func matchesPython() throws {
        var checked = 0
        var divergences: [String] = []

        for testCase in Self.gold.cases {
            let regex = try PureRegex(
                testCase.pattern,
                ignoreCase: testCase.ignoreCase,
                dotAll: testCase.dotAll,
                multiline: testCase.multiline
            )
            for probe in testCase.texts {
                checked += 1
                let got = regex.matches(in: probe.text).map { [$0.0, $0.1] }
                if got != probe.spans {
                    divergences.append("""
                        \(testCase.pattern.debugDescription) on \
                        \(probe.text.debugDescription)
                          python \(probe.spans)
                          swift  \(got)
                        """)
                }
            }
        }

        print("inline flags: \(checked - divergences.count)/\(checked) match Python")
        #expect(divergences.isEmpty, "\(divergences.joined(separator: "\n"))")
        #expect(checked >= 40, "corpus too small: \(checked)")
    }

    /// A flag this engine cannot honour must be refused, not ignored.
    ///
    /// `a` redefines `\w`, `\d` and `\s` to ASCII-only; `x` makes whitespace
    /// insignificant. Accepting either and carrying on would produce a pattern
    /// that matches the wrong text with no indication anything was wrong —
    /// which is precisely the failure this whole change is about.
    @Test("unsupported flags are rejected", arguments: ["(?a)\\w+", "(?x) a b", "(?L)x"])
    func rejectsUnsupportedFlags(pattern: String) {
        #expect(throws: ParseError.self) { _ = try PureRegex(pattern) }
    }

    /// Multiline is decided at match time, so it cannot vary by subexpression.
    @Test("scoped multiline is refused rather than applied pattern-wide")
    func rejectsScopedMultiline() {
        #expect(throws: ParseError.self) { _ = try PureRegex("(?m:^a)") }
        #expect(throws: ParseError.self) { _ = try PureRegex("(?-m:^a)") }
        // The global form is fine, and is what patterns actually use.
        #expect(throws: Never.self) { _ = try PureRegex("(?m)^a") }
    }

    @Test("a malformed flag group is an error, not a silent no-op")
    func rejectsMalformedGroups() {
        #expect(throws: ParseError.self) { _ = try PureRegex("(?i") }
        #expect(throws: ParseError.self) { _ = try PureRegex("(?i-i:a)") }
        #expect(throws: ParseError.self) { _ = try PureRegex("(?i--s:a)") }
    }

    /// The case that started it: a leading `(?iu)` must make the pattern
    /// case-insensitive even though the caller asked for case-sensitive.
    @Test("a leading (?iu) overrides a case-sensitive caller")
    func leadingFlagsOverrideCaller() throws {
        let regex = try PureRegex("(?iu)saint-louis", ignoreCase: false)
        #expect(!regex.matches(in: "Saint-Louis").isEmpty)
        #expect(!regex.matches(in: "SAINT-LOUIS").isEmpty)

        // ...and without the group, the caller's flag still stands.
        let sensitive = try PureRegex("saint-louis", ignoreCase: false)
        #expect(sensitive.matches(in: "Saint-Louis").isEmpty)
    }
}
