import Testing
import Foundation
import PresidioConformance
@testable import PresidioRecognizers
import PresidioAnalyzer
import PresidioCore

/// Upstream tables for the static helpers recognizers are built from.
///
/// Four functions, harvested rather than transcribed: `sanitize_value` (which
/// every checksum validator runs first), Aadhaar's palindrome and Verhoeff
/// checks, and South Africa's number-prefix classifier.
///
/// The palindrome table is the reason this suite found something. Upstream's
/// `_is_palindrome` takes an optional second argument; the port had a
/// one-argument version, which is behaviourally sufficient for the only caller
/// (Aadhaar numbers are digits) and wrong as a port. Two of the five rows
/// exercise the argument that did not exist.
@Suite("harvested function tables")
struct OperationFunctionTests {

    static let corpus: OperationCorpus = {
        // swiftlint:disable:next force_try
        try! Corpus.operationCases()
    }()

    @Test("every harvested function case matches upstream")
    func functionsMatch() throws {
        var checked = 0
        var unknown: Set<String> = []

        for testCase in Self.corpus.functions {
            switch testCase.function {
            case "EntityRecognizer.sanitize_value":
                guard testCase.args.count == 2,
                      let text = testCase.args[0].asString,
                      let pairs = testCase.args[1].asReplacementPairs,
                      let expected = testCase.expected.asString
                else { Issue.record("bad row in \(testCase.test)"); continue }
                #expect(
                    Checksums.sanitize(text, replacing: pairs) == expected,
                    "sanitize(\(text.debugDescription)) in \(testCase.test)"
                )

            case "InAadhaarRecognizer._is_palindrome":
                guard testCase.args.count == 2,
                      let text = testCase.args[0].asString,
                      let caseInsensitive = testCase.args[1].asBool,
                      let expected = testCase.expected.asBool
                else { Issue.record("bad row in \(testCase.test)"); continue }
                #expect(
                    Checksums.isPalindrome(text, caseInsensitive: caseInsensitive)
                        == expected,
                    "isPalindrome(\(text.debugDescription), \(caseInsensitive))"
                )

            case "InAadhaarRecognizer._is_verhoeff_number":
                // Upstream takes an int; the port takes digits, because a Swift
                // `Int` would overflow on a long enough identifier and the
                // callers all have a string in hand anyway.
                guard testCase.args.count == 1,
                      let number = testCase.args[0].asInt,
                      let expected = testCase.expected.asBool,
                      let digits = Checksums.digitValues(String(number))
                else { Issue.record("bad row in \(testCase.test)"); continue }
                #expect(
                    Checksums.verhoeff(digits) == expected,
                    "verhoeff(\(number))"
                )

            case "ZaPhoneNumberRecognizer._classify_by_nsn_prefix":
                guard testCase.args.count == 1,
                      let nsn = testCase.args[0].asString
                else { Issue.record("bad row in \(testCase.test)"); continue }
                // The Swift enum has no raw value — it is a domain type, not a
                // wire format — so the upstream strings are mapped here rather
                // than a `String` raw value being added to satisfy a test.
                let got: String? = {
                    switch ZaPhoneNumberRecognizer.classifyByNSNPrefix(nsn) {
                    case .mobile: return "mobile"
                    case .telephone: return "telephone"
                    case nil: return nil
                    }
                }()
                let expected = testCase.expected.asString
                #expect(
                    got == expected,
                    """
                    classifyByNSNPrefix(\(nsn)): upstream \(expected ?? "nil"), \
                    swift \(got ?? "nil")
                    """
                )

            default:
                unknown.insert(testCase.function)
                continue
            }
            checked += 1
        }

        print("Function parity: \(checked)/\(Self.corpus.functions.count) cases run")
        #expect(
            unknown.isEmpty,
            """
            harvested functions with no Swift counterpart wired up: \
            \(unknown.sorted())
            """
        )
        #expect(checked == Self.corpus.functions.count)
    }

    /// `remove_duplicates`, which is what the span predicates feed.
    ///
    /// Worth harvesting separately from the predicates because its behaviour does
    /// not follow from theirs: it dedupes on equality, sorts by a key that omits
    /// the entity type, drops zero scores, and only then removes anything
    /// contained in a survivor *of the same type*. The third table is the one
    /// that pins that last qualifier — two identical-scoring spans where one
    /// contains the other collapse to one, while the second table's pair with
    /// different entity types does not.
    @Test("remove_duplicates matches upstream")
    func pipelinesMatch() throws {
        #expect(!Self.corpus.pipelines.isEmpty)
        for testCase in Self.corpus.pipelines {
            guard testCase.function == "EntityRecognizer.remove_duplicates" else {
                Issue.record("no Swift counterpart for \(testCase.function)")
                continue
            }
            let input = testCase.input.map {
                RecognizerResult(
                    entityType: $0.entityType, start: $0.start,
                    end: $0.end, score: $0.score
                )
            }
            let got = PatternRecognizer.removeDuplicates(input)
            #expect(
                got.count == testCase.expectedCount,
                """
                \(testCase.test): upstream kept \(testCase.expectedCount), \
                swift kept \(got.count) — \(got)
                """
            )
            for field in testCase.expectedFields {
                guard field.index < got.count else {
                    Issue.record("\(testCase.test): no result at \(field.index)")
                    continue
                }
                switch field.field {
                case "score":
                    #expect(
                        got[field.index].score == field.value.asDouble,
                        "\(testCase.test): score at \(field.index)"
                    )
                case "start":
                    #expect(got[field.index].start == field.value.asInt)
                case "end":
                    #expect(got[field.index].end == field.value.asInt)
                case "entity_type":
                    #expect(got[field.index].entityType == field.value.asString)
                default:
                    Issue.record("unknown field '\(field.field)' in \(testCase.test)")
                }
            }
        }
        print("Pipeline parity: \(Self.corpus.pipelines.count) cases run")
    }

    /// The one row that would have passed against the old one-argument
    /// `isPalindrome` by accident, called out so the reason the parameter exists
    /// does not get optimised away again.
    @Test("the case-insensitive palindrome argument is load-bearing")
    func caseInsensitiveArgumentMatters() {
        #expect(Checksums.isPalindrome("aBba") == false)
        #expect(Checksums.isPalindrome("aBba", caseInsensitive: true))
        // It strips spaces too, which its name does not say. A trailing space
        // is the cheapest demonstration: "abba " reverses to " abba".
        #expect(Checksums.isPalindrome("abba ") == false)
        #expect(Checksums.isPalindrome("abba ", caseInsensitive: true))
    }
}
