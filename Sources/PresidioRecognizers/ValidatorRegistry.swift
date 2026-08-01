import PresidioAnalyzer

/// Maps a recognizer class name to its checksum / invalidation logic.
///
/// This is the Swift answer to Python's `__subclasses__()` reflection: an
/// explicit table instead of runtime class discovery. Adding a recognizer means
/// adding a line here, which is the point — a missing validator is visible as
/// an absent key rather than as silently degraded detection.
///
/// Coverage is reported by `unimplemented(among:)` so the gap is measurable.
public enum ValidatorRegistry {

    /// Recognizers whose logic is implemented. Keys are Python class names.
    public static let table: [String: RecognizerLogic] = [
        "CreditCardRecognizer": RecognizerLogic(
            validate: { Checksums.luhn(digitsOf: $0) ? .valid : .invalid }
        ),
        "InAadhaarRecognizer": RecognizerLogic(
            validate: { text in
                // Upstream sanitizes with [("-",""),(" ",""),(":","")], then
                // requires: 12 digits, leading digit >= 2, Verhoeff passes, and
                // the number is NOT a palindrome.
                let sanitized = Checksums.sanitize(
                    text, replacing: [("-", ""), (" ", ""), (":", "")]
                )
                guard let digits = Checksums.digitValues(sanitized),
                      digits.count == 12,
                      digits[0] >= 2,
                      Checksums.verhoeff(digits),
                      !Checksums.isPalindrome(sanitized)
                else { return .invalid }
                return .valid
            }
        ),
        "UsSsnRecognizer": RecognizerLogic(
            invalidate: { text in
                // Mixed delimiters are rejected: "078-05.1123" is not an SSN.
                var delimiters = Set<Character>()
                for character in text where ".- ".contains(character) {
                    delimiters.insert(character)
                }
                if delimiters.count > 1 { return true }

                let digits = text.filter(\.isNumber)
                guard let first = digits.first else { return true }
                if digits.allSatisfy({ $0 == first }) { return true }

                let d = Array(digits)
                // Group number (positions 3..<5) and serial (5...) cannot be
                // all zeros.
                if d.count >= 5, String(d[3..<5]) == "00" { return true }
                if d.count > 5, String(d[5...]) == "0000" { return true }
                // 000 and 666 are area numbers the SSA never issued.
                if d.count >= 3, ["000", "666"].contains(String(d[0..<3])) { return true }
                // Placeholder SSNs published in official examples.
                if ["123456789", "987654320", "078051120"].contains(digits) { return true }
                return false
            }
        ),
        "CaSinRecognizer": RecognizerLogic(
            invalidate: { text in
                !Checksums.luhn(Checksums.digits(text))
            }
        ),
        "UuidRecognizer": RecognizerLogic(
            invalidate: { text in
                let lowered = text.lowercased()
                // The nil UUID is a sentinel, not an identifier.
                if lowered == "00000000-0000-0000-0000-000000000000" { return true }

                let groups = lowered.split(
                    separator: "-", omittingEmptySubsequences: false
                )
                guard groups.count == 5, groups.allSatisfy({ !$0.isEmpty })
                else { return true }

                // RFC 4122/9562 version nibble and variant bits, checked to cut
                // false positives from arbitrary hex-hyphen strings.
                guard let version = groups[2].first,
                      "12345678".contains(version) else { return true }
                guard let variant = groups[3].first,
                      "89ab".contains(variant) else { return true }
                return false
            }
        ),
        "IbanRecognizer": RecognizerLogic(validate: IbanValidator.validate),

        // Data-backed validators. See DataValidators.
        "EmailRecognizer": RecognizerLogic(validate: DataValidators.email),
        "CryptoRecognizer": RecognizerLogic(validate: DataValidators.crypto),
        "SgUenRecognizer": RecognizerLogic(validate: DataValidators.singaporeUen),
        "ZaCompanyRegistrationRecognizer": RecognizerLogic(
            validate: DataValidators.zaCompanyRegistration
        ),
        "InVehicleRegistrationRecognizer": RecognizerLogic(
            validate: DataValidators.indiaVehicleRegistration
        ),

        // Country-specific national IDs. See CountryValidators.
        "ThTninRecognizer": RecognizerLogic(validate: CountryValidators.thaiTnin),
        "FiPersonalIdentityCodeRecognizer": RecognizerLogic(
            validate: CountryValidators.finnishPersonalIdentityCode
        ),
        "TrNationalIdRecognizer": RecognizerLogic(
            validate: CountryValidators.turkishNationalId
        ),
        "TrLicensePlateRecognizer": RecognizerLogic(
            validate: CountryValidators.turkishLicensePlate
        ),
        "SePersonnummerRecognizer": RecognizerLogic(
            validate: CountryValidators.swedishPersonnummer
        ),
        "SeOrganisationsnummerRecognizer": RecognizerLogic(
            validate: CountryValidators.swedishOrganisationsnummer
        ),
        "KrRrnRecognizer": RecognizerLogic(validate: CountryValidators.koreanRrn),
        "KrFrnRecognizer": RecognizerLogic(validate: CountryValidators.koreanFrn),
        "AuAbnRecognizer": RecognizerLogic(validate: CountryValidators.australianAbn),
        "AuAcnRecognizer": RecognizerLogic(validate: CountryValidators.australianAcn),
        "AuTfnRecognizer": RecognizerLogic(validate: CountryValidators.australianTfn),
        "AuMedicareRecognizer": RecognizerLogic(
            validate: CountryValidators.australianMedicare
        ),
        "EsNieRecognizer": RecognizerLogic(validate: CountryValidators.spanishNie),
        "EsNifRecognizer": RecognizerLogic(validate: CountryValidators.spanishNif),
        "ItVatCodeRecognizer": RecognizerLogic(
            validate: CountryValidators.italianVatCode
        ),
        "ItFiscalCodeRecognizer": RecognizerLogic(
            validate: CountryValidators.italianFiscalCode
        ),
        "UkVehicleRegistrationRecognizer": RecognizerLogic(
            validate: CountryValidators.ukVehicleRegistration
        ),
        "UkDrivingLicenceRecognizer": RecognizerLogic(
            validate: CountryValidators.ukDrivingLicence
        ),
        "DeBsnrRecognizer": RecognizerLogic(validate: CountryValidators.germanBsnr),
        "NgNinRecognizer": RecognizerLogic(validate: CountryValidators.nigerianNin),
        "DeIdCardRecognizer": RecognizerLogic(validate: CountryValidators.germanIdCard),
        "DeTaxIdRecognizer": RecognizerLogic(validate: CountryValidators.germanTaxId),
        "DeVatIdRecognizer": RecognizerLogic(
            // Default (heuristic) mode: a checksum failure is indeterminate,
            // because the BZSt never published the algorithm officially.
            validate: { CountryValidators.germanVatId($0, strict: false) }
        ),
        "DeLanrRecognizer": RecognizerLogic(validate: CountryValidators.germanLanr),
        "DeHealthInsuranceRecognizer": RecognizerLogic(
            validate: CountryValidators.germanHealthInsurance
        ),
        "DeSocialSecurityRecognizer": RecognizerLogic(
            validate: CountryValidators.germanSocialSecurity
        ),
        "DePassportRecognizer": RecognizerLogic(
            validate: CountryValidators.germanPassport
        ),
        "KrBrnRecognizer": RecognizerLogic(validate: CountryValidators.koreanBrn),
        "KrDriverLicenseRecognizer": RecognizerLogic(
            validate: CountryValidators.koreanDriverLicense
        ),
        "ZaLicensePlateRecognizer": RecognizerLogic(
            validate: CountryValidators.zaLicensePlate
        ),
        "ZaPassportRecognizer": RecognizerLogic(validate: CountryValidators.zaPassport),
        "ZaVatNumberRecognizer": RecognizerLogic(
            validate: CountryValidators.zaVatNumber
        ),
        "ZaIncomeTaxNumberRecognizer": RecognizerLogic(
            validate: CountryValidators.zaIncomeTaxNumber
        ),
        "ZaDriverLicenseRecognizer": RecognizerLogic(
            validate: CountryValidators.zaDriverLicense
        ),
        "ZaIdNumberRecognizer": RecognizerLogic(validate: CountryValidators.zaIdNumber),
        "ZaTrafficRegisterNumberRecognizer": RecognizerLogic(
            validate: CountryValidators.zaTrafficRegisterNumber
        ),
        "InGstinRecognizer": RecognizerLogic(validate: CountryValidators.indianGstin),
        "PhTinRecognizer": RecognizerLogic(
            invalidate: { !CountryValidators.philippineTin($0) }
        ),
        "IpRecognizer": RecognizerLogic(invalidate: IpValidator.invalidate),
        "MacAddressRecognizer": RecognizerLogic(
            invalidate: { text in
                let cleaned = Checksums.sanitize(
                    text, replacing: [(":", ""), ("-", ""), (".", "")]
                )
                guard cleaned.count == 12,
                      cleaned.allSatisfy({ $0.isHexDigit && $0.isASCII })
                else { return true }
                // Broadcast and all-zero are structurally valid but carry no
                // identifying information.
                let upper = cleaned.uppercased()
                return upper == "FFFFFFFFFFFF" || upper == "000000000000"
            }
        ),
        "NhsRecognizer": RecognizerLogic(
            validate: { text in
                let sanitized = Checksums.sanitize(
                    text, replacing: [("-", ""), (" ", "")]
                )
                guard let digits = Checksums.digitValues(sanitized),
                      Checksums.nhs(digits)
                else { return .invalid }
                return .valid
            }
        ),
        "AbaRoutingRecognizer": RecognizerLogic(
            validate: { text in
                let sanitized = Checksums.sanitize(text, replacing: [("-", "")])
                guard let digits = Checksums.digitValues(sanitized),
                      Checksums.abaRouting(digits)
                else { return .invalid }
                return .valid
            }
        ),
        "UsNpiRecognizer": RecognizerLogic(
            validate: { text in
                let sanitized = Checksums.sanitize(
                    text, replacing: [("-", ""), (" ", "")]
                )
                guard let digits = Checksums.digitValues(sanitized),
                      Checksums.usNpi(digits)
                else { return .invalid }
                return .valid
            },
            invalidate: { text in
                // A body of identical digits (e.g. 1111111111) is rejected even
                // if the checksum happens to pass.
                let sanitized = Checksums.sanitize(
                    text, replacing: [("-", ""), (" ", "")]
                )
                guard !sanitized.isEmpty else { return false }
                let body = sanitized.count > 1 ? String(sanitized.dropLast()) : sanitized
                return !body.isEmpty && Set(body).count == 1
            }
        ),
        "MedicalLicenseRecognizer": RecognizerLogic(
            validate: { text in
                let sanitized = Checksums.sanitize(
                    text, replacing: [("-", ""), (" ", "")]
                )
                return Checksums.medicalLicense(sanitized) ? .valid : .invalid
            }
        ),
        "PlPeselRecognizer": RecognizerLogic(
            validate: { text in
                // Upstream requires exactly 11 characters, all digits — it does
                // not sanitize first.
                guard let digits = Checksums.digitValues(text),
                      Checksums.pesel(digits)
                else { return .invalid }
                return .valid
            }
        ),
    ]

    /// Fixture names that construct the recognizer with default arguments, and
    /// are therefore equivalent to `recognizer`.
    ///
    /// Verified by reading the fixtures: `cc_recognizer` is a bare
    /// `CreditCardRecognizer()` / `MedicalLicenseRecognizer()`.
    public static let defaultEquivalentFixtures: Set<String> = [
        "recognizer", "cc_recognizer",
    ]

    /// Logic for non-default constructions, keyed `"Class#fixture"`.
    ///
    /// A table whose fixture is neither default-equivalent nor listed here is
    /// reported as uncovered rather than run against the default logic — which
    /// would fail for the wrong reason and hide the real gap.
    public static let variants: [String: RecognizerLogic] = [
        "DeVatIdRecognizer#strict_recognizer": RecognizerLogic(
            validate: { CountryValidators.germanVatId($0, strict: true) }
        )
    ]

    /// Logic for a table, or nil when the fixture variant is unsupported.
    public static func logic(
        for className: String, fixture: String
    ) -> RecognizerLogic?? {
        if defaultEquivalentFixtures.contains(fixture) {
            return .some(table[className])
        }
        if let variant = variants["\(className)#\(fixture)"] {
            return .some(.some(variant))
        }
        return nil
    }

    /// Recognizers that derive candidate spans differently from the default.
    ///
    /// Only IbanRecognizer overrides `analyze` in a way the data model can
    /// express: it walks capture groups in reverse to shed trailing text that
    /// would otherwise break the checksum.
    public static let strategies: [String: MatchStrategy] = [
        "IbanRecognizer": .shortestValidGroupPrefix
    ]

    public static func strategy(for className: String) -> MatchStrategy {
        strategies[className] ?? .wholeMatch
    }

    public static func logic(for className: String) -> RecognizerLogic {
        table[className] ?? RecognizerLogic()
    }

    /// Class names that declare logic upstream but have no implementation here.
    ///
    /// Used by the conformance tests to partition expected failures from real
    /// ones, so an unimplemented validator never masquerades as a passing test.
    public static func unimplemented(among names: some Sequence<String>) -> [String] {
        names.filter { table[$0] == nil }.sorted()
    }
}
