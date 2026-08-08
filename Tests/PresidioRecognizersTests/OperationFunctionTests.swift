import Testing
import Foundation
import PresidioConformance
@testable import PresidioRecognizers

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
