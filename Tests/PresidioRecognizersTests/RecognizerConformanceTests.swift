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

        // Every recognizer that has extractable patterns now has its logic.
        // This is a hard zero, not a ratchet: a regression means a validator
        // was removed or upstream added a recognizer we have not handled.
        #expect(
            blockedCases == 0,
            """
            \(blockedCases)/\(totalCases) cases blocked on \
            \(blockedRecognizers.count) unimplemented validators. \
            Lower this bound as validators land; it must never rise.
            """
        )
    }

    /// The data-backed validators fail *closed* when their bundled JSON does
    /// not decode — every one of them returns `.invalid`, which is
    /// indistinguishable from "nothing validates". That is exactly what
    /// happened when the extractor skipped `LEGACY_PREFIXES` (a `frozenset(...)`
    /// call rather than a literal): one missing key silently disabled five
    /// recognizers. This asserts the resource is really there.
    @Test("the bundled recognizer data decodes")
    func recognizerDataLoads() {
        #expect(
            DataValidators.isDataLoaded,
            "\(DataValidators.loadFailure ?? "unknown failure")"
        )
        // Spot-check each section, so a partially-empty payload is caught too.
        #expect(DataValidators.publicSuffixLength(["example", "site"]) == 1)
        #expect(DataValidators.publicSuffixLength(["example", "co", "uk"]) == 2)
        #expect(DataValidators.crypto("bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4") == .valid)
    }

    /// Recognizers whose patterns cannot be lifted into data at all, so they are
    /// not merely missing a validator. Reported rather than ignored.
    @Test("recognizers without extractable patterns are accounted for")
    func unextractableRecognizersAreVisible() throws {
        let corpus = try Corpus.recognizerCases()
        var missing: [String: Int] = [:]
        for table in corpus.tables where Self.definitions[table.recognizer] == nil {
            missing[table.recognizer, default: 0] += table.cases.count
        }
        // None of these is a checksum gap — they have no extractable patterns.
        // All three delegate to libphonenumber rather than declaring PATTERNS.
        // PhoneRecognizer is nonetheless implemented, via the custom-recognizer
        // path rather than the catalogue; see PhoneRecognizerTests.
        //
        // UrlRecognizer and UsMbiRecognizer were here until the extractor
        // learned to fold f-strings and `+` over class-level string constants;
        // their patterns were always liftable, just not spelled as literals.
        #expect(Set(missing.keys) == [
            "PhoneRecognizer", "ZaMobileNumberRecognizer", "ZaTelephoneNumberRecognizer",
        ])
        #expect(missing.values.reduce(0, +) <= 134)
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
