import Testing
import PresidioConformance
@testable import PresidioCore

/// Integrity checks on the harvested corpus.
///
/// No recognizers exist yet, so these do not assert detection behaviour. They
/// assert that the corpus is *internally coherent and consistent with the
/// offset model* — which cross-validates both. Every upstream span is
/// interpreted as a Unicode scalar range through `TextDocument`; if the offset
/// model were wrong, the substring checks below would fail against 1,677 real
/// cases rather than against fixtures we invented.
@Suite("Conformance corpus integrity")
struct ConformanceCorpusTests {

    @Test("the recognizer corpus loads and is non-trivial")
    func recognizerCorpusLoads() throws {
        let corpus = try Corpus.recognizerCases()
        #expect(corpus.schemaVersion == 1)
        #expect(corpus.source.repo == "data-privacy-stack/presidio")
        #expect(!corpus.source.commit.isEmpty)

        let cases = corpus.tables.reduce(0) { $0 + $1.cases.count }
        // Guard against a silently-degraded extraction: the numbers only go up
        // when upstream adds tests, never down because our parser regressed.
        #expect(corpus.tables.count >= 100)
        #expect(cases >= 1600, "case count regressed to \(cases)")
        #expect(corpus.recognizers.count >= 80)
        #expect(corpus.entityTypes.count >= 80)
    }

    @Test("the validator corpus loads")
    func validatorCorpusLoads() throws {
        let corpus = try Corpus.validatorCases()
        let cases = corpus.tables.reduce(0) { $0 + $1.cases.count }
        #expect(corpus.tables.count >= 20)
        #expect(cases >= 200, "validator case count regressed to \(cases)")

        // The tri-state must survive the JSON round trip; collapsing
        // `indeterminate` into `invalid` would change recognizer behaviour.
        let outcomes = Set(corpus.tables.flatMap { $0.cases.map(\.expected) })
        #expect(outcomes.contains(.valid))
        #expect(outcomes.contains(.invalid))
    }

    @Test("every expected span is in bounds and slices cleanly")
    func spansAreValidScalarRanges() throws {
        let corpus = try Corpus.recognizerCases()
        var checked = 0

        for table in corpus.tables {
            for testCase in table.cases {
                let doc = TextDocument(testCase.text)
                for span in testCase.expected {
                    #expect(
                        span.start >= 0 && span.end <= doc.count && span.start <= span.end,
                        """
                        out-of-bounds span \(span.start)..<\(span.end) in \
                        \(table.recognizer) (\(table.file)) for text of \
                        \(doc.count) scalars: \(testCase.text.debugDescription)
                        """
                    )
                    // The span must actually slice — this is the property that
                    // proves the corpus offsets and TextDocument agree.
                    #expect(
                        doc.substring(start: span.start, end: span.end) != nil,
                        "unsliceable span in \(table.recognizer): \(table.file)"
                    )
                    checked += 1
                }
            }
        }
        #expect(checked >= 900, "only \(checked) spans checked")
    }

    @Test("score bounds are well-formed")
    func scoreBoundsAreSane() throws {
        let corpus = try Corpus.recognizerCases()
        for table in corpus.tables {
            for testCase in table.cases {
                for span in testCase.expected {
                    #expect(span.scoreMin >= 0.0 && span.scoreMin <= 1.0,
                            "\(table.recognizer): scoreMin \(span.scoreMin)")
                    #expect(span.scoreMax >= 0.0 && span.scoreMax <= 1.0,
                            "\(table.recognizer): scoreMax \(span.scoreMax)")
                    #expect(span.scoreMin <= span.scoreMax,
                            "\(table.recognizer): inverted score range")
                }
            }
        }
    }

    @Test("the score epsilon matches upstream's assertion helper")
    func scoreEpsilon() {
        let exact = Corpus.Span(
            start: 0, end: 1, entity: "X", scoreMin: 0.5, scoreMax: 0.5
        )
        #expect(exact.accepts(score: 0.5))
        #expect(exact.accepts(score: 0.5 + 9e-6))   // inside 1e-5
        #expect(!exact.accepts(score: 0.5 + 1e-3))

        // Upstream clamps to [0, 1] after applying the epsilon, so a 1.0 bound
        // must still accept exactly 1.0.
        let top = Corpus.Span(
            start: 0, end: 1, entity: "X", scoreMin: 1.0, scoreMax: 1.0
        )
        #expect(top.accepts(score: 1.0))
    }

    @Test("enumerated spans agree with the asserted count")
    func spanCountsAreConsistent() throws {
        let corpus = try Corpus.recognizerCases()
        for table in corpus.tables {
            for testCase in table.cases where testCase.spansEnumerated {
                // When the table enumerated positions, the count must match —
                // otherwise the Swift runner cannot know which is authoritative.
                #expect(
                    testCase.expected.count == testCase.expectedCount,
                    """
                    \(table.recognizer) (\(table.file)): asserted \
                    \(testCase.expectedCount) results but enumerated \
                    \(testCase.expected.count) spans for \
                    \(testCase.text.debugDescription)
                    """
                )
            }
        }
    }

    @Test("negative cases carry no spans")
    func negativeCasesAreEmpty() throws {
        let corpus = try Corpus.recognizerCases()
        for table in corpus.tables {
            for testCase in table.cases where testCase.expectedCount == 0 {
                #expect(testCase.expected.isEmpty,
                        "\(table.recognizer): zero-count case has spans")
            }
        }
    }

    /// Coverage is reported, never silently trimmed. If the extractor starts
    /// dropping tables, this surfaces it rather than letting a shrinking corpus
    /// look like a passing build.
    @Test("skipped tables are recorded with reasons")
    func skippedTablesAreVisible() throws {
        let corpus = try Corpus.recognizerCases()
        for skipped in corpus.skipped {
            #expect(!skipped.reason.isEmpty)
            #expect(!skipped.file.isEmpty)
        }
        let droppedRows = corpus.skipped.compactMap(\.rows).reduce(0, +)
        // Documents the current known gap. Lower it as shapes get supported;
        // a rise means the extractor regressed against a new upstream commit.
        #expect(droppedRows <= 260, "dropped rows rose to \(droppedRows)")
    }
}
