import Testing
import Foundation
import PresidioConformance
@testable import PresidioNLP

/// The dependency parser, against spaCy's own output over the NER corpus.
///
/// Three things are measured, and the order matters when something breaks.
/// Sentence starts are what NER consumes, so that is the number that decides
/// whether this component did its job. But a boundary is derived from the heads,
/// and a head from a sequence of transitions, so heads and labels are measured
/// too — a boundary divergence with exact heads means the edge computation is
/// wrong, and one with divergent heads means it never got that far.
///
/// Same 2,000 texts as `NERTests`, so a regression here and a regression there
/// are attributable to each other.
@Suite("spaCy parser parity", .enabled(if: spacyModelDirectory() != nil))
struct ParserTests {

    struct Gold: Decodable {
        struct Case: Decodable {
            let text: String
            let heads: [Int]
            let deps: [String]
            let sentStarts: [Int]

            enum CodingKeys: String, CodingKey {
                case text, heads, deps
                case sentStarts = "sent_starts"
            }
        }
        let model: String
        let cases: [Case]
    }

    static let gold: Gold = {
        // swiftlint:disable:next force_try
        try! JSONDecoder().decode(Gold.self, from: Corpus.data(named: "parser_gold_sm"))
    }()

    @Test("the parser loads with its full transition table")
    func parserLoads() throws {
        let parser = try DependencyParser(directory: spacyModelDirectory()!)
        // 106 for English sm. Asserting the count rather than the number keeps
        // this meaningful for a model with different labels.
        #expect(parser.actionCount > 100)
    }

    @Test("a model without a parser is reported, not crashed on")
    func missingParser() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-parser-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(throws: ComponentLoadError.self) {
            _ = try DependencyParser(directory: empty.path)
        }
    }

    /// The concrete case the parser exists for.
    ///
    /// One of the four texts in the corpus that `exclude=["parser"]` changes.
    /// Without boundaries the ORG span opens on `KR_PASSPORT` and runs through
    /// the table cell into the next sentence, swallowing an identifier; with
    /// them it starts where spaCy starts it. Asserted as a span rather than as
    /// a boundary index because the span is what leaks.
    @Test("an entity stops at a sentence boundary")
    func entityStopsAtBoundary() throws {
        let text = "| | KR_PASSPORT| The Korean Passport Number | Pattern match, context."

        let ner = try SpacyNER(modelDirectory: spacyModelDirectory()!)
        #expect(ner.parsesSentences)
        #expect(
            ner.entities(in: text).map { "\($0.start),\($0.end),\($0.label)" }
                == ["17,43,ORG"]
        )

        // Opting out has to actually opt out, or the throughput escape hatch is
        // a lie and the `.none` boundary mode measures the wrong thing.
        let unparsed = try SpacyNER(
            modelDirectory: spacyModelDirectory()!, parseSentences: false
        )
        #expect(!unparsed.parsesSentences)
        #expect(unparsed.parse(text) == nil)
        #expect(
            unparsed.entities(in: text).map { "\($0.start),\($0.end),\($0.label)" }
                == ["4,43,ORG"]
        )
    }

    @Test("heads, labels and sentence starts match spaCy")
    func parseMatchesSpacy() throws {
        let directory = spacyModelDirectory()!
        let parser = try DependencyParser(directory: directory)
        let tokenizer = try SpacyTokenizer.english()

        var headsAgreed = 0, depsAgreed = 0, tokens = 0
        var startsAgreed = 0, startsExpected = 0, startsProduced = 0
        var misaligned = 0
        var report: [String] = []

        for testCase in Self.gold.cases {
            let got = parser.parse(
                tokens: tokenizer.tokenize(testCase.text), text: testCase.text
            )
            guard got.heads.count == testCase.heads.count else {
                misaligned += 1
                continue
            }
            tokens += got.heads.count
            for i in 0..<got.heads.count {
                if got.heads[i] == testCase.heads[i] { headsAgreed += 1 }
                if got.deps[i] == testCase.deps[i] { depsAgreed += 1 }
            }
            let want = Set(testCase.sentStarts)
            startsExpected += want.count
            startsProduced += got.sentenceStarts.count
            startsAgreed += got.sentenceStarts.intersection(want).count

            if got.sentenceStarts != want, report.count < 10 {
                report.append("""
                    \(testCase.text.prefix(90).debugDescription)
                      spacy \(want.sorted())
                      swift \(got.sentenceStarts.sorted())
                    """)
            }
        }

        print("""
            Parser parity: heads \(headsAgreed)/\(tokens) \
            deps \(depsAgreed)/\(tokens) \
            sentence starts \(startsAgreed)/\(startsExpected) \
            (produced \(startsProduced)), \(misaligned) texts misaligned
            """)

        #expect(misaligned == 0, "tokenization diverged on \(misaligned) texts")
        #expect(tokens > 45000, "corpus too small: \(tokens) tokens")
        #expect(
            headsAgreed == tokens,
            """
            heads diverged on \(tokens - headsAgreed) of \(tokens)
            \(report.joined(separator: "\n"))
            """
        )
        #expect(depsAgreed == tokens, "labels diverged on \(tokens - depsAgreed)")
        #expect(
            startsAgreed == startsExpected && startsProduced == startsExpected,
            """
            sentence starts diverged: \(startsAgreed)/\(startsExpected) matched, \
            \(startsProduced) produced
            \(report.joined(separator: "\n"))
            """
        )
    }
}

/// The parser in the other seven languages.
///
/// Their corpora already record `sent_start` per token, so no new gold was
/// needed — the boundaries spaCy's parser produced were captured when the
/// divergence was first attributed to them, which is what makes this
/// measurable now.
///
/// One suite rather than seven, gated on *all* the models being present. A
/// per-language gate would skip quietly for whichever model was missing, and a
/// skipped suite that prints nothing is indistinguishable from a passing one —
/// the failure mode that let the English NER suite run nowhere for months. CI
/// greps for the per-language measurement lines below.
/// File scope, not a static on the suite: a `.enabled(if:)` condition that
/// mentions the type it is attached to is a circular macro reference. Same trap
/// `spacyModelDirectory()` is written this way to avoid.
let parsedLanguages = ["de", "es", "fr", "it", "pt", "ru", "uk"]

@Suite(
    "parser sentence boundaries across languages",
    .enabled(if: parsedLanguages.allSatisfy { modelDirectory($0) != nil })
)
struct MultilingualParserTests {

    @Test("sentence boundaries match spaCy in every language")
    func boundariesMatchSpacy() throws {
        for language in parsedLanguages {
            let ner = try SpacyNER(
                modelDirectory: modelDirectory(language)!,
                tokenizer: try SpacyTokenizer.forLanguage(language)
            )
            let report = LanguageParity.sentenceStarts(
                LanguageGold.load(language), ner
            )
            print("\(language) sentence boundaries: \(report.summary)")
            #expect(report.total > 300, "\(language) corpus too small: \(report.total)")
            #expect(report.isExact, "\(language) boundaries diverged\n\(report.detail)")
        }
    }
}
