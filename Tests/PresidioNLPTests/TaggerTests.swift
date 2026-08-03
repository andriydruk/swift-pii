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

    @Test("POS and lemmas match spaCy")
    func posAndLemmasMatchSpacy() throws {
        let directory = spacyModelDirectory()!
        let tagger = try TaggerModel(directory: directory)
        let tokenizer = try SpacyTokenizer.english()
        let lemmatizer = RuleLemmatizer()

        var posAgreed = 0, lemmaAgreed = 0, total = 0
        var posReport: [String] = []
        var lemmaReport: [String] = []

        for entry in TaggerTests.gold.texts {
            let tokens = tokenizer.tokenize(entry.text)
            guard tokens.count == entry.tokens.count else { continue }
            let tags = tagger.tags(for: tokens, text: entry.text)

            for (index, want) in entry.tokens.enumerated() {
                total += 1
                let lowered = tokens[index].text.lowercased()
                let attributes = AttributeRuler.attributes(
                    tag: tags[index], lowercased: lowered
                )
                if attributes.pos == want.pos {
                    posAgreed += 1
                } else if posReport.count < 8 {
                    posReport.append(
                        "\(want.text.debugDescription) [\(want.tag)]: "
                        + "spaCy \(want.pos), swift \(attributes.pos)"
                    )
                }

                let lemma = attributes.lemma ?? lemmatizer.lemma(
                    text: tokens[index].text,
                    pos: attributes.pos,
                    morph: attributes.morph
                )
                if lemma == want.lemma {
                    lemmaAgreed += 1
                } else if lemmaReport.count < 10 {
                    lemmaReport.append(
                        "\(want.text.debugDescription) [\(want.pos)]: "
                        + "spaCy \(want.lemma.debugDescription), "
                        + "swift \(lemma.debugDescription)"
                    )
                }
            }
        }

        print("""
            POS   parity: \(posAgreed)/\(total)
            Lemma parity: \(lemmaAgreed)/\(total)
            \(posReport.joined(separator: "\n"))
            --
            \(lemmaReport.joined(separator: "\n"))
            """)
        #expect(total >= 5000)
        // Lemmas are **exact**, which is the point of the whole chain.
        #expect(lemmaAgreed == total, "lemma \(lemmaAgreed)/\(total)")
        // POS is not, and cannot be: 22 attribute-ruler rules need the
        // dependency parser this port does not have. Every divergence is one
        // of them — AUX vs VERB for "has"/"have", DET vs PRON for "this",
        // ADP vs SCONJ for "as" — and none of them changes a lemma, because
        // the ruler assigns those lemmas directly and DET/PRON have no lemma
        // tables to differ over.
        #expect(posAgreed >= 5499, "POS \(posAgreed)/\(total)")
    }
}
