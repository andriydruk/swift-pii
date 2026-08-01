import Testing
import Foundation
import PresidioConformance
@testable import PresidioNLP

/// Token-for-token differential against spaCy.
///
/// Three things must match, and all three are load-bearing:
///
///  * **Text** — token boundaries decide what the NER model sees.
///  * **Offset** — in Unicode scalars, so a span maps back onto the source.
///  * **NORM** — consumed directly as an NER feature, and *not* simply the
///    lowercase form.
///
/// Regenerate the gold file from a spaCy install; see Tools/extract_tokenizer.py
/// for the rule extraction that feeds the Swift side.
@Suite("spaCy tokenizer parity")
struct TokenizerTests {

    struct Gold: Decodable {
        struct Case: Decodable {
            struct Tok: Decodable {
                let text: String
                let offset: Int
                let norm: String
            }
            let text: String
            let tokens: [Tok]
        }
        let spacyVersion: String
        let cases: [Case]

        enum CodingKeys: String, CodingKey {
            case spacyVersion = "spacy_version"
            case cases
        }
    }

    static let gold: Gold = {
        // swiftlint:disable:next force_try
        try! JSONDecoder().decode(Gold.self, from: Corpus.data(named: "tokenizer_gold"))
    }()

    /// Built per test rather than shared: `SpacyTokenizer` keeps a span cache
    /// and lazily-built special-case tables, so it is not `Sendable`.
    static func makeTokenizer() throws -> SpacyTokenizer {
        try SpacyTokenizer.english()
    }

    @Test("rules were extracted from the same spaCy the gold file used")
    func versionsAgree() throws {
        let tokenizer = try Self.makeTokenizer()
        #expect(tokenizer.spacyVersion == Self.gold.spacyVersion)
    }

    @Test("token text and offsets match spaCy exactly")
    func tokensMatch() throws {
        try withLargeStack {
            let tokenizer = try Self.makeTokenizer()
            var checked = 0
            var divergences = 0
            var report: [String] = []

            for testCase in Self.gold.cases {
                let produced = tokenizer.tokenize(testCase.text)
                let expected = testCase.tokens

                if produced.count != expected.count {
                    divergences += 1
                    if report.count < 10 {
                        report.append("""
                            count: \(testCase.text.debugDescription)
                              spacy \(expected.map(\.text))
                              swift \(produced.map(\.text))
                            """)
                    }
                    continue
                }
                for (got, want) in zip(produced, expected) {
                    checked += 1
                    if got.text != want.text || got.offset != want.offset {
                        divergences += 1
                        if report.count < 10 {
                            report.append("""
                                token: \(testCase.text.debugDescription)
                                  spacy \(want.text.debugDescription)@\(want.offset)
                                  swift \(got.text.debugDescription)@\(got.offset)
                                """)
                        }
                        break
                    }
                }
            }

            #expect(checked >= 50_000, "only \(checked) tokens compared")
            #expect(
                divergences == 0,
                """
                \(divergences) token divergences over \(Self.gold.cases.count) texts:
                \(report.joined(separator: "\n"))
                """
            )
        }
    }

    @Test("NORMs match spaCy exactly")
    func normsMatch() throws {
        try withLargeStack {
            let tokenizer = try Self.makeTokenizer()
            var checked = 0
            var divergences = 0
            var report: [String] = []

            for testCase in Self.gold.cases {
                let produced = tokenizer.tokenize(testCase.text)
                guard produced.count == testCase.tokens.count else { continue }
                for (got, want) in zip(produced, testCase.tokens) {
                    checked += 1
                    if got.norm != want.norm {
                        divergences += 1
                        if report.count < 15 {
                            report.append(
                                "\(got.text.debugDescription): spacy "
                                + "\(want.norm.debugDescription), swift "
                                + "\(got.norm.debugDescription)"
                            )
                        }
                    }
                }
            }

            #expect(checked >= 50_000)
            #expect(
                divergences == 0,
                """
                \(divergences)/\(checked) NORM divergences:
                \(report.joined(separator: "\n"))
                """
            )
        }
    }

    /// The NORM rule is subtle enough to pin case by case.
    @Test("NORM resolution order", arguments: [
        // lexeme_norm is keyed by the EXACT surface form, not lowercased.
        ("licence", "license"),
        ("PLZ", "plz"),        // only "plz" is a key, so this falls back to lower
        ("plz", "please"),
        // BASE_NORMS folds punctuation.
        ("`", "'"),
        ("\u{2014}", "-"),     // em dash
        ("\u{2026}", "..."),   // ellipsis
        // Everything else is just lowercase.
        ("Bond", "bond"),
        ("HELLO", "hello"),
    ])
    func normResolution(text: String, expected: String) throws {
        let tokenizer = try Self.makeTokenizer()
        #expect(tokenizer.norm(for: text) == expected)
    }

    /// Contraction NORMs come from the tokenizer exception that produced the
    /// piece, not from any surface-form table — "gonna" splits into pieces
    /// carrying "going"/"to", while a bare "a" elsewhere stays "a".
    @Test("contraction NORMs come from the splitting exception")
    func contractionNorms() throws {
        let tokenizer = try Self.makeTokenizer()
        let tokens = tokenizer.tokenize("I can't and won't")
        let norms = tokens.map(\.norm)
        #expect(norms.contains("not"))
        #expect(norms.contains("can"))
        #expect(norms.contains("will"))

        // The same letters standing alone must not pick up an exception NORM.
        let bare = tokenizer.tokenize("a b c")
        #expect(bare.map(\.norm) == ["a", "b", "c"])
    }

    @Test("offsets round-trip onto the source text")
    func offsetsRoundTrip() throws {
        try withLargeStack {
            let tokenizer = try Self.makeTokenizer()
            for testCase in Self.gold.cases.prefix(500) {
                let scalars = Array(testCase.text.unicodeScalars)
                for token in tokenizer.tokenize(testCase.text) {
                    let end = token.offset + token.text.unicodeScalars.count
                    guard token.offset >= 0, end <= scalars.count else {
                        Issue.record("span out of range in \(testCase.text.debugDescription)")
                        continue
                    }
                    let slice = String(String.UnicodeScalarView(scalars[token.offset..<end]))
                    #expect(slice == token.text)
                }
            }
        }
    }
}
