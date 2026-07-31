import Testing
@testable import PresidioCore

/// Positional start/end, with type and score as labelled defaults — a leading
/// defaulted parameter makes the call sites ambiguous to infer.
private func r(
    _ start: Int, _ end: Int, score: Double = 0.5, type: String = "X"
) -> RecognizerResult {
    RecognizerResult(entityType: type, start: start, end: end, score: score)
}

/// The span algebra is ported line-for-line from
/// `presidio-analyzer/presidio_analyzer/recognizer_result.py`. These cases pin
/// the boundary behaviour, including the parts that look like bugs but must be
/// reproduced because dedup and conflict resolution are built on them.
@Suite("RecognizerResult span algebra")
struct RecognizerResultTests {

    @Test("intersects returns the overlap length")
    func intersectsOverlap() {
        #expect(r(0, 10).intersects(r(5, 15)) == 5)
        #expect(r(5, 15).intersects(r(0, 10)) == 5)
        #expect(r(0, 10).intersects(r(0, 10)) == 10)
        #expect(r(0, 10).intersects(r(3, 7)) == 4)   // fully contained
    }

    @Test("intersects returns 0 for disjoint and abutting spans")
    func intersectsDisjoint() {
        #expect(r(0, 5).intersects(r(10, 15)) == 0)
        #expect(r(10, 15).intersects(r(0, 5)) == 0)
        // Abutting: end == other.start. Python does not early-return here, it
        // falls through to min(end)-max(start) == 0. Same answer, but the path
        // matters if the arithmetic is ever refactored.
        #expect(r(0, 5).intersects(r(5, 10)) == 0)
    }

    @Test("intersects is symmetric")
    func intersectsSymmetric() {
        let samples = [r(0, 10), r(5, 15), r(3, 7), r(10, 20), r(0, 1), r(7, 7)]
        for a in samples {
            for b in samples {
                #expect(a.intersects(b) == b.intersects(a))
            }
        }
    }

    @Test("containedIn and contains are duals")
    func containment() {
        #expect(r(3, 7).containedIn(r(0, 10)))
        #expect(r(0, 10).contains(r(3, 7)))
        #expect(!r(0, 10).containedIn(r(3, 7)))

        // Equal spans satisfy both directions.
        #expect(r(0, 10).containedIn(r(0, 10)))
        #expect(r(0, 10).contains(r(0, 10)))

        for a in [r(0, 10), r(3, 7), r(5, 15)] {
            for b in [r(0, 10), r(3, 7), r(5, 15)] {
                #expect(a.containedIn(b) == b.contains(a))
            }
        }
    }

    @Test("equalIndices ignores type and score")
    func equalIndicesIgnoresPayload() {
        #expect(r(0, 5, score: 0.1, type: "A").equalIndices(r(0, 5, score: 0.9, type: "B")))
        #expect(!r(0, 5, type: "A").equalIndices(r(0, 6, type: "A")))
    }

    @Test("hasConflict: equal indices lose on ties")
    func conflictOnEqualIndices() {
        // Python: `if equal_indices: return self.score <= other.score`.
        // The <= means an exact score tie is a conflict — the receiver loses.
        #expect(r(0, 5, score: 0.5, type: "A").hasConflict(with: r(0, 5, score: 0.5, type: "B")))
        #expect(r(0, 5, score: 0.4, type: "A").hasConflict(with: r(0, 5, score: 0.6, type: "B")))
        #expect(!r(0, 5, score: 0.6, type: "A").hasConflict(with: r(0, 5, score: 0.4, type: "B")))
    }

    @Test("hasConflict: contained spans lose regardless of score")
    func conflictOnContainment() {
        // A higher score does not rescue a contained span.
        #expect(r(3, 7, score: 0.99, type: "A").hasConflict(with: r(0, 10, score: 0.01, type: "B")))
        #expect(!r(0, 10, score: 0.01, type: "A").hasConflict(with: r(3, 7, score: 0.99, type: "B")))
        // Merely overlapping is not a conflict.
        #expect(!r(0, 10, type: "A").hasConflict(with: r(5, 15, type: "B")))
    }

    @Test("length and range agree with the offsets")
    func lengthAndRange() {
        #expect(r(3, 7).length == 4)
        #expect(r(3, 7).range == 3..<7)
        #expect(r(5, 5).length == 0)
    }

    // MARK: - Ordering

    @Test("Comparable matches Python __gt__: start, then end")
    func comparableMatchesPython() {
        #expect(r(0, 5) < r(1, 3))     // earlier start wins
        #expect(r(0, 5) < r(0, 9))     // same start, shorter end first
        #expect(!(r(0, 5) < r(0, 5)))  // irreflexive
    }

    @Test("the deterministic total order is stable and complete")
    func totalOrderIsDeterministic() {
        // These four differ only in entityType — exactly the case Python's sort
        // key omits, which is where PYTHONHASHSEED nondeterminism shows up.
        let results = [
            r(0, 5, score: 0.8, type: "ZULU"),
            r(0, 5, score: 0.8, type: "ALPHA"),
            r(0, 5, score: 0.8, type: "MIKE"),
            r(0, 5, score: 0.8, type: "BRAVO"),
        ]
        let once = results.sortedDeterministically()
        #expect(once.map { $0.entityType } == ["ALPHA", "BRAVO", "MIKE", "ZULU"])

        // Order must not depend on input order.
        #expect(results.reversed().sortedDeterministically() == once)
        for _ in 0..<20 {
            #expect(results.shuffled().sortedDeterministically() == once)
        }
    }

    @Test("total order applies score, start, length, type in that priority")
    func totalOrderPriority() {
        let results = [
            r(10, 20, score: 0.5, type: "A"),
            r(0, 10, score: 0.9, type: "A"),   // highest score first
            r(0, 5, score: 0.5, type: "A"),
            r(0, 10, score: 0.5, type: "A"),   // same start as above, longer first
        ]
        let sorted = results.sortedDeterministically()
        #expect(sorted[0].score == 0.9)
        #expect(sorted[1].start == 0 && sorted[1].length == 10)
        #expect(sorted[2].start == 0 && sorted[2].length == 5)
        #expect(sorted[3].start == 10)
    }

    @Test("sortedByStart reproduces the upstream assertion normalization")
    func sortedByStartMatchesUpstream() {
        // presidio-analyzer/tests/assertions.py sorts by start before comparing.
        let results = [r(20, 25), r(0, 5), r(10, 15)]
        #expect(results.sortedByStart().map { $0.start } == [0, 10, 20])
    }
}
