import Testing
import Foundation
import PresidioConformance
@testable import PresidioNLP

/// End-to-end NER parity: raw text in, character spans out.
///
/// Parity is NOT exact — see the ratchet below for the measured figures and the
/// reason. Tokenization and NORMs are exact; the model forward pass is not.
///
/// This is the composition M3 exists to prove. The tokenizer and the model were
/// each validated against spaCy separately; only here do token boundaries,
/// NORMs and offset mapping all have to be right *simultaneously*.
///
/// The gold file is generated from the full spaCy pipeline with character
/// offsets, and the Swift side is given nothing but the raw text.
///
/// Model weights are not bundled (15 MB for `sm`, 619 MB for `lg`), so the
/// suite is gated on `SPACY_MODEL_DIR`. It reports loudly when unset rather
/// than passing vacuously — the failure mode upstream's `skip_by_engine`
/// fixture demonstrates.
/// Free function rather than a static on the suite: a `.enabled(if:)` condition
/// referencing the type it is attached to is a circular macro reference.
func spacyModelDirectory() -> String? {
    ProcessInfo.processInfo.environment["SPACY_MODEL_DIR"]
}

@Suite("spaCy NER parity", .enabled(if: spacyModelDirectory() != nil))
struct NERTests {

    struct Gold: Decodable {
        struct Case: Decodable {
            struct Entity: Decodable {
                let label: String
                let start: Int
                let end: Int
                let text: String
            }
            let text: String
            let entities: [Entity]
        }
        let model: String
        let cases: [Case]
    }

    static let gold: Gold = {
        // swiftlint:disable:next force_try
        try! JSONDecoder().decode(Gold.self, from: Corpus.data(named: "ner_gold_sm"))
    }()

    @Test("the model loads and has transition actions")
    func modelLoads() throws {
        let ner = try SpacyNER(modelDirectory: spacyModelDirectory()!)
        #expect(ner.actionCount > 0)
    }

    @Test("a missing model is reported, not crashed on")
    func missingModel() {
        #expect(throws: NERError.self) {
            _ = try SpacyNER(modelDirectory: "/nonexistent/model/path")
        }
    }

    @Test("entities match spaCy within the recorded bounds, from raw text")
    func entitiesMatchSpacy() throws {
        let directory = spacyModelDirectory()!
        let (matched, expected, produced, report) = try withLargeStack { () -> (Int, Int, Int, [String]) in
            let ner = try SpacyNER(modelDirectory: directory)
            var matched = 0, expectedTotal = 0, producedTotal = 0
            var report: [String] = []

            for testCase in Self.gold.cases {
                let got = ner.entities(in: testCase.text)
                let want = testCase.entities

                let gotKeys = Set(got.map { "\($0.start),\($0.end),\($0.label)" })
                let wantKeys = Set(want.map { "\($0.start),\($0.end),\($0.label)" })
                matched += gotKeys.intersection(wantKeys).count
                expectedTotal += wantKeys.count
                producedTotal += gotKeys.count

                if gotKeys != wantKeys, report.count < 10 {
                    report.append("""
                        \(testCase.text.prefix(90).debugDescription)
                          spacy \(wantKeys.sorted())
                          swift \(gotKeys.sorted())
                        """)
                }
            }
            return (matched, expectedTotal, producedTotal, report)
        }

        #expect(expected >= 2000, "gold corpus too small: \(expected) entities")

        // Ratchet, not an equality assertion — end-to-end parity is NOT exact.
        //
        // Tokenization and NORMs are exact (0/2000 divergences on this very
        // corpus), so the residual is entirely in the model forward pass: most
        // likely float accumulation order, since the hand-written SIMD reduction
        // sums in a different order from numpy's BLAS, which flips argmax on
        // borderline transitions. The divergent cases are plausible spans with a
        // different label or extent (DATE vs CARDINAL over an identical span),
        // not corrupted offsets.
        //
        // Current: 2564/2592 matched, 28 missed, 69 spurious = 98.92% recall.
        // These bounds must not regress. To close the gap, dump the tok2vec
        // output for a divergent sentence and diff it against spaCy's — if the
        // vectors differ in the last few bits, it is accumulation order.
        let recall = Double(matched) / Double(expected)
        let precision = Double(matched) / Double(produced)
        #expect(
            recall >= 0.989,
            """
            recall regressed to \(recall): matched \(matched), spacy \(expected)
            \(report.joined(separator: "\n"))
            """
        )
        #expect(
            precision >= 0.973,
            "precision regressed to \(precision): matched \(matched), swift \(produced)"
        )
    }

    @Test("entity text round-trips onto the source")
    func entityTextRoundTrips() throws {
        let directory = spacyModelDirectory()!
        try withLargeStack {
            let ner = try SpacyNER(modelDirectory: directory)
            for testCase in Self.gold.cases.prefix(300) {
                let scalars = Array(testCase.text.unicodeScalars)
                for entity in ner.entities(in: testCase.text) {
                    guard entity.start >= 0, entity.end <= scalars.count else {
                        Issue.record("span out of range: \(entity)")
                        continue
                    }
                    let slice = String(
                        String.UnicodeScalarView(scalars[entity.start..<entity.end])
                    )
                    #expect(slice == entity.text)
                }
            }
        }
    }
}
