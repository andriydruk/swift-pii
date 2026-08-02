import Testing
import PresidioCore
import PresidioAnalyzer
import PresidioRecognizers
@testable import PresidioEngine

/// Pins exactly what the default lemmatizer costs.
///
/// `LowercaseLemmatizer` stands in for spaCy's rule-based lemmatizer, which
/// would need the tagger (POS is required in rule mode) and ~1.3 MB of
/// WordNet-derived lookup tables. That trade is only defensible with a number
/// attached, and the number has to be measured against the thing that actually
/// consumes lemmas — context matching — not against lemma accuracy in general.
///
/// Raw disagreement is common: over 1,500 texts, 42 distinct surface forms
/// lemmatize to something that is *not* a substring of themselves. Most are
/// invisible here because upstream excludes them from keywords anyway (`be`,
/// the lemma of every form of "is", is dropped by name).
///
/// What matters is how many of the **523 context words across all 88
/// recognizers** can only be reached through a lemma. Measured: **6**, all the
/// same `-y → -ies` plural rule, and one of them is not a word.
@Suite("Lemmatizer gap")
struct LemmatizerGapTests {

    /// A stub standing in for a real lemmatizer, covering only the rule the
    /// measurement found. Used to show the seam works — not shipped.
    struct PluralYLemmatizer: Lemmatizing {
        func lemma(for token: String) -> String {
            let lower = token.lowercased()
            guard lower.hasSuffix("ies"), lower.count > 4 else { return lower }
            return String(lower.dropLast(3)) + "y"
        }
    }

    static let lemmaOnlyContextWords = [
        "beneficiary", "birthday", "delivery", "identity", "security", "taxonomy",
    ]

    /// If a future recognizer adds a context word whose inflections are only
    /// reachable through a lemma, this is where it should become visible.
    @Test("the lemma-only context words are the ones we measured")
    func gapIsWhereWeThinkItIs() throws {
        let definitions = try Catalog.definitions()
        let context = Set(definitions.flatMap { $0.context }.map { $0.lowercased() })
        for word in Self.lemmaOnlyContextWords where word != "birthdaies" {
            #expect(
                context.contains(word),
                "\(word) is no longer a context word; re-run the measurement"
            )
        }
        // The catalogue's context vocabulary is the input to that measurement,
        // so a large change to it invalidates the 6.
        #expect(
            context.count >= 500 && context.count <= 560,
            "context vocabulary moved to \(context.count); re-measure the gap"
        )
    }

    /// The seam is real: swapping the lemmatizer changes the score, so a caller
    /// who needs spaCy-exact context matching can supply one.
    @Test("a lemmatizer changes context matching, and the default does not")
    func swappingTheLemmatizerMatters() throws {
        // UsMbiRecognizer lists "beneficiary" and has no checksum, so its
        // results keep the pattern score and a boost is visible. A validated
        // recognizer is useless here: ZaIdNumber was tried first and every
        // surviving match is already 1.0, where the boost is capped away.
        let definitions = try Catalog.definitions()
        guard let mbi = definitions.first(where: { $0.class == "UsMbiRecognizer" }),
              let recognizer = Catalog.makeRecognizer(
                  mbi, logic: ValidatorRegistry.logic(for: "UsMbiRecognizer")
              )
        else { Issue.record("UsMbiRecognizer unavailable"); return }

        var registry = RecognizerRegistry(recognizers: [recognizer])
        registry.add(SpacyRecognizer())

        func score(lemmatizer: any Lemmatizing) throws -> Double? {
            let engine = try AnalyzerEngine(
                registry: registry,
                nlpEngine: try TokenizerOnlyNlpEngine(lemmatizer: lemmatizer)
            )
            let results = try engine.analyze(
                text: "Their beneficiaries include 1EG4-TE5-MK73"
            )
            return results.first { $0.entityType == "US_MBI" }?.score
        }

        let plain = try score(lemmatizer: LowercaseLemmatizer())
        let lemmatized = try score(lemmatizer: PluralYLemmatizer())
        #expect(plain != nil && lemmatized != nil)
        // "identities" does not contain "identity", so only the lemmatized run
        // sees the context word. This is the entire measured cost of the
        // default, on the one case where it bites.
        #expect(try #require(lemmatized) > #require(plain))
        #expect(try #require(plain) == 0.5, "pattern score, unboosted")
        #expect(try #require(lemmatized) == 0.85, "0.5 + the 0.35 context factor")
    }
}
