import Testing
import Foundation
import PresidioConformance
@testable import PresidioRecognizers

/// Differential test for the `PhoneNumberMatcher` port.
///
/// This is the half `PhoneRecognizer` actually calls — finding numbers embedded
/// in free text — and the half no Swift phone library provides.
@Suite("libphonenumber matcher parity")
struct PhoneMatcherTests {

    struct Gold: Decodable {
        struct Case: Decodable {
            struct M: Decodable { let start: Int; let end: Int; let raw: String }
            let region: String
            let text: String
            let leniency: Int
            let matches: [M]
        }
        let cases: [Case]
    }

    static let gold: Gold = {
        // swiftlint:disable:next force_try
        try! JSONDecoder().decode(Gold.self, from: Corpus.data(named: "phone_matcher_gold"))
    }()

    @Test("the matcher's patterns compiled")
    func matcherReady() {
        #expect(PhoneNumberMatcher.isReady)
    }

    @Test("matches agree with libphonenumber")
    func matchesAgree() {
        var exact = 0
        var total = 0
        var spanAgree = 0, spanTotal = 0
        var report: [String] = []

        for testCase in Self.gold.cases {
            total += 1
            let matcher = PhoneNumberMatcher(
                text: testCase.text,
                region: testCase.region,
                leniency: PhoneLeniency(rawValue: testCase.leniency) ?? .valid
            )
            let produced = matcher.matches()
            let got = Set(produced.map { "\($0.start)..<\($0.end)" })
            let want = Set(testCase.matches.map { "\($0.start)..<\($0.end)" })

            spanTotal += want.count
            spanAgree += got.intersection(want).count
            if got == want {
                exact += 1
            } else if report.count < 12 {
                report.append("""
                    \(testCase.region) L\(testCase.leniency) \(testCase.text.prefix(60).debugDescription)
                      python \(want.sorted())
                      swift  \(got.sorted())
                    """)
            }
        }

        print("""
            matcher agreement:
              exact case agreement \(exact)/\(total)
              span recall          \(spanAgree)/\(spanTotal)
            \(report.joined(separator: "\n"))
            """)

        #expect(total >= 600)
        // Measured bounds; raise as the port improves, never lower.
        // 623/624: the one holdout is a leniency-0 timestamp, "2012-01-02
        // 08:00", where the inner-match fallback accepts "00" as a *possible*
        // number. Presidio always uses leniency 1.
        #expect(exact >= 623, "\(exact)/\(total)")
        #expect(spanAgree == spanTotal, "span recall \(spanAgree)/\(spanTotal)")
    }
}

/// The recognizer itself, against its own corpus cases.
@Suite("PhoneRecognizer conformance")
struct PhoneRecognizerTests {

    @Test("PhoneRecognizer cases from the harvested corpus")
    func corpusCases() throws {
        let corpus = try Corpus.recognizerCases()
        let tables = corpus.tables.filter { $0.recognizer == "PhoneRecognizer" }
        #expect(tables.count >= 3)

        var passed = 0, failed = 0
        var report: [String] = []

        // The corpus records which pytest fixture built the recognizer but not
        // its constructor arguments, and these tables configure it per region:
        // the PH suite passes supported_regions=["PH"], the TR suite ["TR"].
        // Running them against the default eight regions matches PH national
        // numbers as US ones and inverts the negative cases.
        func recognizer(for file: String, leniency: PhoneLeniency) -> PhoneRecognizer {
            if file.contains("ph_mobile_number") {
                return PhoneRecognizer(
                    entity: "PH_MOBILE_NUMBER", regions: ["PH"], leniency: leniency
                )
            }
            if file.contains("tr_phone_number") {
                return PhoneRecognizer(
                    entity: "TR_PHONE_NUMBER", regions: ["TR"], leniency: leniency
                )
            }
            // test_phone_recognizer.py's fixture is
            // DEFAULT_SUPPORTED_REGIONS + ("JP", "CN").
            return PhoneRecognizer(
                regions: PhoneRecognizer.defaultRegions + ["JP", "CN"],
                leniency: leniency
            )
        }

        for table in tables {
            for testCase in table.cases {
                // A row may carry its own leniency; upstream's leniency table
                // repeats the same text with different values and opposite
                // expectations, so this cannot be a per-table setting.
                let recognizer = recognizer(
                    for: table.file,
                    leniency: testCase.leniency.flatMap(PhoneLeniency.init(rawValue:))
                        ?? .valid
                )
                let got = recognizer.analyze(testCase.text).sortedByStart()
                if got.count == testCase.expectedCount { passed += 1 }
                else {
                    failed += 1
                    if report.count < 8 {
                        report.append(
                            "L\(testCase.leniency ?? 1) "
                            + "\(testCase.text.suffix(28).debugDescription) "
                            + "expected \(testCase.expectedCount), got \(got.count)"
                        )
                    }
                }
            }
        }
        print("""
            PhoneRecognizer (default config) over its corpus:
              count agreement \(passed)/\(passed + failed)
            \(report.joined(separator: "\n"))
            """)
        #expect(passed + failed >= 100)
        // 98/106. The eight remaining are the leniency table, where the
        // expected count varies with a `leniency` column that the corpus does
        // not carry — the same fixture-variant limitation as DE_VAT_ID, except
        // here the variant is per row rather than per table. STRICT_GROUPING
        // and EXACT_GROUPING are also not implemented and fall back to VALID.
        // 102/106. Each holdout has a named cause:
        //   L1 "…91-415-555-0132"   country code written without a leading '+'
        //   L1 "…+39 06 678 4343"   Italian metadata not bundled
        //   L1 "…+30 21 0 1234567"  Greek metadata not bundled
        //   L3 "…+91 4155 550132"   EXACT_GROUPING, which falls back to VALID
        #expect(passed >= 102, "\(passed)/\(passed + failed)")
    }
}

/// The two South African line-type recognizers, against their corpus tables.
///
/// These share PhoneRecognizer's matcher but split its results by line type, so
/// what is really under test here is the classifier: `number_type` from the
/// metadata, with a digit-prefix fallback when the metadata says UNKNOWN.
@Suite("ZA phone recognizer conformance")
struct ZaPhoneRecognizerTests {

    @Test("ZA mobile and telephone cases from the harvested corpus")
    func corpusCases() throws {
        let corpus = try Corpus.recognizerCases()
        var passed = 0, failed = 0
        var report: [String] = []

        for table in corpus.tables {
            guard let recognizer = CustomRecognizerRegistry.make(table.recognizer),
                  table.recognizer.hasPrefix("Za")
            else { continue }
            for testCase in table.cases {
                let got = recognizer.analyze(testCase.text).sortedByStart()
                var problem: String?
                if got.count != testCase.expectedCount {
                    problem = "expected \(testCase.expectedCount), got \(got.count)"
                } else if testCase.spansEnumerated {
                    for (result, expected) in zip(got, testCase.expected)
                    where result.start != expected.start || result.end != expected.end {
                        problem = "span \(result.start)..<\(result.end), "
                            + "expected \(expected.start)..<\(expected.end)"
                        break
                    }
                }
                if let problem {
                    failed += 1
                    if report.count < 8 {
                        report.append(
                            "\(table.recognizer): "
                            + "\(testCase.text.prefix(50).debugDescription) \(problem)"
                        )
                    }
                } else {
                    passed += 1
                }
            }
        }

        print("""
            ZA line-type recognizers over their corpus:
              agreement \(passed)/\(passed + failed)
            \(report.joined(separator: "\n"))
            """)
        #expect(passed + failed == 28, "expected both ZA tables")
        #expect(failed == 0, "\(report.joined(separator: "\n"))")
    }

    /// The prefix fallback is only reached when the metadata cannot type the
    /// number, and its ordering is load-bearing: 086 and 087 are telephone
    /// lines that would be called mobile by the bare "starts with 8" rule.
    @Test("the NSN prefix fallback keeps upstream's rule order")
    func prefixFallbackOrder() {
        typealias R = ZaPhoneNumberRecognizer
        #expect(R.classifyByNSNPrefix("821234567") == .mobile)
        #expect(R.classifyByNSNPrefix("801234567") == .telephone)
        #expect(R.classifyByNSNPrefix("861234567") == .telephone)
        #expect(R.classifyByNSNPrefix("871234567") == .telephone)
        #expect(R.classifyByNSNPrefix("711234567") == .mobile)
        #expect(R.classifyByNSNPrefix("211234567") == .telephone)
        #expect(R.classifyByNSNPrefix("011234567") == nil)
        #expect(R.classifyByNSNPrefix("") == nil)
    }
}
