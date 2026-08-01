import Testing
import PresidioConformance
import PresidioCore
import PresidioAnalyzer
@testable import PresidioRecognizers

/// Runs Presidio's own recognizer expectations against the Swift port.
///
/// Comparison follows upstream's assertion helper
/// (`presidio-analyzer/tests/assertions.py`): sort by start, assert the result
/// count, then check entity type, offsets, and score within a 1e-5 epsilon
/// clamped to [0, 1].
///
/// Cases are partitioned by whether the recognizer needs Swift-side checksum
/// logic that is not yet implemented. Those are reported as a measured gap
/// rather than skipped silently — an unimplemented validator must never look
/// like a passing test.
@Suite("Recognizer conformance")
struct RecognizerConformanceTests {

    struct Outcome {
        var passed = 0
        var failed = 0
        var details: [String] = []
    }

    static let definitions: [String: Catalog.Definition] = {
        // swiftlint:disable:next force_try
        let all = try! Catalog.definitions()
        return Dictionary(uniqueKeysWithValues: all.map { ($0.class, $0) })
    }()

    /// Whether this table's fixture variant is supported at all.
    static func isSupported(_ table: Corpus.Table) -> Bool {
        ValidatorRegistry.logic(for: table.recognizer, fixture: table.fixture) != nil
    }

    /// Run one corpus table and return its pass/fail tally.
    static func run(
        table: Corpus.Table, definition: Catalog.Definition
    ) -> Outcome {
        var outcome = Outcome()
        guard let resolved = ValidatorRegistry.logic(
            for: table.recognizer, fixture: table.fixture
        ) else {
            outcome.failed += table.cases.count
            outcome.details.append(
                "\(table.recognizer): unsupported fixture '\(table.fixture)'"
            )
            return outcome
        }
        guard let recognizer = Catalog.makeRecognizer(
            definition, logic: resolved ?? RecognizerLogic()
        ) else {
            outcome.failed += table.cases.count
            outcome.details.append("\(table.recognizer): could not be built")
            return outcome
        }

        for testCase in table.cases {
            let got = recognizer.analyze(testCase.text).sortedByStart()
            var problem: String?

            if got.count != testCase.expectedCount {
                problem = "expected \(testCase.expectedCount) results, got \(got.count)"
            } else if testCase.spansEnumerated {
                for (result, expected) in zip(got, testCase.expected) {
                    if result.start != expected.start || result.end != expected.end {
                        problem = """
                            span \(result.start)..<\(result.end), \
                            expected \(expected.start)..<\(expected.end)
                            """
                        break
                    }
                    if let entity = expected.entity, result.entityType != entity {
                        problem = "entity \(result.entityType), expected \(entity)"
                        break
                    }
                    if !expected.accepts(score: result.score) {
                        problem = """
                            score \(result.score) outside \
                            [\(expected.scoreMin), \(expected.scoreMax)]
                            """
                        break
                    }
                }
            }

            if let problem {
                outcome.failed += 1
                if outcome.details.count < 5 {
                    outcome.details.append(
                        "  \(testCase.text.debugDescription): \(problem)"
                    )
                }
            } else {
                outcome.passed += 1
            }
        }
        return outcome
    }

    /// Recognizers that need no Swift logic at all — pure pattern matching.
    /// These have no excuse for failing.
    @Test("pure-pattern recognizers match upstream exactly")
    func purePatternRecognizers() throws {
        let corpus = try Corpus.recognizerCases()
        var total = Outcome()
        var covered = 0

        for table in corpus.tables {
            guard let definition = Self.definitions[table.recognizer],
                  !definition.needsSwiftLogic, Self.isSupported(table)
            else { continue }
            covered += 1
            let outcome = Self.run(table: table, definition: definition)
            total.passed += outcome.passed
            total.failed += outcome.failed
            if !outcome.details.isEmpty && total.details.count < 40 {
                total.details.append(table.recognizer)
                total.details.append(contentsOf: outcome.details)
            }
        }

        #expect(covered >= 25, "only \(covered) pure-pattern tables found")
        #expect(
            total.failed == 0,
            """
            \(total.failed)/\(total.passed + total.failed) pure-pattern cases failed:
            \(total.details.joined(separator: "\n"))
            """
        )
    }

    /// Recognizers whose checksum logic is implemented in `ValidatorRegistry`.
    @Test("recognizers with implemented validators match upstream exactly")
    func implementedValidatorRecognizers() throws {
        let corpus = try Corpus.recognizerCases()
        var total = Outcome()
        var covered: [String] = []

        for table in corpus.tables {
            guard let definition = Self.definitions[table.recognizer],
                  definition.needsSwiftLogic, Self.isSupported(table),
                  (ValidatorRegistry.logic(for: table.recognizer, fixture: table.fixture)
                    ?? nil) != nil
            else { continue }
            covered.append(table.recognizer)
            let outcome = Self.run(table: table, definition: definition)
            total.passed += outcome.passed
            total.failed += outcome.failed
            if !outcome.details.isEmpty && total.details.count < 40 {
                total.details.append(table.recognizer)
                total.details.append(contentsOf: outcome.details)
            }
        }

        #expect(!covered.isEmpty, "no implemented validators exercised")
        #expect(
            total.failed == 0,
            """
            \(total.failed)/\(total.passed + total.failed) cases failed for \
            \(covered.sorted().joined(separator: ", ")):
            \(total.details.joined(separator: "\n"))
            """
        )
    }

    /// Measures — and therefore makes impossible to ignore — how much of the
    /// corpus is still blocked on unimplemented checksum logic.
    @Test("unimplemented validator coverage is tracked")
    func unimplementedCoverageIsVisible() throws {
        let corpus = try Corpus.recognizerCases()
        var blockedCases = 0
        var blockedRecognizers = Set<String>()
        var totalCases = 0

        for table in corpus.tables {
            totalCases += table.cases.count
            guard let definition = Self.definitions[table.recognizer] else { continue }
            if definition.needsSwiftLogic,
               (ValidatorRegistry.logic(for: table.recognizer, fixture: table.fixture)
                 ?? nil) == nil {
                blockedCases += table.cases.count
                blockedRecognizers.insert(table.recognizer)
            }
        }

        // Ratchet: this must go DOWN as validators land. If it rises, either a
        // validator was removed or the corpus grew in an unhandled area.
        // Currently 48/1654 (3%), across 5 recognizers that each need
        // something beyond a checksum: a public suffix list (Email), SHA-256 +
        // base58 + bech32 (Crypto), large state/district tables
        // (InVehicleRegistration), or constants plus a current-date comparison
        // (SgUen, ZaCompanyRegistration).
        #expect(
            blockedCases <= 48,
            """
            \(blockedCases)/\(totalCases) cases blocked on \
            \(blockedRecognizers.count) unimplemented validators. \
            Lower this bound as validators land; it must never rise.
            """
        )
    }

    @Test("every catalogue recognizer either builds or is explained")
    func catalogueIsBuildable() throws {
        var unbuildable: [String] = []
        for definition in try Catalog.definitions() {
            if Catalog.makeRecognizer(definition) == nil {
                unbuildable.append("\(definition.class) (entity: \(definition.entity ?? "nil"))")
            }
        }
        #expect(
            unbuildable.isEmpty,
            "\(unbuildable.count) recognizers could not be built: \(unbuildable.prefix(10))"
        )
    }

    @Test("no recognizer silently loses patterns to a compile failure")
    func allPatternsCompileInEveryRecognizer() throws {
        var failures: [String] = []
        for definition in try Catalog.definitions() {
            guard let recognizer = Catalog.makeRecognizer(definition) else { continue }
            for failure in recognizer.compilationFailures {
                failures.append(
                    "\(definition.class)/\(failure.pattern.name): \(failure.reason)"
                )
            }
        }
        #expect(failures.isEmpty, "\(failures.count) patterns failed: \(failures.prefix(5))")
    }
}
