import Testing
import PresidioConformance
import PresidioCore
import PresidioAnalyzer
import PresidioRecognizers
@testable import PresidioEngine

/// Runs Presidio's own `AnalyzerEngine` output against this port.
///
/// The engine is driven with **Python's NLP artifacts**, not our own: the
/// fixture records the tokens, offsets, lemmas and NER spans spaCy produced,
/// and they are injected verbatim. Otherwise the 1.1% NER gap and any engine
/// bug would be indistinguishable, and the more likely failure — an engine bug
/// hidden by a compensating NER difference — would never surface.
@Suite("AnalyzerEngine conformance")
struct AnalyzerEngineConformanceTests {

    static func makeEngine(
        contextEnhancer: any ContextAwareEnhancing = LemmaContextAwareEnhancer()
    ) throws -> AnalyzerEngine {
        var registry = try RecognizerRegistry.loadPredefined()
        // Upstream's default registry includes the NLP recognizer, which is
        // what turns spaCy's spans into PERSON/LOCATION results.
        registry.add(SpacyRecognizer())
        return try AnalyzerEngine(registry: registry, contextEnhancer: contextEnhancer)
    }

    static func artifacts(
        _ raw: Corpus.AnalyzerCorpus.Artifacts
    ) -> NlpArtifacts {
        NlpArtifacts(
            tokens: raw.tokens,
            tokenIndices: raw.tokenIndices,
            lemmas: raw.lemmas,
            // Keywords come from the fixture rather than being recomputed, so
            // this test measures the engine. `keywordDerivationMatchesPython`
            // measures the derivation separately.
            keywords: raw.keywords,
            entities: raw.entities.map {
                NlpEntity(text: $0.text, label: $0.label, start: $0.start, end: $0.end)
            },
            scores: raw.scores
        )
    }

    /// Options for one recorded case. Mirrors the matrix in
    /// `Tools/analyzer_reference.py`.
    static func run(
        _ engine: AnalyzerEngine, case name: String, text: String, artifacts: NlpArtifacts
    ) throws -> [RecognizerResult] {
        switch name {
        case "default":
            return try engine.analyze(text: text, artifacts: artifacts)
        case "entities_subset":
            return try engine.analyze(
                text: text, entities: ["PHONE_NUMBER", "EMAIL_ADDRESS", "PERSON"],
                artifacts: artifacts
            )
        case "threshold_0_5":
            return try engine.analyze(text: text, scoreThreshold: 0.5, artifacts: artifacts)
        case "threshold_0_85":
            return try engine.analyze(text: text, scoreThreshold: 0.85, artifacts: artifacts)
        case "context_words":
            return try engine.analyze(
                text: text, context: ["credit", "card", "passport", "phone"],
                artifacts: artifacts
            )
        case "allow_exact":
            return try engine.analyze(
                text: text, allowList: ["David", "212-555-5555", "example.com"],
                allowListMatch: .exact, artifacts: artifacts
            )
        case "allow_regex":
            return try engine.analyze(
                text: text, allowList: [#"\d{3}-\d{3}-\d{4}"#, "example"],
                allowListMatch: .regex, artifacts: artifacts
            )
        default:
            Issue.record("unknown option set '\(name)'")
            return []
        }
    }

    struct Tally {
        var matched = 0
        var mismatched = 0
        var details: [String] = []
    }

    /// Entity type of a `TYPE@start-end=score` key.
    static func entityType(of key: String) -> String {
        String(key.prefix { $0 != "@" })
    }

    @Test("engine results agree with Presidio across the option matrix")
    func matrixAgrees() throws {
        let corpus = try Corpus.analyzerReference()
        let engine = try Self.makeEngine()
        var byCase: [String: Tally] = [:]
        // Attributing divergences by entity separates a genuine engine bug
        // from the phone matcher's already-measured leniency gap.
        var byEntity: [String: Int] = [:]

        for entry in corpus.texts {
            let artifacts = Self.artifacts(entry.artifacts)
            for name in corpus.cases {
                guard let expected = entry.runs[name] else { continue }
                let got = try Self.run(
                    engine, case: name, text: entry.text, artifacts: artifacts
                )
                let gotKeys = got.map {
                    "\($0.entityType)@\($0.start)-\($0.end)=\(($0.score * 1e6).rounded() / 1e6)"
                }.sorted()
                let wantKeys = expected.map {
                    "\($0.entity)@\($0.start)-\($0.end)=\(($0.score * 1e6).rounded() / 1e6)"
                }.sorted()

                var tally = byCase[name] ?? Tally()
                if gotKeys == wantKeys {
                    tally.matched += 1
                } else {
                    tally.mismatched += 1
                    let missing = Set(wantKeys).subtracting(gotKeys).sorted()
                    let extra = Set(gotKeys).subtracting(wantKeys).sorted()
                    for key in missing { byEntity["\(Self.entityType(of: key)) missing", default: 0] += 1 }
                    for key in extra { byEntity["\(Self.entityType(of: key)) extra", default: 0] += 1 }
                    if tally.details.count < 3 {
                        tally.details.append(
                            "  \(entry.text.prefix(60).debugDescription)"
                            + "\n    missing: \(missing)\n    extra:   \(extra)"
                        )
                    }
                }
                byCase[name] = tally
            }
        }

        var report: [String] = []
        var totalMatched = 0, totalCases = 0
        for name in corpus.cases {
            guard let tally = byCase[name] else { continue }
            let total = tally.matched + tally.mismatched
            totalMatched += tally.matched
            totalCases += total
            report.append("  \(name): \(tally.matched)/\(total)")
            report.append(contentsOf: tally.details)
        }
        let attribution = byEntity.sorted { $0.value > $1.value }
            .map { "    \($0.key): \($0.value)" }.joined(separator: "\n")
        print("""
            AnalyzerEngine vs Presidio:
            \(report.joined(separator: "\n"))
              divergences by entity:
            \(attribution)
            """)

        #expect(totalCases >= 6000, "corpus shrank: \(totalCases) runs")
        // Exact. This was a ratchet at 11 while the phone port was missing
        // extension handling, descriptor anchoring, country-code extraction
        // without a '+', and metadata for every region outside the configured
        // set. With those closed there is no residual, so it is an equality:
        // a single divergence is now a regression, not a known gap.
        #expect(
            totalCases == totalMatched,
            "\(totalCases - totalMatched)/\(totalCases) runs diverged\n\(report.joined(separator: "\n"))"
        )
        // Nothing may diverge for any entity other than PHONE_NUMBER, and
        // nothing may be *extra* — a false positive is a different class of
        // failure from a miss and must not hide inside the ratchet.
        let unexpected = byEntity.filter { !$0.key.hasPrefix("PHONE_NUMBER ") }
        #expect(unexpected.isEmpty, "\(unexpected)")
        #expect(
            byEntity.filter { $0.key.hasSuffix(" extra") }.isEmpty,
            "false positives: \(byEntity.filter { $0.key.hasSuffix(" extra") })"
        )
    }

    /// The keyword derivation is fed from the fixture above, so it needs its
    /// own check — otherwise `makeKeywords`, `isPunctuation` and the stopword
    /// table would all be untested.
    @Test("keyword derivation matches Python")
    func keywordDerivationMatchesPython() throws {
        let corpus = try Corpus.analyzerReference()
        var matched = 0, total = 0
        var examples: [String] = []

        for entry in corpus.texts {
            total += 1
            let derived = NlpArtifacts.makeKeywords(entry.artifacts.lemmas) {
                LexicalTables.isStopWord($0, language: "en")
            }
            if derived == entry.artifacts.keywords {
                matched += 1
            } else if examples.count < 5 {
                examples.append(
                    "  \(entry.text.prefix(50).debugDescription)\n"
                    + "    got:  \(derived)\n    want: \(entry.artifacts.keywords)"
                )
            }
        }
        #expect(LexicalTables.isLoaded, "stopword table did not load")
        #expect(
            matched == total,
            "\(total - matched)/\(total) keyword lists diverged\n\(examples.joined(separator: "\n"))"
        )
    }

    /// `whole_word` is the mode where lemmatization becomes observable, so the
    /// port is measured there too rather than only in the default mode.
    @Test("the enhancer's whole-word mode is wired through")
    func wholeWordModeWorks() throws {
        let enhancer = LemmaContextAwareEnhancer(matchingMode: .wholeWord)
        #expect(
            LemmaContextAwareEnhancer.findSupportiveWord(
                in: ["duplicate"], recognizerContext: ["lic"], mode: .wholeWord
            ) == nil
        )
        #expect(
            LemmaContextAwareEnhancer.findSupportiveWord(
                in: ["duplicate"], recognizerContext: ["lic"], mode: .substring
            ) == "lic"
        )
        #expect(enhancer.matchingMode == .wholeWord)
    }
}
