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
/// Where to find an unpacked spaCy model.
///
/// The suite is skipped without one, which is convenient locally and was a
/// trap: it meant NER parity ran nowhere for a long time, including CI. There
/// is now a dedicated CI job that fetches the model and asserts the suite
/// actually executed — a `--filter` matching nothing exits 0.
///
/// It must be **en_core_web_sm 3.7.1**, the version the gold corpus was built
/// from. A different patch release has different weights and scores ~62%
/// against this corpus, which reads as a catastrophic regression and is only a
/// version mismatch.
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
        let ner = try SpacyNER(modelDirectory: directory)
        let (matched, expected, produced, report): (Int, Int, Int, [String]) = {
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
        }()

        #expect(expected >= 2000, "gold corpus too small: \(expected) entities")

        // Ratchet, not an equality assertion — end-to-end parity is not exact.
        //
        // This comment used to blame float accumulation order. That was a
        // guess, and it was wrong: 24 of the 28 misses came from the reserved
        // string-store symbols, whose table was read from a relative
        // "symbols.tsv" that never existed, so every shape like "X" hashed
        // instead of resolving to its symbol id. Bundling the table took
        // recall from 98.92% to 99.85%.
        //
        // Current: 2588/2592 matched = 99.85% recall and precision. The
        // remaining 4 are plausible spans with a different label or extent,
        // not corrupted offsets — the accumulation-order theory may finally be
        // right about those, but it has not been demonstrated.
        let recall = Double(matched) / Double(expected)
        let precision = Double(matched) / Double(produced)
        print("NER parity: matched \(matched)/\(expected) recall \(recall) precision \(precision)")
        #expect(
            recall >= 0.998,
            """
            recall regressed to \(recall): matched \(matched), spacy \(expected)
            \(report.joined(separator: "\n"))
            """
        )
        #expect(
            precision >= 0.998,
            "precision regressed to \(precision): matched \(matched), swift \(produced)"
        )
    }

    @Test("entity text round-trips onto the source")
    func entityTextRoundTrips() throws {
        let directory = spacyModelDirectory()!
        let ner = try SpacyNER(modelDirectory: directory)
        do {
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
