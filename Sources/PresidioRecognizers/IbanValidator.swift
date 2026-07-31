import Foundation
import PresidioAnalyzer
import PresidioRegex

/// IBAN validation: ISO 7064 mod-97 checksum plus a per-country format regex.
///
/// Ported from `IbanRecognizer.validate_result`. The tri-state matters here
/// more than anywhere else in the catalogue:
///
/// - checksum passes **and** the country format matches → `.valid` (score 1.0)
/// - checksum passes but the format only matches once upper-cased → `.unknown`,
///   so the match survives at its pattern score instead of being discarded
/// - anything else → `.invalid`
///
/// That middle arm is why a lowercase-but-well-formed IBAN is kept as a weak
/// hit rather than dropped.
public enum IbanValidator {

    struct CountryTable: Decodable {
        let bos: String
        let eos: String
        let countries: [String: String]
    }

    /// Compiled per-country format regexes, keyed by ISO country code.
    ///
    /// Compiled once and reused; `PureRegex` is not `Sendable`, so this is
    /// guarded by the load being a single immutable initialization.
    private static let table: (bos: String, eos: String, countries: [String: String]) = {
        guard let url = Bundle.module.url(
            forResource: "iban_countries", withExtension: "json"
        ),
        let data = try? Data(contentsOf: url),
        let decoded = try? JSONDecoder().decode(CountryTable.self, from: data)
        else { return ("^", "$", [:]) }
        return (decoded.bos, decoded.eos, decoded.countries)
    }()

    public static var countryCount: Int { table.countries.count }

    /// A→10 … Z→35, digits unchanged — the ISO 13616 letter substitution.
    private static func numericized(_ iban: String) -> String? {
        var out = ""
        out.reserveCapacity(iban.count * 2)
        for character in iban {
            if character.isASCII, character.isNumber {
                out.append(character)
            } else if character.isASCII, character.isLetter {
                guard let ascii = character.uppercased().unicodeScalars.first?.value,
                      ascii >= 65, ascii <= 90
                else { return nil }
                out += String(ascii - 65 + 10)
            } else {
                return nil  // Python's str.translate would leave this in place,
                            // and int() would then raise ValueError -> False.
            }
        }
        return out
    }

    /// `98 - (numeric mod 97)`, zero-padded to two digits.
    ///
    /// The numeric form is up to ~70 digits, well past `UInt64`, so the modulus
    /// is taken digit by digit.
    static func checkDigits(for iban: String) -> String? {
        // Python: (iban[:2] + "00" + iban[4:]).upper(), then move the first
        // four characters to the end before numericizing.
        let chars = Array(iban)
        guard chars.count >= 4 else { return nil }
        let transformed = (String(chars[0..<2]) + "00" + String(chars[4...])).uppercased()

        let rearranged = String(Array(transformed)[4...]) + String(Array(transformed)[0..<4])
        guard let numeric = numericized(rearranged) else { return nil }

        var remainder = 0
        for character in numeric {
            guard let digit = character.wholeNumberValue else { return nil }
            remainder = (remainder * 10 + digit) % 97
        }
        return String(format: "%02d", 98 - remainder)
    }

    /// Does the sanitized IBAN match its country's format regex?
    ///
    /// **Prefix match, not a full match.** `IbanRecognizer.__init__` sets
    /// `self.BOSEOS = bos_eos if exact_match else ()`, and `exact_match`
    /// defaults to `False` — so `__is_valid_format` does *not* wrap the country
    /// regex in `^...$`, and `re.match` anchors only at the start.
    ///
    /// This is load-bearing, not pedantry: several country regexes in
    /// `iban_patterns.py` are shorter than the IBAN they describe (MU covers 28
    /// of 30 characters, PS and PT likewise). Anchoring the end rejects the very
    /// IBANs upstream accepts.
    static func matchesCountryFormat(_ iban: String) -> Bool {
        guard iban.count >= 2 else { return false }
        let code = String(iban.prefix(2)).uppercased()
        guard let countryRegex = table.countries[code], !countryRegex.isEmpty
        else { return false }

        guard let regex = try? PureRegex(
            countryRegex, ignoreCase: false, dotAll: true, multiline: true
        ) else { return false }

        // re.match semantics: must match starting at offset 0; the end is free.
        return regex.matches(in: iban).contains { $0.0 == 0 }
    }

    public static func validate(_ text: String) -> Validation {
        let sanitized = Checksums.sanitize(text, replacing: [("-", ""), (" ", "")])
        guard sanitized.count >= 4,
              let expected = checkDigits(for: sanitized)
        else { return .invalid }

        let actual = String(Array(sanitized)[2..<4])
        guard expected == actual else { return .invalid }

        if matchesCountryFormat(sanitized) { return .valid }
        if matchesCountryFormat(sanitized.uppercased()) { return .unknown }
        return .invalid
    }
}
