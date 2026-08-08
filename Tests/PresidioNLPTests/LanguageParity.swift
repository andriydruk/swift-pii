import Foundation
import PresidioConformance
@testable import PresidioNLP

/// Shared machinery for the per-language parity suites.
///
/// Three languages now measure the same four things — tokens, tags, lemmas,
/// entity spans — against corpora with an identical shape. Written out three
/// times, the measurement code would drift, and a suite that drifts quietly is
/// worse than no suite: it keeps printing a number that no longer means what it
/// says.
///
/// The harness only *measures*. Every assertion stays in the suite that owns it,
/// so a failure names the language rather than pointing here.

/// Where to find an unpacked model for a language: `SPACY_DE_MODEL_DIR` and so
/// on. Each language's corpus is tied to one model version, recorded in the
/// gold file — a different patch release has different weights and reads as a
/// catastrophic regression when it is only version skew.
func modelDirectory(_ language: String) -> String? {
    ProcessInfo.processInfo.environment["SPACY_\(language.uppercased())_MODEL_DIR"]
}

struct LanguageGold: Decodable {
    struct Case: Decodable {
        struct Token: Decodable {
            let text: String
            let offset: Int
            let norm: String
            let tag: String
            let pos: String
            let lemma: String
            let sentStart: Bool

            enum CodingKeys: String, CodingKey {
                case text, offset, norm, tag, pos, lemma
                case sentStart = "sent_start"
            }
        }
        struct Entity: Decodable {
            let label: String
            let start: Int
            let end: Int
            let text: String
        }
        let text: String
        let tokens: [Token]
        let entities: [Entity]

        /// Token indices spaCy's parser marked as sentence starts.
        var sentenceStarts: Set<Int> {
            Set(tokens.indices.filter { tokens[$0].sentStart })
        }
    }
    let model: String
    let spacyVersion: String
    let cases: [Case]

    enum CodingKeys: String, CodingKey {
        case model
        case spacyVersion = "spacy_version"
        case cases
    }

    static func load(_ language: String) -> LanguageGold {
        // swiftlint:disable:next force_try
        try! JSONDecoder().decode(
            LanguageGold.self, from: Corpus.data(named: "\(language)_gold")
        )
    }
}

enum LanguageParity {

    /// A count of agreements out of a total, with a few examples of what
    /// disagreed. Samples are capped because the first handful of divergences
    /// tell you what went wrong and the next four hundred do not.
    struct Report {
        var matched = 0
        var total = 0
        var samples: [String] = []

        mutating func record(_ agreed: Bool, _ describe: @autoclosure () -> String) {
            total += 1
            if agreed {
                matched += 1
            } else if samples.count < 12 {
                samples.append(describe())
            }
        }

        var isExact: Bool { matched == total }
        var summary: String { "\(matched)/\(total)" }
        var detail: String { samples.joined(separator: "\n") }
    }

    /// Tokens must agree on *text and offset together*. Comparing only the text
    /// would pass a tokenizer that produced the right pieces at the wrong
    /// places, and every offset this library reports would then be wrong.
    static func tokens(
        _ gold: LanguageGold, _ tokenizer: SpacyTokenizer
    ) -> (alignment: Report, norms: Report) {
        var alignment = Report()
        var norms = Report()
        for testCase in gold.cases {
            let got = tokenizer.tokenize(testCase.text)
            let want = testCase.tokens
            let gotKeys = got.map { "\($0.offset):\($0.text)" }
            let wantKeys = want.map { "\($0.offset):\($0.text)" }
            alignment.record(gotKeys == wantKeys, """
                \(testCase.text.prefix(70).debugDescription)
                  spacy \(wantKeys)
                  swift \(gotKeys)
                """)
            guard gotKeys == wantKeys else { continue }
            for (index, token) in got.enumerated() {
                norms.record(
                    token.norm == want[index].norm,
                    "\(token.text): spacy \(want[index].norm) swift \(token.norm)"
                )
            }
        }
        return (alignment, norms)
    }

    /// Per-token agreement for anything derived from the token sequence.
    ///
    /// Texts whose tokenization already diverges are skipped rather than
    /// counted as failures — they are the tokenizer suite's business, and
    /// counting them here would report the same bug twice while making the
    /// tagger look worse than it is.
    static func perToken(
        _ gold: LanguageGold,
        _ tokenizer: SpacyTokenizer,
        expected: (LanguageGold.Case.Token) -> String,
        produced: ([Token], String) -> [String]
    ) -> Report {
        var report = Report()
        for testCase in gold.cases {
            let tokens = tokenizer.tokenize(testCase.text)
            guard tokens.count == testCase.tokens.count else { continue }
            let got = produced(tokens, testCase.text)
            guard got.count == tokens.count else { continue }
            for (index, value) in got.enumerated() {
                let want = expected(testCase.tokens[index])
                report.record(value == want,
                              "\(tokens[index].text): spacy \(want) swift \(value)")
            }
        }
        return report
    }

    /// Entity spans, compared as sets of `start,end,label`.
    struct EntityReport {
        var matched = 0
        var expected = 0
        var produced = 0
        var samples: [String] = []

        var recall: Double { expected == 0 ? 0 : Double(matched) / Double(expected) }
        var precision: Double { produced == 0 ? 0 : Double(matched) / Double(produced) }
        var summary: String {
            "matched \(matched)/\(expected) recall \(recall) precision \(precision)"
        }
        var detail: String { samples.joined(separator: "\n") }
    }

    /// - Parameter withSentenceBoundaries: supply spaCy's sentence starts.
    ///
    ///   spaCy forbids entities from spanning a sentence boundary and gets
    ///   those boundaries from the parser, which this port does not implement.
    ///   Measuring both ways separates "we cannot see boundaries" from "we get
    ///   the wrong answer when we can".
    static func entities(
        _ gold: LanguageGold, _ ner: SpacyNER, withSentenceBoundaries: Bool = false
    ) -> EntityReport {
        var report = EntityReport()
        for testCase in gold.cases {
            let tokens = ner.tokenize(testCase.text)
            let starts = withSentenceBoundaries ? testCase.sentenceStarts : []
            let got = Set(ner.entities(
                in: testCase.text, tokens: tokens, sentenceStarts: starts
            ).map {
                "\($0.start),\($0.end),\($0.label)"
            })
            let want = Set(testCase.entities.map { "\($0.start),\($0.end),\($0.label)" })
            report.matched += got.intersection(want).count
            report.expected += want.count
            report.produced += got.count
            if got != want, report.samples.count < 10 {
                report.samples.append("""
                    \(testCase.text.prefix(70).debugDescription)
                      spacy \(want.sorted())
                      swift \(got.sorted())
                    """)
            }
        }
        return report
    }
}
