import Testing
import Foundation
@testable import PresidioNLP

func spanishModelDirectory() -> String? { modelDirectory("es") }

/// Spanish tokenization. Inverted punctuation is the thing English rules get
/// wrong: `¿` and `¡` open a clause and must split off the word that follows.
@Suite("spaCy Spanish tokenizer parity")
struct SpanishTokenizerTests {
    static let gold = LanguageGold.load("es")

    @Test("the Spanish rules load and are not the English ones")
    func rulesLoad() throws {
        let spanish = try SpacyTokenizer.spanish()
        let english = try SpacyTokenizer.english()
        let text = "Esto se aplica p.ej. a los contratos."
        #expect(spanish.tokenize(text).map(\.text) != english.tokenize(text).map(\.text))
    }

    @Test("inverted punctuation splits off")
    func invertedPunctuation() throws {
        let tokenizer = try SpacyTokenizer.spanish()
        #expect(tokenizer.tokenize("¿Quién?").map(\.text) == ["¿", "Quién", "?"])
        #expect(tokenizer.tokenize("¡No!").map(\.text) == ["¡", "No", "!"])
    }

    @Test("tokens, offsets and NORMs match spaCy across the corpus")
    func matchesSpacy() throws {
        let (alignment, norms) = LanguageParity.tokens(
            Self.gold, try SpacyTokenizer.spanish()
        )
        print("Spanish tokenizer: \(norms.total) tokens over \(alignment.total) texts, "
              + "\(alignment.total - alignment.matched) misaligned, "
              + "\(norms.total - norms.matched) NORM divergences")
        #expect(alignment.isExact, "\(alignment.detail)")
        #expect(norms.isExact, "\(norms.detail)")
        #expect(norms.total >= 500, "corpus too small: \(norms.total) tokens")
    }
}

@Suite("spaCy Spanish NER parity", .enabled(if: spanishModelDirectory() != nil))
struct SpanishNERTests {
    static let gold = LanguageGold.load("es")

    @Test("entities match spaCy")
    func entitiesMatchSpacy() throws {
        let report = LanguageParity.entities(Self.gold, try SpacyNER(
            modelDirectory: spanishModelDirectory()!,
            tokenizer: try SpacyTokenizer.spanish()
        ))
        print("Spanish NER parity: \(report.summary)")
        if !report.samples.isEmpty { print(report.detail) }
        #expect(report.expected >= 60, "corpus too small: \(report.expected) entities")
        #expect(report.recall == 1.0, "recall \(report.recall)\n\(report.detail)")
        #expect(report.precision == 1.0, "precision \(report.precision)\n\(report.detail)")
    }
}

/// What Spanish does *not* have, asserted rather than left as a footnote.
///
/// Two gaps, both structural rather than unfinished work:
///
/// - **No tagger.** `es_core_news_sm`'s pipeline is tok2vec → morphologizer →
///   parser → attribute_ruler → lemmatizer → ner. POS comes from the
///   morphologizer, a component this port does not read yet.
/// - **A bespoke lemmatizer.** Spanish uses `SpanishLemmatizer`, 428 lines of
///   hand-written Python with a method per part of speech, not the table-driven
///   rule lemmatizer English uses nor the edit trees German and Italian use.
///
/// Neither blocks PII detection: entity spans and identifier patterns are
/// unaffected. What degrades is context scoring, which matches supporting words
/// by lemma. These tests exist so the gap fails loudly if someone later assumes
/// it closed.
@Suite("Spanish pipeline gaps", .enabled(if: spanishModelDirectory() != nil))
struct SpanishGapTests {

    @Test("the model genuinely has no tagger component")
    func noTagger() {
        #expect(throws: TaggerModel.LoadError.self) {
            _ = try TaggerModel(directory: spanishModelDirectory()!)
        }
    }

    @Test("the model genuinely has no edit-tree lemmatizer")
    func noEditTrees() {
        // Spanish ships `lemmatizer/lookups.bin` for the rule tables, not the
        // `trees` a trainable lemmatizer serializes. Loading must fail rather
        // than silently produce lemmas from an empty tree store.
        #expect(throws: (any Error).self) {
            _ = try EditTreeLemmatizer(directory: spanishModelDirectory()!)
        }
    }
}
