import Testing
import Foundation
@testable import PresidioNLP

func italianModelDirectory() -> String? { modelDirectory("it") }

/// Italian tokenization, whose distinguishing feature is elision.
///
/// `dell'ingegnere` is two tokens and the apostrophe stays with the first one;
/// `un'altra` likewise. Get that wrong and every offset in the sentence shifts,
/// which is why this runs unconditionally rather than behind a model gate.
@Suite("spaCy Italian tokenizer parity")
struct ItalianTokenizerTests {
    static let gold = LanguageGold.load("it")

    @Test("the Italian rules load and are not the English ones")
    func rulesLoad() throws {
        let italian = try SpacyTokenizer.italian()
        let english = try SpacyTokenizer.english()
        let text = "L'azienda dell'ingegnere è un'impresa nuova."
        #expect(italian.tokenize(text).map(\.text) != english.tokenize(text).map(\.text))
    }

    @Test("elision splits after the apostrophe")
    func elision() throws {
        let tokenizer = try SpacyTokenizer.italian()
        // Asserted directly, not only through the corpus: this is the single
        // rule most likely to regress, and a corpus failure would report it as
        // "some texts misaligned" rather than naming the cause.
        #expect(tokenizer.tokenize("dell'ingegnere").map(\.text) == ["dell'", "ingegnere"])
        #expect(tokenizer.tokenize("un'altra").map(\.text) == ["un'", "altra"])
    }

    @Test("tokens, offsets and NORMs match spaCy across the corpus")
    func matchesSpacy() throws {
        let (alignment, norms) = LanguageParity.tokens(
            Self.gold, try SpacyTokenizer.italian()
        )
        print("Italian tokenizer: \(norms.total) tokens over \(alignment.total) texts, "
              + "\(alignment.total - alignment.matched) misaligned, "
              + "\(norms.total - norms.matched) NORM divergences")
        #expect(alignment.isExact, "\(alignment.detail)")
        #expect(norms.isExact, "\(norms.detail)")
        #expect(norms.total >= 400, "corpus too small: \(norms.total) tokens")
    }
}

@Suite("spaCy Italian NER parity", .enabled(if: italianModelDirectory() != nil))
struct ItalianNERTests {
    static let gold = LanguageGold.load("it")

    @Test("entities match spaCy")
    func entitiesMatchSpacy() throws {
        let report = LanguageParity.entities(Self.gold, try SpacyNER(
            modelDirectory: italianModelDirectory()!,
            tokenizer: try SpacyTokenizer.italian()
        ))
        print("Italian NER parity: \(report.summary)")
        if !report.samples.isEmpty { print(report.detail) }
        #expect(report.expected >= 40, "corpus too small: \(report.expected) entities")
        #expect(report.recall == 1.0, "recall \(report.recall)\n\(report.detail)")
        #expect(report.precision == 1.0, "precision \(report.precision)\n\(report.detail)")
    }
}

/// Italian has a tagger — 48 labels — where Spanish has none.
@Suite("spaCy Italian tagger parity", .enabled(if: italianModelDirectory() != nil))
struct ItalianTaggerTests {
    static let gold = LanguageGold.load("it")

    @Test("fine-grained tags match spaCy")
    func tagsMatchSpacy() throws {
        let tagger = try TaggerModel(directory: italianModelDirectory()!)
        #expect(tagger.labels.count == 48, "\(tagger.labels.count)")
        let report = LanguageParity.perToken(
            Self.gold, try SpacyTokenizer.italian(),
            expected: \.tag,
            produced: { tagger.tags(for: $0, text: $1) }
        )
        print("Italian tagger: \(report.summary) tags")
        if !report.samples.isEmpty { print(report.detail) }
        #expect(report.total >= 400, "corpus too small: \(report.total)")
        #expect(report.isExact)
    }
}

/// Italian lemmas come from the same neural edit-tree classifier as German's,
/// so this suite is the evidence that the component ported rather than that one
/// model happened to work.
@Suite("spaCy Italian lemma parity", .enabled(if: italianModelDirectory() != nil))
struct ItalianLemmaTests {
    static let gold = LanguageGold.load("it")

    @Test("lemmas match spaCy")
    func lemmasMatchSpacy() throws {
        let lemmatizer = try EditTreeLemmatizer(directory: italianModelDirectory()!)
        let report = LanguageParity.perToken(
            Self.gold, try SpacyTokenizer.italian(),
            expected: \.lemma,
            produced: { lemmatizer.lemmas(for: $0, text: $1) }
        )
        print("Italian lemmas: \(report.summary)")
        if !report.samples.isEmpty { print(report.detail) }
        #expect(report.total >= 400, "corpus too small: \(report.total)")
        #expect(report.isExact)
    }
}
