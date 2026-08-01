import Testing
import Foundation
import PresidioConformance
@testable import PresidioRecognizers

/// Differential test for the libphonenumber port, against `phonenumbers` itself.
///
/// `PhoneRecognizer` has no patterns of its own — it delegates entirely to
/// libphonenumber — so parity here is parity with Google's metadata plus its
/// algorithm, not with a regex.
///
/// This covers parse, validity and region resolution. The `PhoneNumberMatcher`
/// half — finding numbers embedded in free text at a given leniency — is not
/// ported yet, so the recognizer itself remains uncovered.
@Suite("libphonenumber parse parity")
struct PhoneNumberTests {

    struct Gold: Decodable {
        struct Case: Decodable {
            let region: String
            let text: String
            let parsed: Bool
            let countryCode: Int?
            let nationalNumber: String?
            let valid: Bool?
            let possible: Bool?
            let type: Int?
            let regionCode: String?

            enum CodingKeys: String, CodingKey {
                case region, text, parsed, valid, possible, type
                case countryCode = "country_code"
                case nationalNumber = "national_number"
                case regionCode = "region_code"
            }
        }
        let cases: [Case]
    }

    static let gold: Gold = {
        // swiftlint:disable:next force_try
        try! JSONDecoder().decode(Gold.self, from: Corpus.data(named: "phone_parse_gold"))
    }()

    @Test("metadata for all twelve configured regions is bundled")
    func metadataLoads() {
        #expect(PhoneNumberUtil.isMetadataLoaded)
        #expect(Set(PhoneNumberUtil.supportedRegions) == [
            "US", "GB", "DE", "FR", "IL", "IN", "CA", "BR", "JP", "CN", "PH", "TR",
        ])
    }

    /// Reported as measured agreement rather than asserted equality: the port is
    /// incomplete, and a bound that only ratchets upward is more honest than a
    /// test that pretends the remaining gap does not exist.
    @Test("parse and validity agree with phonenumbers")
    func parseAgreement() {
        var total = 0
        var parseAgree = 0, numberAgree = 0, validAgree = 0, regionAgree = 0
        var report: [String] = []

        for testCase in Self.gold.cases {
            total += 1
            let produced = try? PhoneNumberUtil.parse(
                testCase.text, defaultRegion: testCase.region
            )
            if (produced != nil) == testCase.parsed { parseAgree += 1 }
            guard let produced, testCase.parsed else { continue }

            let sameNumber = produced.countryCode == testCase.countryCode
                && produced.nationalNumber == testCase.nationalNumber
            if sameNumber { numberAgree += 1 }

            let valid = PhoneNumberUtil.isValid(produced)
            if valid == testCase.valid { validAgree += 1 }
            else if report.count < 10 {
                report.append("""
                    \(testCase.region) \(testCase.text.debugDescription): \
                    valid python=\(testCase.valid ?? false) swift=\(valid), \
                    nsn python=\(testCase.nationalNumber ?? "-") swift=\(produced.nationalNumber)
                    """)
            }

            if PhoneNumberUtil.regionCode(for: produced) == testCase.regionCode {
                regionAgree += 1
            }
        }

        let parsedCases = Self.gold.cases.filter(\.parsed).count
        print("""
            phone parse agreement over \(total) cases:
              parse/reject \(parseAgree)/\(total)
              nsn          \(numberAgree)/\(parsedCases)
              validity     \(validAgree)/\(parsedCases)
              region       \(regionAgree)/\(parsedCases)
            \(report.joined(separator: "\n"))
            """)

        // Bounds record where the port actually is, measured rather than
        // aspirational. Raise them as it improves; they must never fall.
        //
        // Current: parse/reject 479/480 (99.8%), NSN 400/432 (92.6%),
        // validity 423/432 (97.9%), region 294/432 (68.1%).
        //
        // Region resolution is the weakest link and the next thing to fix — it
        // decides which region's patterns a number is validated against, so the
        // other three cannot get far ahead of it.
        #expect(total >= 400)
        #expect(Double(parseAgree) / Double(total) >= 0.99)
        #expect(Double(numberAgree) / Double(parsedCases) >= 0.92)
        #expect(Double(validAgree) / Double(parsedCases) >= 0.97)
        #expect(Double(regionAgree) / Double(parsedCases) >= 0.68)
    }
}
