import Testing
import Foundation
import PresidioConformance
import PresidioCore

/// `RecognizerResult`'s span algebra, against upstream's own tables.
///
/// These predicates decide what `remove_duplicates` collapses and what the
/// conflict resolver drops, so a divergence would reorder or silently delete
/// results from every recognizer at once — and it would do it quietly, because
/// each individual predicate is three lines that look obviously right.
///
/// They were asserted by hand-written Swift tests until now. The upstream tables
/// existed the whole time; `extract_fixtures.py` could not express them, because
/// a unit test of a value type has no text column, so they sat in the `skipped`
/// list under a reason that read like "not worth having".
@Suite("RecognizerResult predicates (harvested)")
struct OperationCorpusTests {

    static let corpus: OperationCorpus = {
        // swiftlint:disable:next force_try
        try! Corpus.operationCases()
    }()

    static func result(_ value: OperationCorpus.Predicate.Value) -> RecognizerResult {
        RecognizerResult(
            entityType: value.entityType, start: value.start,
            end: value.end, score: value.score
        )
    }

    @Test("the corpus is present and covers both outcomes")
    func corpusIsUseful() throws {
        let predicates = Self.corpus.predicates
        #expect(predicates.count >= 37, "corpus shrank to \(predicates.count)")
        // Every operation must have at least one true and one false case, or the
        // table is only testing that the function returns a constant.
        for op in Set(predicates.map(\.op)) {
            let outcomes = Set(predicates.filter { $0.op == op }.map(\.expected))
            #expect(outcomes == [true, false], "\(op) only ever expects \(outcomes)")
        }
    }

    @Test("every predicate matches upstream")
    func predicatesMatch() throws {
        var checked = 0
        for testCase in Self.corpus.predicates {
            let first = Self.result(testCase.first)
            let second = Self.result(testCase.second)
            let got: Bool
            switch testCase.op {
            case "contains": got = first.contains(second)
            case "contained_in": got = first.containedIn(second)
            case "equal_indices": got = first.equalIndices(second)
            case "has_conflict": got = first.hasConflict(with: second)
            case "greater_than": got = first > second
            case "equal": got = first == second
            case "hash_equal": got = first.hashValue == second.hashValue
            case "intersects": got = first.intersects(second) > 0
            default:
                Issue.record("unknown operation '\(testCase.op)' in \(testCase.test)")
                continue
            }
            checked += 1
            #expect(
                got == testCase.expected,
                """
                \(testCase.op) disagreed in \(testCase.test)
                  first  \(testCase.first)
                  second \(testCase.second)
                  upstream \(testCase.expected), swift \(got)
                """
            )
        }
        print("Predicate parity: \(checked)/\(Self.corpus.predicates.count) cases run")
        #expect(checked == Self.corpus.predicates.count)
    }

    /// Hashing is the one predicate where agreeing on the *table* is not the
    /// whole contract.
    ///
    /// Upstream hashes a formatted string and the port uses `Hasher`, so the
    /// values differ by construction and only the equivalence matters. The table
    /// checks that equal results hash equally and that four specific unequal
    /// ones do not. What it cannot check is the property `remove_duplicates`
    /// actually depends on — that `==` and `hashValue` agree — because Python
    /// gets that for free from a formatted string and Swift does not.
    @Test("equal results hash equally, over the whole predicate corpus")
    func hashingAgreesWithEquality() throws {
        for testCase in Self.corpus.predicates {
            let first = Self.result(testCase.first)
            let second = Self.result(testCase.second)
            if first == second {
                #expect(
                    first.hashValue == second.hashValue,
                    "equal results hash differently: \(testCase.first)"
                )
            }
        }
    }

    /// What the harvest still cannot reach, asserted so the number cannot drift
    /// without someone noticing.
    ///
    /// `skipped` means not covered *anywhere*. The first version of the tool
    /// meant "not covered by me" and listed four tables `extract_fixtures.py`
    /// already harvests, which overstated the gap — the same kind of error as
    /// the doc that called the remainder infrastructure, pointing the other way.
    /// Those are in `coveredElsewhere` now, and this asserts the two stay
    /// distinct.
    @Test("the unharvested remainder is recorded with reasons")
    func skippedIsRecorded() throws {
        let skipped = Self.corpus.skipped
        #expect(!skipped.isEmpty)
        for entry in skipped + Self.corpus.coveredElsewhere {
            #expect(!entry.reason.isEmpty, "\(entry.file) has no reason recorded")
        }
        #expect(
            !Self.corpus.coveredElsewhere.isEmpty,
            "the cross-reference found nothing, so it is probably not running"
        )
        for entry in Self.corpus.coveredElsewhere {
            #expect(entry.reason.contains("extract_fixtures.py"))
        }
    }
}
