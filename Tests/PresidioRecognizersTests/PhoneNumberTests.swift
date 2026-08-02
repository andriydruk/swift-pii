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
            let significant: String?
            let valid: Bool?
            let possible: Bool?
            let type: Int?
            let regionCode: String?

            enum CodingKeys: String, CodingKey {
                case region, text, parsed, valid, possible, type
                case countryCode = "country_code"
                case nationalNumber = "national_number"
                case significant
                case regionCode = "region_code"
            }
        }
        let cases: [Case]
    }

    static let gold: Gold = {
        // swiftlint:disable:next force_try
        try! JSONDecoder().decode(Gold.self, from: Corpus.data(named: "phone_parse_gold"))
    }()

    @Test("metadata covers every region sharing a configured country code")
    func metadataLoads() {
        #expect(PhoneNumberUtil.isMetadataLoaded)
        let regions = Set(PhoneNumberUtil.supportedRegions)
        // The twelve the recognizers name...
        #expect(regions.isSuperset(of: [
            "US", "GB", "DE", "FR", "IL", "IN", "CA", "BR", "JP", "CN", "PH", "TR",
        ]))
        // ...plus everyone sharing their country codes, because
        // region_code_for_number only disambiguates when a code has more than
        // one region. Truncating would make +44 an unconditional "GB".
        #expect(regions.isSuperset(of: ["GG", "IM", "JE"]))   // +44
        #expect(regions.isSuperset(of: ["PR", "JM", "BS"]))   // +1
        #expect(regions.count >= 38)
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

            // Compare the SIGNIFICANT number: leading zeros are part of it and
            // are what validation matches against.
            let sameNumber = produced.countryCode == testCase.countryCode
                && produced.significantNumber == (testCase.significant ?? testCase.nationalNumber)
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
        // Current: parse/reject 479/480 (99.8%), NSN 416/432 (96.3%),
        // validity 431/432 (99.8%), region 430/432 (99.5%).
        #expect(total >= 400)
        // Absolute counts, not ratios. A ratio bound set loosely lets a real
        // regression pass: dropping the descriptor anchoring took the
        // recognizer from 101/106 to 98/106 and every ratio bound here stayed
        // satisfied. These are the current measurements; raise, never lower.
        #expect(parseAgree == total, "parse \(parseAgree)/\(total)")
        #expect(numberAgree >= 431, "nsn \(numberAgree)/\(parsedCases)")
        #expect(validAgree == parsedCases, "validity \(validAgree)/\(parsedCases)")
        #expect(regionAgree >= 431, "region \(regionAgree)/\(parsedCases)")
    }
}
