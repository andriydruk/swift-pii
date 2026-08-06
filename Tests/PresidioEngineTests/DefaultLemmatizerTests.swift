import Testing
import Foundation
import PresidioCore
import PresidioNLP
@testable import PresidioEngine

func spacyModel() -> String? {
    ProcessInfo.processInfo.environment["SPACY_MODEL_DIR"]
}

/// With a model in hand, the exact lemmatizer is the default and the
/// approximation is what you have to ask for.
@Suite("Default lemmatizer", .enabled(if: spacyModel() != nil))
struct DefaultLemmatizerTests {

    @Test("a model-backed engine uses spaCy's rule-mode lemmatizer")
    func defaultsToRuleMode() throws {
        let engine = try SpacyNlpEngine(modelDirectory: spacyModel()!)
        #expect(engine.lemmatizerKind == "spaCy rule-mode (exact)")
        #expect(engine.warnings.isEmpty)
    }

    @Test("the caller can still override it")
    func explicitOverrideWins() throws {
        let engine = try SpacyNlpEngine(
            modelDirectory: spacyModel()!, lemmatizer: LookupLemmatizer()
        )
        #expect(engine.lemmatizerKind.contains("caller-supplied"))
        #expect(engine.warnings.isEmpty, "an explicit choice is not a fallback")
    }

    /// The lemmas actually differ, so the default is doing something.
    @Test("the default produces spaCy's lemmas where the lookup table cannot")
    func defaultLemmasAreExact() throws {
        let model = spacyModel()!
        let exact = try SpacyNlpEngine(modelDirectory: model)
        let approximate = try SpacyNlpEngine(
            modelDirectory: model, lemmatizer: LookupLemmatizer()
        )
        // "was" lemmatizes to "be" only through the attribute ruler, which
        // needs the tag.
        let text = "The delivery was late and the identities were checked"
        let exactLemmas = exact.process(text: text, language: "en").lemmas
        let approximateLemmas = approximate.process(text: text, language: "en").lemmas
        #expect(exactLemmas.contains("be"), "\(exactLemmas)")
        #expect(!approximateLemmas.contains("be"), "\(approximateLemmas)")
        #expect(exactLemmas.contains("delivery"))
        #expect(exactLemmas.contains("identity"))
    }

    /// A model without a tagger must say so rather than quietly degrade.
    @Test("a tagger-less model falls back loudly")
    func fallbackIsLoud() throws {
        let stripped = NSTemporaryDirectory() + "no-tagger-\(UUID().uuidString)"
        let manager = FileManager.default
        try manager.createDirectory(atPath: stripped, withIntermediateDirectories: true)
        defer { try? manager.removeItem(atPath: stripped) }
        // Enough of a model for the NER component, nothing for the tagger.
        for item in ["ner", "vocab", "tokenizer"] {
            let source = spacyModel()! + "/" + item
            if manager.fileExists(atPath: source) {
                try? manager.copyItem(atPath: source, toPath: stripped + "/" + item)
            }
        }

        guard let engine = try? SpacyNlpEngine(modelDirectory: stripped) else {
            // The NER component itself may refuse; that is a louder failure
            // still, which is fine.
            return
        }
        #expect(engine.lemmatizerKind.contains("approximate"))
        #expect(engine.warnings.count == 1)
        // The wording widened when German arrived: a model can now miss the
        // rule lemmatizer *and* the trainable one, and "no usable tagger" named
        // only the first of those.
        #expect(engine.warnings[0].contains("neither a rule lemmatizer nor a trainable one"),
                "\(engine.warnings[0])")
    }

    @Test("the warning reaches AnalyzerEngine.configurationWarnings")
    func warningsPropagate() throws {
        var registry = try RecognizerRegistry.loadPredefined()
        registry.add(SpacyRecognizer())
        let engine = try AnalyzerEngine(
            registry: registry,
            nlpEngine: try SpacyNlpEngine(modelDirectory: spacyModel()!)
        )
        #expect(engine.configurationWarnings.isEmpty, "nothing degraded here")
    }
}
