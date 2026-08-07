import Testing
import Foundation
@testable import PresidioNLP

func russianModelDirectory() -> String? { modelDirectory("ru") }
func ukrainianModelDirectory() -> String? { modelDirectory("uk") }

/// Russian and Ukrainian tokenization.
///
/// The first non-Latin script here, which makes this suite a test of the
/// generated Unicode tables as much as of the rules: `\b`, `\w` and the
/// character classes in the prefix/suffix/infix patterns all have to behave the
/// same way on Cyrillic as Python's `regex` module does. Anything that quietly
/// fell back to an ASCII notion of a word character would show up as misaligned
/// tokens here and nowhere else.
@Suite("spaCy Cyrillic tokenizer parity")
struct CyrillicTokenizerTests {
    static let russian = LanguageGold.load("ru")
    static let ukrainian = LanguageGold.load("uk")

    @Test("Ukrainian keeps its letter-internal apostrophe")
    func ukrainianApostrophe() throws {
        let tokenizer = try SpacyTokenizer.ukrainian()
        // The case most likely to be wrong: in Ukrainian the apostrophe sits
        // *inside* a word, where Italian and English rules would split on it.
        // Asserted directly, because through the corpus this would surface as
        // "some texts misaligned" without naming the cause.
        #expect(tokenizer.tokenize("п'ять").map(\.text) == ["п'ять"])
        #expect(tokenizer.tokenize("об'єкт").map(\.text) == ["об'єкт"])
        // The apostrophe binds, the hyphen still splits — checked against
        // spaCy rather than assumed. My first version of this expectation had
        // the whole compound as one token, which was wrong about spaCy, not
        // about us.
        #expect(tokenizer.tokenize("прем'єр-міністр").map(\.text)
                == ["прем'єр", "-", "міністр"])
    }

    @Test("Cyrillic words are single tokens, not split per character")
    func cyrillicIsWordy() throws {
        // Guards the failure mode a wrong `\w` produces: every letter its own
        // token. Cheap, and it fails loudly rather than as a parity percentage.
        for (language, word) in [("ru", "Здравствуйте"), ("uk", "Привіт")] {
            let tokenizer = try SpacyTokenizer.forLanguage(language)
            #expect(tokenizer.tokenize(word).map(\.text) == [word], "\(language)")
        }
    }

    @Test("Russian tokens, offsets and NORMs match spaCy")
    func russianMatchesSpacy() throws {
        let (alignment, norms) = LanguageParity.tokens(
            Self.russian, try SpacyTokenizer.russian()
        )
        print("Russian tokenizer: \(norms.total) tokens over \(alignment.total) texts, "
              + "\(alignment.total - alignment.matched) misaligned, "
              + "\(norms.total - norms.matched) NORM divergences")
        #expect(alignment.isExact, "\(alignment.detail)")
        #expect(norms.isExact, "\(norms.detail)")
        #expect(norms.total >= 450, "corpus too small: \(norms.total) tokens")
    }

    @Test("Ukrainian tokens, offsets and NORMs match spaCy")
    func ukrainianMatchesSpacy() throws {
        let (alignment, norms) = LanguageParity.tokens(
            Self.ukrainian, try SpacyTokenizer.ukrainian()
        )
        print("Ukrainian tokenizer: \(norms.total) tokens over \(alignment.total) texts, "
              + "\(alignment.total - alignment.matched) misaligned, "
              + "\(norms.total - norms.matched) NORM divergences")
        #expect(alignment.isExact, "\(alignment.detail)")
        #expect(norms.isExact, "\(norms.detail)")
        #expect(norms.total >= 300, "corpus too small: \(norms.total) tokens")
    }
}

@Suite("spaCy Russian NER parity", .enabled(if: russianModelDirectory() != nil))
struct RussianNERTests {
    static let gold = LanguageGold.load("ru")

    @Test("entities match spaCy")
    func entitiesMatchSpacy() throws {
        let report = LanguageParity.entities(Self.gold, try SpacyNER(
            modelDirectory: russianModelDirectory()!,
            tokenizer: try SpacyTokenizer.russian()
        ))
        print("Russian NER parity: \(report.summary)")
        if !report.samples.isEmpty { print(report.detail) }
        #expect(report.expected >= 35, "corpus too small: \(report.expected) entities")
        #expect(report.recall >= 0.95, "recall \(report.recall)")
        #expect(report.precision >= 0.95, "precision \(report.precision)")
    }
}

@Suite("spaCy Ukrainian NER parity", .enabled(if: ukrainianModelDirectory() != nil))
struct UkrainianNERTests {
    static let gold = LanguageGold.load("uk")

    @Test("entities match spaCy")
    func entitiesMatchSpacy() throws {
        let report = LanguageParity.entities(Self.gold, try SpacyNER(
            modelDirectory: ukrainianModelDirectory()!,
            tokenizer: try SpacyTokenizer.ukrainian()
        ))
        print("Ukrainian NER parity: \(report.summary)")
        if !report.samples.isEmpty { print(report.detail) }
        #expect(report.expected >= 20, "corpus too small: \(report.expected) entities")
        #expect(report.recall >= 0.95, "recall \(report.recall)")
        #expect(report.precision >= 0.95, "precision \(report.precision)")
    }
}

/// What Russian and Ukrainian do *not* have, asserted rather than footnoted.
///
/// Both pipelines are tok2vec → morphologizer → parser → attribute_ruler →
/// lemmatizer → ner. So, as with Spanish, there is **no tagger**; and their
/// lemmatizers run in `pymorphy3` mode — a full morphological analyser backed by
/// a compiled dictionary (OpenCorpora for Russian, a separate one for
/// Ukrainian), not a table this port could bundle. Porting it is a project in
/// itself, and heavily inflected languages are exactly where that gap costs the
/// most for context scoring.
///
/// Entity spans and identifier patterns are unaffected.
@Suite("Cyrillic pipeline gaps")
struct CyrillicGapTests {

    @Test("neither model has a tagger component",
          arguments: [("ru", russianModelDirectory()), ("uk", ukrainianModelDirectory())])
    func noTagger(language: String, directory: String?) throws {
        guard let directory else { return }
        #expect(throws: TaggerModel.LoadError.self) {
            _ = try TaggerModel(directory: directory)
        }
    }

    @Test("neither model has an edit-tree lemmatizer",
          arguments: [("ru", russianModelDirectory()), ("uk", ukrainianModelDirectory())])
    func noEditTrees(language: String, directory: String?) throws {
        guard let directory else { return }
        #expect(throws: (any Error).self) {
            _ = try EditTreeLemmatizer(directory: directory)
        }
    }
}

/// The lexical features the model consumes, over combining marks.
///
/// spaCy computes `prefix_`, `suffix_` and `shape_` over **codepoints**; this
/// port originally computed them over Swift `Character`s, which are grapheme
/// clusters. The two agree on ASCII and diverge the moment a combining mark
/// appears — so the bug was invisible for four languages and then produced
/// thirteen spurious Russian entities on spaCy's own stress-mark tests.
///
/// Asserted against values taken from spaCy directly, not derived from the
/// implementation, because that is the only version of this test that could
/// have failed before the fix.
@Suite("lexical features over combining marks")
struct CombiningMarkFeatureTests {

    @Test("shape, prefix and suffix count codepoints, not grapheme clusters")
    func codepointSemantics() {
        // рекоменду́я: acute U+0301 after "у". Eleven codepoints, ten clusters.
        #expect(wordShape("рекоменду́я") == "xxxx\u{0301}x")
        #expect(lexSuffix("рекоменду́я") == "у\u{0301}я")
        #expect(lexPrefix("рекоменду́я") == "р")

        // жару̍: U+030D. Five codepoints, four clusters.
        #expect(wordShape("жару̍") == "xxxx\u{030D}")
        #expect(lexSuffix("жару̍") == "ру\u{030D}")

        // No combining marks: unchanged, and the reason English never noticed.
        #expect(wordShape("Баргамота") == "Xxxxx")
        #expect(lexSuffix("Баргамота") == "ота")
        #expect(wordShape("café") == "xxxx")
        #expect(lexSuffix("café") == "afé")
    }

    @Test("a combining mark is not a letter")
    func combiningMarksAreNotLetters() {
        // Swift's `properties.isAlphabetic` says true for Other_Alphabetic
        // marks; Python's `str.isalpha()` says false. The shape depends on
        // taking Python's side.
        #expect(!pyIsAlpha("\u{0301}"))
        #expect(pyIsAlpha("я"))
        #expect(pyIsUpper("Б"))
        #expect(!pyIsUpper("б"))
        #expect(pyIsDigit("7"))
        #expect(pyIsDigit("²"), "Python's isdigit() accepts superscripts")
        #expect(!pyIsDigit("½"), "...but not vulgar fractions")
    }
}
