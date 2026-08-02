import Testing
import PresidioConformance
import PresidioAnalyzer
@testable import PresidioRecognizers

/// Every checksum validator against deliberately hostile input.
///
/// Upstream's own tables are ASCII and well-formed: they check the arithmetic,
/// not the edges. The edges are where a port drifts — `str.isdigit()` and
/// `Character.isNumber` disagree outside Nd, `int()` and `wholeNumberValue`
/// accept different things, and `strip()` and Swift trimming remove different
/// spaces. This corpus feeds each validator non-ASCII digits, mixed case,
/// Unicode spaces and combining marks, and compares the tri-state.
@Suite("Validator stress")
struct ValidatorStressTests {

    @Test("validators agree with Python on adversarial input")
    func validatorsAgree() throws {
        let corpus = try Corpus.validatorStress()
        #expect(corpus.tables.count >= 15)

        var agreed = 0, total = 0
        var report: [String] = []
        var uncovered: [String] = []

        for table in corpus.tables {
            guard let logic = ValidatorRegistry.logic(for: table.recognizer).validate
            else { uncovered.append(table.recognizer); continue }

            for testCase in table.cases {
                total += 1
                let got: String
                switch logic(testCase.input) {
                case .valid: got = "valid"
                case .invalid: got = "invalid"
                case .unknown: got = "indeterminate"
                }
                if got == testCase.validate {
                    agreed += 1
                } else if report.count < 12 {
                    report.append(
                        "\(table.recognizer) \(testCase.input.debugDescription) "
                        + "python=\(testCase.validate) swift=\(got)"
                    )
                }
            }
        }

        print("""
            Validator stress: \(agreed)/\(total) agree
            \(report.joined(separator: "\n"))
            """)
        #expect(uncovered.isEmpty, "no Swift validator for \(uncovered)")
        #expect(total >= 2000)
        #expect(agreed == total, "\(report.joined(separator: "\n"))")
    }
}
