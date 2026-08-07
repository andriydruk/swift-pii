import Testing
import Foundation
@testable import PresidioNLP

func frenchModelDirectory() -> String? { modelDirectory("fr") }
func portugueseModelDirectory() -> String? { modelDirectory("pt") }

/// French tokenization, whose distinguishing case is elision — more aggressive
/// than Italian's, because French elides pronouns and conjunctions too.
@Suite("spaCy French tokenizer parity")
struct FrenchTokenizerTests {
    static let gold = LanguageGold.load("fr")

    @Test("elision splits after the apostrophe, and inversion hyphens do not")
    func elisionAndInversion() throws {
        let tokenizer = try SpacyTokenizer.french()
        #expect(tokenizer.tokenize("l'entreprise").map(\.text) == ["l'", "entreprise"])
        #expect(tokenizer.tokenize("qu'il").map(\.text) == ["qu'", "il"])
        #expect(tokenizer.tokenize("aujourd'hui").map(\.text) == ["aujourd'hui"],
                "a fixed expression, not an elision")
    }

    @Test("tokens, offsets and NORMs match spaCy across the corpus")
    func matchesSpacy() throws {
        let (alignment, norms) = LanguageParity.tokens(
            Self.gold, try SpacyTokenizer.french()
        )
        print("French tokenizer: \(norms.total) tokens over \(alignment.total) texts, "
              + "\(alignment.total - alignment.matched) misaligned, "
              + "\(norms.total - norms.matched) NORM divergences")
        #expect(alignment.isExact, "\(alignment.detail)")
        #expect(norms.isExact, "\(norms.detail)")
        #expect(norms.total >= 550, "corpus too small: \(norms.total) tokens")
    }
}

/// Portuguese tokenization: clitic hyphens, `diga-me` and `dar-lhe-ei`.
@Suite("spaCy Portuguese tokenizer parity")
struct PortugueseTokenizerTests {
    static let gold = LanguageGold.load("pt")

    @Test("tokens, offsets and NORMs match spaCy across the corpus")
    func matchesSpacy() throws {
        let (alignment, norms) = LanguageParity.tokens(
            Self.gold, try SpacyTokenizer.portuguese()
        )
        print("Portuguese tokenizer: \(norms.total) tokens over \(alignment.total) texts, "
              + "\(alignment.total - alignment.matched) misaligned, "
              + "\(norms.total - norms.matched) NORM divergences")
        #expect(alignment.isExact, "\(alignment.detail)")
        #expect(norms.isExact, "\(norms.detail)")
        #expect(norms.total >= 320, "corpus too small: \(norms.total) tokens")
    }
}

@Suite("spaCy French NER parity", .enabled(if: frenchModelDirectory() != nil))
struct FrenchNERTests {
    static let gold = LanguageGold.load("fr")

    @Test("entities match spaCy")
    func entitiesMatchSpacy() throws {
        let report = LanguageParity.entities(Self.gold, try SpacyNER(
            modelDirectory: frenchModelDirectory()!,
            tokenizer: try SpacyTokenizer.french()
        ))
        print("French NER parity: \(report.summary)")
        if !report.samples.isEmpty { print(report.detail) }
        #expect(report.expected >= 35, "corpus too small: \(report.expected) entities")

        // French is the first language here that is **not** exact: 40/42
        // recall, 0.930 precision, three divergences. What that is not:
        //
        // - not tokenization — 624/624 tokens, offsets and NORMs match;
        // - not the lexical features — NORM, prefix, suffix and shape were
        //   compared token by token against spaCy for the failing sentence and
        //   agree on all eleven;
        // - not accumulation order — the Accelerate and portable kernels
        //   produce the identical 40/42, as they do for English's residual 4.
        //
        // So it is the forward pass, and the divergences look like it: an extra
        // PER over "Pierre-Yves Le Gall", and two MISC spans with the right
        // start and a longer extent. Plausible spans, wrong boundary — never
        // corrupted offsets.
        //
        // Ratchet at the measured value. Tighten when it improves; never loosen
        // without writing down why.
        #expect(report.recall >= 0.95, "recall \(report.recall), was 0.952")
        #expect(report.precision >= 0.93, "precision \(report.precision), was 0.930")
    }
}

@Suite("spaCy Portuguese NER parity", .enabled(if: portugueseModelDirectory() != nil))
struct PortugueseNERTests {
    static let gold = LanguageGold.load("pt")

    @Test("entities match spaCy")
    func entitiesMatchSpacy() throws {
        let report = LanguageParity.entities(Self.gold, try SpacyNER(
            modelDirectory: portugueseModelDirectory()!,
            tokenizer: try SpacyTokenizer.portuguese()
        ))
        print("Portuguese NER parity: \(report.summary)")
        if !report.samples.isEmpty { print(report.detail) }
        #expect(report.expected >= 30, "corpus too small: \(report.expected) entities")
        #expect(report.recall >= 0.95, "recall \(report.recall)")
        #expect(report.precision >= 0.95, "precision \(report.precision)")
    }
}

/// Portuguese lemmas come from the edit-tree classifier, like German's and
/// Italian's — but with **no tagger in the pipeline**, which is the useful
/// thing this suite establishes: the component never needed one. It reads
/// tok2vec and predicts a tree per token; POS was always a German and Italian
/// coincidence, not a dependency.
@Suite("spaCy Portuguese lemma parity", .enabled(if: portugueseModelDirectory() != nil))
struct PortugueseLemmaTests {
    static let gold = LanguageGold.load("pt")

    @Test("lemmas match spaCy without a tagger in the pipeline")
    func lemmasMatchSpacy() throws {
        let lemmatizer = try EditTreeLemmatizer(directory: portugueseModelDirectory()!)
        let report = LanguageParity.perToken(
            Self.gold, try SpacyTokenizer.portuguese(),
            expected: \.lemma,
            produced: { lemmatizer.lemmas(for: $0, text: $1) }
        )
        print("Portuguese lemmas: \(report.summary)")
        if !report.samples.isEmpty { print(report.detail) }
        #expect(report.total >= 320, "corpus too small: \(report.total)")
        #expect(report.isExact)
    }
}

/// The gaps, asserted rather than footnoted.
///
/// Neither model has a tagger. French additionally lemmatizes with
/// `FrenchLemmatizer` in rule mode — bespoke Python like Spanish's, not the
/// edit trees — so French has no lemmas here, while Portuguese does.
@Suite("Romance pipeline gaps")
struct RomanceGapTests {

    @Test("neither model has a tagger",
          arguments: [("fr", frenchModelDirectory()), ("pt", portugueseModelDirectory())])
    func noTagger(language: String, directory: String?) throws {
        guard let directory else { return }
        #expect(throws: TaggerModel.LoadError.self) {
            _ = try TaggerModel(directory: directory)
        }
    }

    @Test("French has no edit-tree lemmatizer, Portuguese does")
    func lemmatizerAvailability() throws {
        if let french = frenchModelDirectory() {
            #expect(throws: (any Error).self) {
                _ = try EditTreeLemmatizer(directory: french)
            }
        }
        if let portuguese = portugueseModelDirectory() {
            #expect(throws: Never.self) {
                _ = try EditTreeLemmatizer(directory: portuguese)
            }
        }
    }
}

/// Inline regex flags, from the tokenizer's side.
///
/// French's `token_match` opens with `(?iu)`, and the engine used to parse that
/// and then ignore it — so capitalised compounds stopped matching while
/// lower-case ones still did: `franco-italienne` stayed whole, `Saint-Louis`
/// split. `PureRegex` honours inline flags now (see `RegexInlineFlagTests` for
/// the differential against Python), and this is the end-to-end consequence.
///
/// The 12 recognizer patterns carrying `(?i)` were unaffected throughout, but
/// by redundancy rather than by the flag working: the registry compiles every
/// pattern with `global_regex_flags = 26`, which already includes IGNORECASE.
@Suite("French token_match honours its inline flags")
struct FrenchTokenMatchFlagTests {

    @Test("capitalised compounds match, which is what (?iu) buys")
    func caseInsensitive() throws {
        let tokenizer = try SpacyTokenizer.french()
        #expect(tokenizer.isTokenMatch("Saint-Louis"))
        #expect(tokenizer.isTokenMatch("saint-louis"))
        #expect(tokenizer.isTokenMatch("SAINT-LOUIS"))
        #expect(!tokenizer.isTokenMatch("Dupont"))
    }

    @Test("and the tokenizer keeps them whole")
    func keepsCompoundsWhole() throws {
        let tokenizer = try SpacyTokenizer.french()
        #expect(tokenizer.tokenize("Saint-Louis").map(\.text) == ["Saint-Louis"])
        #expect(tokenizer.tokenize("Aix-en-Provence").map(\.text) == ["Aix-en-Provence"])
        #expect(tokenizer.tokenize("prud\'hommes").map(\.text) == ["prud\'hommes"])
    }
}
