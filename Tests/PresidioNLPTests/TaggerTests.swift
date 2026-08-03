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
