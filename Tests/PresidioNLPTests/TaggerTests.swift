import Testing
import Foundation
import PresidioConformance
@testable import PresidioNLP

/// The tagger, against spaCy's own output.
///
/// Needs the same model the gold corpus was built from — see `NERTests` for
/// why a different patch release is not a regression.
@Suite("spaCy tagger parity", .enabled(if: spacyModelDirectory() != nil))
struct TaggerTests {

    struct Gold: Decodable {
        struct Token: Decodable {
            let text: String
            let offset: Int
            let norm: String
            let tag: String
            let pos: String
            let lemma: String
        }
        struct Entry: Decodable {
            let text: String
            let tokens: [Token]
        }
        let texts: [Entry]
    }

    static let gold: Gold = {
        // swiftlint:disable:next force_try
        try! JSONDecoder().decode(Gold.self, from: Corpus.data(named: "tagger_gold"))
    }()

    @Test("fine-grained tags match spaCy")
    func tagsMatchSpacy() throws {
        let directory = spacyModelDirectory()!
        let tagger = try TaggerModel(directory: directory)
        let tokenizer = try SpacyTokenizer.english()

        var agreed = 0, total = 0, misaligned = 0
        var report: [String] = []

        for entry in Self.gold.texts {
            let tokens = tokenizer.tokenize(entry.text)
            guard tokens.count == entry.tokens.count else { misaligned += 1; continue }
            let predicted = tagger.tags(for: tokens, text: entry.text)
            for (index, want) in entry.tokens.enumerated() {
                total += 1
                if predicted[index] == want.tag {
                    agreed += 1
                } else if report.count < 12 {
                    report.append(
                        "\(want.text.debugDescription): spaCy \(want.tag), swift \(predicted[index])"
                    )
                }
            }
        }

        print("""
            Tagger parity: \(agreed)/\(total) tags, \(misaligned) texts misaligned
            \(report.joined(separator: "\n"))
            """)
        #expect(misaligned == 0, "tokenization diverged on \(misaligned) texts")
        #expect(total >= 5000)
        #expect(agreed == total, "\(report.joined(separator: "\n"))")
    }
}

/// The POS and lemma stages, against spaCy's own output.
@Suite("spaCy POS and lemma parity", .enabled(if: spacyModelDirectory() != nil))
struct RuleLemmatizerTests {

    @Test("the tables loaded")
    func tablesLoaded() {
        #expect(AttributeRuler.isLoaded)
        #expect(RuleLemmatizer.isLoaded)
        #expect(SpacySymbols.count == 457)
    }

    /// POS and lemmas, in both ruler configurations.
    ///
    /// Measured both ways on purpose. The claim that the parser-dependent rules
    /// change no lemma had been in the docs for a while as an argument; running
    /// the whole chain with and without dependency labels and comparing the
    /// lemmas turns it into a measurement, which is what lets the engine keep
    /// the cheaper path without hedging about it.
    @Test("POS and lemmas match spaCy")
    func posAndLemmasMatchSpacy() throws {
        let directory = spacyModelDirectory()!
        let tokenizer = try SpacyTokenizer.english()
        let withDeps = try SpacyLemmatizer(modelDirectory: directory)
        let withoutDeps = try SpacyLemmatizer(
            modelDirectory: directory, parseDependencies: false
        )
        #expect(withDeps.usesDependencies)
        #expect(!withoutDeps.usesDependencies)
        #expect(SpacyLemmatizer.parserDependentRuleCount == 13)

        var posAgreed = 0, posAgreedUnparsed = 0
        var lemmaAgreed = 0, lemmaMatchedAcrossConfigurations = 0
        var total = 0
        var posReport: [String] = []
        var lemmaReport: [String] = []

        for entry in TaggerTests.gold.texts {
            let tokens = tokenizer.tokenize(entry.text)
            guard tokens.count == entry.tokens.count else { continue }

            let pos = withDeps.partsOfSpeech(for: tokens, text: entry.text)
            let unparsedPOS = withoutDeps.partsOfSpeech(for: tokens, text: entry.text)
            let lemmas = withDeps.lemmas(for: tokens, text: entry.text)
            let unparsedLemmas = withoutDeps.lemmas(for: tokens, text: entry.text)

            for (index, want) in entry.tokens.enumerated() {
                total += 1
                if pos[index] == want.pos {
                    posAgreed += 1
                } else if posReport.count < 8 {
                    posReport.append(
                        "\(want.text.debugDescription) [\(want.tag)]: "
                        + "spaCy \(want.pos), swift \(pos[index])"
                    )
                }
                if unparsedPOS[index] == want.pos { posAgreedUnparsed += 1 }

                if lemmas[index] == want.lemma {
                    lemmaAgreed += 1
                } else if lemmaReport.count < 10 {
                    lemmaReport.append(
                        "\(want.text.debugDescription) [\(want.pos)]: "
                        + "spaCy \(want.lemma.debugDescription), "
                        + "swift \(lemmas[index].debugDescription)"
                    )
                }
                if lemmas[index] == unparsedLemmas[index] {
                    lemmaMatchedAcrossConfigurations += 1
                }
            }
        }

        print("""
            POS   parity: \(posAgreed)/\(total) with dependencies, \
            \(posAgreedUnparsed)/\(total) without
            Lemma parity: \(lemmaAgreed)/\(total), \
            \(lemmaMatchedAcrossConfigurations)/\(total) identical either way
            \(posReport.joined(separator: "\n"))
            --
            \(lemmaReport.joined(separator: "\n"))
            """)
        #expect(total >= 5000)
        #expect(lemmaAgreed == total, "lemma \(lemmaAgreed)/\(total)")

        // Exact now. This was 5,499/5,513 and documented as unreachable without
        // the dependency parser; with the parser ported, the 13 rules that test
        // DEP fire and the gap closes. They decide AUX vs VERB for "has"/"have",
        // DET vs PRON for "this", and ADP vs SCONJ for "as" — which is exactly
        // what the divergences used to be.
        #expect(posAgreed == total, "POS \(posAgreed)/\(total)\n\(posReport.joined(separator: "\n"))")

        // ...and the same measurement in reverse: without dependency labels the
        // ruler still behaves as spaCy-without-a-parser does, so the escape
        // hatch degrades to the documented number rather than to nonsense.
        #expect(
            posAgreedUnparsed == 5499,
            "unparsed POS moved to \(posAgreedUnparsed)/\(total), was 5499"
        )

        // The load-bearing one: no parser-dependent rule reaches a lemma, so a
        // caller who turns the parser off loses POS exactness and nothing else.
        #expect(
            lemmaMatchedAcrossConfigurations == total,
            "\(total - lemmaMatchedAcrossConfigurations) lemmas depend on the parse"
        )
    }
}
