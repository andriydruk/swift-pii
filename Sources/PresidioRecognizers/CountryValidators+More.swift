import Foundation
import PresidioAnalyzer

extension CountryValidators {

    // MARK: - Germany
    //
    // DE_TAX_ID and DE_VAT_ID share the ISO 7064 Mod 11,10 engine. They differ
    // in length and, crucially, in what a failing checksum means: the tax ID
    // rejects, while the VAT ID defaults to heuristic mode and returns
    // "indeterminate" because the BZSt has never officially published the
    // algorithm.
    static func mod11_10(_ digits: [Int]) -> Int {
        var product = 10
        for digit in digits {
            var total = (digit + product) % 10
            if total == 0 { total = 10 }
            product = total * 2 % 11
        }
        var check = 11 - product
        if check == 10 { check = 0 }
        return check
    }

    public static func germanTaxId(_ text: String) -> Validation {
        guard let digits = Checksums.digitValues(text), digits.count == 11,
              digits[0] != 0
        else { return .invalid }
        // No digit may repeat more than three times in the first ten.
        var counts = [Int: Int]()
        for digit in digits.prefix(10) { counts[digit, default: 0] += 1 }
        guard (counts.values.max() ?? 0) <= 3 else { return .invalid }
        return mod11_10(Array(digits.prefix(10))) == digits[10] ? .valid : .invalid
    }

    /// `strictChecksum` mirrors upstream's constructor flag. In the default
    /// heuristic mode a structurally valid but checksum-failing VAT ID returns
    /// `.unknown`, so the match survives at its pattern score.
    public static func germanVatId(_ text: String, strict: Bool = false) -> Validation {
        let normalized = text.uppercased().filter { !" \t\n.-".contains($0) }
        guard normalized.count == 11, normalized.hasPrefix("DE") else { return .invalid }
        let body = String(normalized.dropFirst(2))
        guard let digits = Checksums.digitValues(body), digits.count == 9
        else { return .invalid }
        if mod11_10(Array(digits.prefix(8))) == digits[8] { return .valid }
        return strict ? .invalid : .unknown
    }

    public static func germanLanr(_ text: String) -> Validation {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let digits = Checksums.digitValues(trimmed), digits.count == 9
        else { return .invalid }
        let weights = [4, 9, 4, 9, 4, 9]
        let total = weightedSum(Array(digits.prefix(6)), weights)
        return (10 - total % 10) % 10 == digits[6] ? .valid : .invalid
    }

    public static func germanHealthInsurance(_ text: String) -> Validation {
        let value = Array(text.uppercased().trimmingCharacters(in: .whitespacesAndNewlines))
        guard value.count == 10, value[0].isLetter, value[0].isASCII,
              value.dropFirst().allSatisfy({ $0.isNumber && $0.isASCII })
        else { return .invalid }

        // The leading letter becomes its two-digit alphabet position.
        let letterValue = Int(value[0].asciiValue! - 64)
        let effective = String(format: "%02d", letterValue) + String(value[1..<9])
        guard let digits = Checksums.digitValues(effective),
              let check = value[9].wholeNumberValue
        else { return .invalid }

        let factors = [1, 2, 1, 2, 1, 2, 1, 2, 1, 2]
        var total = 0
        for (digit, factor) in zip(digits, factors) {
            var product = digit * factor
            if product >= 10 { product = product / 10 + product % 10 }
            total += product
        }
        return total % 10 == check ? .valid : .invalid
    }

    public static func germanSocialSecurity(_ text: String) -> Validation {
        let value = Array(text.uppercased().trimmingCharacters(in: .whitespacesAndNewlines))
        guard value.count == 12,
              value[0..<8].allSatisfy({ $0.isNumber && $0.isASCII }),
              value[8].isLetter, value[8].isASCII,
              value[9..<12].allSatisfy({ $0.isNumber && $0.isASCII })
        else { return .invalid }

        let day = Int(String(value[2..<4]))!
        let month = Int(String(value[4..<6]))!
        // 51-81 encodes a female birth day in the historical scheme.
        guard (1...31).contains(day) || (51...81).contains(day),
              (1...12).contains(month)
        else { return .invalid }

        let letterValue = Int(value[8].asciiValue! - 64)
        let effective = String(value[0..<8])
            + String(format: "%02d", letterValue)
            + String(value[9..<11])
        guard let digits = Checksums.digitValues(effective),
              let check = value[11].wholeNumberValue
        else { return .invalid }

        let weights = [2, 1, 2, 5, 7, 1, 2, 1, 2, 1, 2, 1]
        var total = 0
        for (digit, weight) in zip(digits, weights) {
            let product = digit * weight
            total += product / 10 + product % 10
        }
        return total % 10 == check ? .valid : .invalid
    }

    private static let germanPassportForbidden = Set("ABDEIOQSU")

    public static func germanPassport(_ text: String) -> Validation {
        let value = Array(text.uppercased().trimmingCharacters(in: .whitespacesAndNewlines))
        guard value.count == 9, value[8].isNumber else { return .invalid }
        // Letters that look like digits are excluded from the document number.
        guard !value.dropLast().contains(where: { germanPassportForbidden.contains($0) })
        else { return .invalid }

        let weights = [7, 3, 1]
        var total = 0
        for (index, character) in value.dropLast().enumerated() {
            let value: Int
            if character.isNumber, let d = character.wholeNumberValue {
                value = d
            } else if character.isASCII, character.isLetter,
                      let ascii = character.asciiValue, ascii >= 65, ascii <= 90 {
                value = Int(ascii - 65) + 10
            } else {
                return .invalid
            }
            total += value * weights[index % 3]
        }
        return total % 10 == value[8].wholeNumberValue! ? .valid : .invalid
    }

    // MARK: - Korea

    public static func koreanBrn(_ text: String) -> Validation {
        let sanitized = Checksums.sanitize(text, replacing: [("-", "")])
        guard let digits = Checksums.digitValues(sanitized), digits.count == 10
        else { return .invalid }
        let keys = [1, 3, 7, 1, 3, 7, 1, 3, 5]
        var total = weightedSum(Array(digits.prefix(8)), Array(keys.prefix(8)))
        // The ninth digit contributes both its product and that product's tens
        // digit — an unusual step, reproduced literally.
        let last = digits[8] * keys[8]
        total += last / 10 + last
        return (10 - total % 10) % 10 == digits[9] ? .valid : .invalid
    }

    private static let koreanLicenseRegions: Set<String> = [
        "11", "12", "13", "14", "15", "16", "17", "18", "19",
        "20", "21", "22", "23", "24", "25", "26", "28",
    ]

    public static func koreanDriverLicense(_ text: String) -> Validation {
        let sanitized = Checksums.sanitize(text, replacing: [("-", ""), (" ", "")])
        guard sanitized.count == 12,
              Checksums.digitValues(sanitized) != nil,
              koreanLicenseRegions.contains(String(sanitized.prefix(2)))
        else { return .invalid }
        return .valid
    }

    // MARK: - United Kingdom

    /// Only a structural check on the surname field; upstream returns `None`
    /// for anything that passes, so a licence never scores above its pattern.
    public static func ukDrivingLicence(_ text: String) -> Validation {
        let value = text.uppercased()
        guard value.count >= 5 else { return .invalid }
        let surname = String(value.prefix(5))
        if surname == "99999" { return .invalid }
        // `^[A-Z]+9*$`: letters, then optional padding nines.
        var seenNine = false
        var letters = 0
        for character in surname {
            if character == "9" {
                seenNine = true
            } else if character.isASCII, character.isLetter, !seenNine {
                letters += 1
            } else {
                return .invalid
            }
        }
        return letters >= 1 ? .unknown : .invalid
    }

    // MARK: - South Africa

    private static let zaProvinceSuffixes: Set<String> = [
        "GP", "ZN", "WP", "EC", "NC", "FS", "LP", "MP", "NW",
    ]

    public static func zaLicensePlate(_ text: String) -> Validation {
        let sanitized = Checksums.sanitize(
            text, replacing: [("-", ""), (" ", "")]
        ).uppercased()
        guard sanitized.count >= 5 else { return .invalid }
        let suffix = String(sanitized.suffix(2))
        guard zaProvinceSuffixes.contains(suffix) else { return .invalid }
        let body = sanitized.dropLast(2)
        guard !body.isEmpty, body.contains(where: \.isLetter) else { return .invalid }
        return .valid
    }

    public static func zaPassport(_ text: String) -> Validation {
        let value = text.uppercased()
        guard value.count == 9, let first = value.first,
              "ADMT".contains(first),
              Checksums.digitValues(String(value.dropFirst())) != nil
        else { return .invalid }
        return .valid
    }

    public static func zaVatNumber(_ text: String) -> Validation {
        guard text.count == 10, Checksums.digitValues(text) != nil,
              text.hasPrefix("4")
        else { return .invalid }
        return .valid
    }

    public static func zaIncomeTaxNumber(_ text: String) -> Validation {
        guard text.count == 10, Checksums.digitValues(text) != nil,
              let first = text.first, "01239".contains(first)
        else { return .invalid }
        return .valid
    }

    public static func zaDriverLicense(_ text: String) -> Validation {
        let value = Array(text.uppercased())
        guard (10...14).contains(value.count) else { return .invalid }
        // `\d{6,10}[A-Z0-9]{2,5}` with at least one letter overall.
        var digitRun = 0
        while digitRun < value.count, value[digitRun].isNumber { digitRun += 1 }
        guard (6...10).contains(digitRun) else { return .invalid }
        let tail = value[digitRun...]
        guard (2...5).contains(tail.count),
              tail.allSatisfy({ ($0.isLetter || $0.isNumber) && $0.isASCII })
        else { return .invalid }
        return value.contains(where: \.isLetter) ? .valid : .invalid
    }

    /// The birth-date check compares against *today*, so this validator is
    /// time-dependent by construction — a future-dated ID is rejected. That is
    /// upstream's behaviour (`date.today()`), reproduced rather than frozen.
    public static func zaIdNumber(_ text: String) -> Validation {
        guard let digits = Checksums.digitValues(text), digits.count == 13
        else { return .invalid }

        let yearSuffix = digits[0] * 10 + digits[1]
        let month = digits[2] * 10 + digits[3]
        let day = digits[4] * 10 + digits[5]

        let today = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let nowParts = calendar.dateComponents([.year, .month, .day], from: today)
        let currentYear = nowParts.year!
        let pivot = currentYear % 100
        let century = yearSuffix > pivot ? 1900 : 2000
        let year = century + yearSuffix

        guard isValidDate(year: year, month: month, day: day) else { return .invalid }
        // Birth date must not be in the future.
        let birth = (year, month, day)
        let now = (currentYear, nowParts.month!, nowParts.day!)
        if birth > now { return .invalid }

        guard "012".contains(String(digits[10])) else { return .invalid }
        guard "89".contains(String(digits[11])) else { return .invalid }

        // Luhn with parity keyed off the total length.
        let parity = digits.count % 2
        var checksum = 0
        for (index, digit) in digits.enumerated() {
            var d = digit
            if index % 2 == parity {
                d *= 2
                if d > 9 { d -= 9 }
            }
            checksum += d
        }
        return checksum % 10 == 0 ? .valid : .invalid
    }

    /// A traffic register number is deliberately the *complement* of an ID
    /// number: same shape, but must NOT be a valid ID.
    public static func zaTrafficRegisterNumber(_ text: String) -> Validation {
        guard text.count == 13, Checksums.digitValues(text) != nil
        else { return .invalid }
        return zaIdNumber(text) == .valid ? .invalid : .valid
    }

    // MARK: - India

    public static func indianGstin(_ text: String) -> Validation {
        let sanitized = Checksums.sanitize(
            text.uppercased(), replacing: [("-", ""), (" ", "")]
        )
        let value = Array(sanitized)
        guard value.count == 15 else { return .invalid }

        let stateCode = String(value[0..<2])
        guard let state = Int(stateCode), stateCode.allSatisfy(\.isNumber),
              (1...37).contains(state)
        else { return .invalid }

        // PAN: at least 3 letters in the first five, 4 digits, then a letter.
        let pan = Array(value[2..<12])
        let letterCount = pan.prefix(5).filter(\.isLetter).count
        guard letterCount >= 3,
              pan[5..<9].allSatisfy({ $0.isNumber && $0.isASCII }),
              pan[9].isLetter
        else { return .invalid }

        guard value[12].isLetter || value[12].isNumber else { return .invalid }
        guard value[13] == "Z" else { return .invalid }
        guard value[14].isLetter || value[14].isNumber else { return .invalid }
        return .valid
    }

    // MARK: - Philippines

    public static func philippineTin(_ text: String) -> Bool {
        let sanitized = Checksums.sanitize(text, replacing: [("-", ""), (" ", "")])
        guard let digits = Checksums.digitValues(sanitized),
              digits.count == 9 || digits.count == 12
        else { return false }
        let weights = [9, 8, 7, 6, 5, 4, 3, 2]
        return weightedSum(Array(digits.prefix(8)), weights) % 11 == digits[8]
    }
}
