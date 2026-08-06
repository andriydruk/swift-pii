import Testing
import Foundation
import PresidioConformance
@testable import PresidioNLP

/// Where to find an unpacked `de_core_news_sm`.
///
/// Free function rather than a static, for the same reason as the English one:
/// a `.enabled(if:)` condition referencing the type it is attached to is a
/// circular macro reference.
///
/// It must be **3.7.0**, the version `de_gold.json` was built from. A different
/// patch release has different weights, and the resulting mismatch reads as a
/// catastrophic regression when it is only a version skew.
func germanModelDirectory() -> String? {
    ProcessInfo.processInfo.environment["SPACY_DE_MODEL_DIR"]
}

struct GermanGold: Decodable {
    struct Case: Decodable {
        struct Token: Decodable {
            let text: String
            let offset: Int
            let norm: String
            let tag: String
            let pos: String
            let lemma: String
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
    }
    let model: String
    let spacyVersion: String
    let cases: [Case]

    enum CodingKeys: String, CodingKey {
        case model
        case spacyVersion = "spacy_version"
        case cases
    }

    static let shared: GermanGold = {
        // swiftlint:disable:next force_try
        try! JSONDecoder().decode(GermanGold.self, from: Corpus.data(named: "de_gold"))
    }()
}

/// The German tokenizer, which needs no model weights at all.
///
/// This suite is deliberately not gated on a model directory: tokenization is
/// pure data, so it must run everywhere the package builds. That matters more
/// than it sounds — the English NER suite was gated for months and therefore
/// ran nowhere, and gating what does not need gating is how that happens.
@Suite("spaCy German tokenizer parity")
struct GermanTokenizerTests {

    @Test("the German rules load and differ from the English ones")
    func rulesLoad() throws {
        let german = try SpacyTokenizer.german()
        let english = try SpacyTokenizer.english()
        #expect(german.spacyVersion.isEmpty == false)
        // Same shape, different data. If these ever became equal, the German
        // resource would have silently fallen back to English and every
        // parity number below would still look fine.
        #expect(german.tokenize("Das gilt z.B. für Verträge.").map(\.text)
                != english.tokenize("Das gilt z.B. für Verträge.").map(\.text))
    }

    @Test("an unbundled language is refused rather than guessed at")
    func unsupportedLanguage() {
        #expect(throws: SpacyTokenizer.LoadError.self) {
            _ = try SpacyTokenizer.forLanguage("ja")
        }
    }

    @Test("tokens, offsets and NORMs match spaCy across the corpus")
    func matchesSpacy() throws {
        let tokenizer = try SpacyTokenizer.german()
        var tokensChecked = 0
        var textMismatches: [String] = []
        var normMismatches: [String] = []

        for testCase in GermanGold.shared.cases {
            let got = tokenizer.tokenize(testCase.text)
            let want = testCase.tokens

            let gotTexts = got.map { "\($0.offset):\($0.text)" }
            let wantTexts = want.map { "\($0.offset):\($0.text)" }
            if gotTexts != wantTexts {
                if textMismatches.count < 8 {
                    textMismatches.append("""
                        \(testCase.text.prefix(70).debugDescription)
                          spacy \(wantTexts)
                          swift \(gotTexts)
                        """)
                }
                continue
            }
            tokensChecked += want.count
            for (index, token) in got.enumerated() where token.norm != want[index].norm {
                if normMismatches.count < 8 {
                    normMismatches.append(
                        "\(token.text): spacy \(want[index].norm) swift \(token.norm)"
                    )
                }
            }
        }

        print("German tokenizer: \(tokensChecked) tokens over "
              + "\(GermanGold.shared.cases.count) texts, "
              + "\(textMismatches.count) misaligned, "
              + "\(normMismatches.count) NORM divergences")

        #expect(textMismatches.isEmpty, "\(textMismatches.joined(separator: "\n"))")
        #expect(normMismatches.isEmpty, "\(normMismatches.joined(separator: "\n"))")
        #expect(tokensChecked >= 600, "corpus too small: \(tokensChecked) tokens")
    }
}

/// German NER, on the same terms as the English suite: raw text in, character
/// spans out, compared against spaCy's own output.
@Suite("spaCy German NER parity", .enabled(if: germanModelDirectory() != nil))
struct GermanNERTests {

    @Test("the German model loads")
    func modelLoads() throws {
        let ner = try SpacyNER(
            modelDirectory: germanModelDirectory()!,
            tokenizer: try SpacyTokenizer.german()
        )
        // 18 transition actions over 4 entity labels, against English's 74 over
        // 18. That difference is what used to crash the loader.
        #expect(ner.actionCount == 18, "\(ner.actionCount)")
    }

    @Test("entities match spaCy")
    func entitiesMatchSpacy() throws {
        let ner = try SpacyNER(
            modelDirectory: germanModelDirectory()!,
            tokenizer: try SpacyTokenizer.german()
        )
        var matched = 0, expected = 0, produced = 0
        var report: [String] = []

        for testCase in GermanGold.shared.cases {
            let got = Set(ner.entities(in: testCase.text).map {
                "\($0.start),\($0.end),\($0.label)"
            })
            let want = Set(testCase.entities.map { "\($0.start),\($0.end),\($0.label)" })
            matched += got.intersection(want).count
            expected += want.count
            produced += got.count
            if got != want, report.count < 10 {
                report.append("""
                    \(testCase.text.prefix(70).debugDescription)
                      spacy \(want.sorted())
                      swift \(got.sorted())
                    """)
            }
        }

        let recall = Double(matched) / Double(expected)
        let precision = Double(matched) / Double(produced)
        print("German NER parity: matched \(matched)/\(expected) "
              + "recall \(recall) precision \(precision)")
        if !report.isEmpty { print(report.joined(separator: "\n")) }

        #expect(expected >= 60, "corpus too small: \(expected) entities")
        // Ratchet, like the English suite. Tightened as the port improves;
        // never loosened without a written reason.
        #expect(recall >= 0.98, "recall \(recall), was 1.0")
        #expect(precision >= 0.98, "precision \(precision), was 1.0")
    }
}

/// The German tagger, which shares its architecture with the English one but
/// not its label set: 52 STTS tags against English's 50 Penn Treebank ones.
@Suite("spaCy German tagger parity", .enabled(if: germanModelDirectory() != nil))
struct GermanTaggerTests {

    @Test("fine-grained tags match spaCy")
    func tagsMatchSpacy() throws {
        let tagger = try TaggerModel(directory: germanModelDirectory()!)
        let tokenizer = try SpacyTokenizer.german()
        var matched = 0, total = 0
        var report: [String] = []

        for testCase in GermanGold.shared.cases {
            let tokens = tokenizer.tokenize(testCase.text)
            guard tokens.count == testCase.tokens.count else { continue }
            let got = tagger.tags(for: tokens, text: testCase.text)
            for (index, tag) in got.enumerated() {
                total += 1
                if tag == testCase.tokens[index].tag {
                    matched += 1
                } else if report.count < 10 {
                    report.append("\(tokens[index].text): spacy "
                                  + "\(testCase.tokens[index].tag) swift \(tag)")
                }
            }
        }

        print("German tagger: \(matched)/\(total) tags")
        if !report.isEmpty { print(report.joined(separator: "\n")) }
        #expect(total >= 600, "corpus too small: \(total)")
        #expect(matched == total)
    }
}

/// German lemmas, which come from a neural edit-tree classifier rather than
/// from rules — a different component from English's, ported separately.
@Suite("spaCy German lemma parity", .enabled(if: germanModelDirectory() != nil))
struct GermanLemmaTests {

    @Test("the edit trees load")
    func treesLoad() throws {
        let lemmatizer = try EditTreeLemmatizer(directory: germanModelDirectory()!)
        #expect(lemmatizer.labelCount == 1311)
        #expect(lemmatizer.treeCount > lemmatizer.labelCount,
                "the tree store includes subtrees that are never predicted directly")
    }

    @Test("lemmas match spaCy")
    func lemmasMatchSpacy() throws {
        let lemmatizer = try EditTreeLemmatizer(directory: germanModelDirectory()!)
        let tokenizer = try SpacyTokenizer.german()
        var matched = 0, total = 0
        var report: [String] = []

        for testCase in GermanGold.shared.cases {
            let tokens = tokenizer.tokenize(testCase.text)
            guard tokens.count == testCase.tokens.count else { continue }
            let got = lemmatizer.lemmas(for: tokens, text: testCase.text)
            for (index, lemma) in got.enumerated() {
                total += 1
                if lemma == testCase.tokens[index].lemma {
                    matched += 1
                } else if report.count < 12 {
                    report.append("\(tokens[index].text): spacy "
                                  + "\(testCase.tokens[index].lemma) swift \(lemma)")
                }
            }
        }

        print("German lemmas: \(matched)/\(total)")
        if !report.isEmpty { print(report.joined(separator: "\n")) }
        #expect(total >= 600, "corpus too small: \(total)")
        #expect(matched == total)
    }
}
