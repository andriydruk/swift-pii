import Testing
import Foundation
@testable import PresidioNLP

/// Free function rather than a static: a `.enabled(if:)` condition referencing
/// the type it is attached to is a circular macro reference.
func germanModelDirectory() -> String? { modelDirectory("de") }

/// The German tokenizer, which needs no model weights at all.
///
/// Deliberately *not* gated on a model directory: tokenization is pure data, so
/// it must run everywhere the package builds. That matters more than it sounds
/// — the English NER suite was gated for months and therefore ran nowhere, and
/// gating what does not need gating is how that happens.
@Suite("spaCy German tokenizer parity")
struct GermanTokenizerTests {
    static let gold = LanguageGold.load("de")

    @Test("the German rules load and differ from the English ones")
    func rulesLoad() throws {
        let german = try SpacyTokenizer.german()
        let english = try SpacyTokenizer.english()
        #expect(german.spacyVersion.isEmpty == false)
        // Same shape, different data. If these ever became equal, the German
        // resource would have silently fallen back to English and every parity
        // number below would still look fine.
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
        let (alignment, norms) = LanguageParity.tokens(
            Self.gold, try SpacyTokenizer.german()
        )
        print("German tokenizer: \(norms.total) tokens over \(alignment.total) texts, "
              + "\(alignment.total - alignment.matched) misaligned, "
              + "\(norms.total - norms.matched) NORM divergences")
        #expect(alignment.isExact, "\(alignment.detail)")
        #expect(norms.isExact, "\(norms.detail)")
        #expect(norms.total >= 600, "corpus too small: \(norms.total) tokens")
    }
}

/// German NER: raw text in, character spans out, against spaCy's own output.
@Suite("spaCy German NER parity", .enabled(if: germanModelDirectory() != nil))
struct GermanNERTests {
    static let gold = LanguageGold.load("de")

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
        let report = LanguageParity.entities(Self.gold, try SpacyNER(
            modelDirectory: germanModelDirectory()!,
            tokenizer: try SpacyTokenizer.german()
        ))
        print("German NER parity: \(report.summary)")
        if !report.samples.isEmpty { print(report.detail) }
        #expect(report.expected >= 60, "corpus too small: \(report.expected) entities")
        // Ratchet, like the English suite. Tightened as the port improves;
        // never loosened without a written reason.
        #expect(report.recall >= 0.98, "recall \(report.recall), was 1.0")
        #expect(report.precision >= 0.98, "precision \(report.precision), was 0.985")
    }
}

/// The German tagger, which shares its architecture with the English one but
/// not its label set: 55 STTS tags against English's 50 Penn Treebank ones.
@Suite("spaCy German tagger parity", .enabled(if: germanModelDirectory() != nil))
struct GermanTaggerTests {
    static let gold = LanguageGold.load("de")

    @Test("fine-grained tags match spaCy")
    func tagsMatchSpacy() throws {
        let tagger = try TaggerModel(directory: germanModelDirectory()!)
        let report = LanguageParity.perToken(
            Self.gold, try SpacyTokenizer.german(),
            expected: \.tag,
            produced: { tagger.tags(for: $0, text: $1) }
        )
        print("German tagger: \(report.summary) tags")
        if !report.samples.isEmpty { print(report.detail) }
        #expect(report.total >= 600, "corpus too small: \(report.total)")
        #expect(report.isExact)
    }
}

/// German lemmas, which come from a neural edit-tree classifier rather than
/// from rules — a different component from English's, ported separately.
@Suite("spaCy German lemma parity", .enabled(if: germanModelDirectory() != nil))
struct GermanLemmaTests {
    static let gold = LanguageGold.load("de")

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
        let report = LanguageParity.perToken(
            Self.gold, try SpacyTokenizer.german(),
            expected: \.lemma,
            produced: { lemmatizer.lemmas(for: $0, text: $1) }
        )
        print("German lemmas: \(report.summary)")
        if !report.samples.isEmpty { print(report.detail) }
        #expect(report.total >= 600, "corpus too small: \(report.total)")
        #expect(report.isExact)
    }
}
