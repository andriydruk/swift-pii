import PresidioAnalyzer

/// Country-specific national-ID checksums.
///
/// Each is ported from the corresponding Presidio recognizer rather than from
/// the published specification, because several deviate from the spec in ways
/// that change results — and the corpus asserts upstream's behaviour, not the
/// standard's.
public enum CountryValidators {

    // MARK: - Shared helpers

    /// Gregorian date plausibility, matching Python's `datetime(y, m, d)`.
    static func isValidDate(year: Int, month: Int, day: Int) -> Bool {
        guard month >= 1, month <= 12, day >= 1 else { return false }
        let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        let lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return day <= lengths[month - 1]
    }

    /// Weighted sum of the first `count` digits.
    static func weightedSum(_ digits: [Int], _ weights: [Int]) -> Int {
        zip(digits, weights).reduce(0) { $0 + $1.0 * $1.1 }
    }

    // MARK: - Thailand

    /// TNIN: weights 13…2 over the first 12 digits.
    ///
    /// Note the check-digit derivation is *not* a plain `(11 - x) % 10` — the
    /// upstream code branches on `x <= 1`, which yields a different digit for
    /// `x == 0` and `x == 1`.
    public static func thaiTnin(_ text: String) -> Validation {
        guard let digits = Checksums.digitValues(text), digits.count == 13
        else { return .invalid }
        let weights = Array((2...13).reversed())
        let x = weightedSum(Array(digits.prefix(12)), weights) % 11
        let expected = x <= 1 ? 1 - x : 11 - x
        return expected == digits[12] ? .valid : .invalid
    }

    // MARK: - Finland

    private static let finnishControl = Array("0123456789ABCDEFHJKLMNPRSTUVWXY")
    private static let finnishCentury: [Character: Int] = [
        "+": 1800,
        "-": 1900, "Y": 1900, "X": 1900, "W": 1900, "V": 1900, "U": 1900,
        "A": 2000, "B": 2000, "C": 2000, "D": 2000, "E": 2000, "F": 2000,
    ]

    public static func finnishPersonalIdentityCode(_ text: String) -> Validation {
        let chars = Array(text)
        guard chars.count == 11 else { return .invalid }

        let datePart = String(chars[0..<6])
        guard let dd = Int(String(chars[0..<2])),
              let mm = Int(String(chars[2..<4])),
              let yy = Int(String(chars[4..<6]))
        else { return .invalid }

        // An unrecognized separator defaults to 2000, as upstream's
        // `.get(sep, 2000)` does.
        let century = finnishCentury[chars[6]] ?? 2000
        guard isValidDate(year: century + yy, month: mm, day: dd) else { return .invalid }

        let individual = String(chars[7..<10])
        guard let number = Int(datePart + individual) else { return .invalid }
        let control = Character(String(chars[10]).uppercased())
        return finnishControl[number % 31] == control ? .valid : .invalid
    }

    // MARK: - Turkey

    public static func turkishNationalId(_ text: String) -> Validation {
        guard let digits = Checksums.digitValues(text), digits.count == 11,
              digits[0] != 0
        else { return .invalid }

        let oddSum = stride(from: 0, to: 9, by: 2).reduce(0) { $0 + digits[$1] }
        let evenSum = stride(from: 1, to: 8, by: 2).reduce(0) { $0 + digits[$1] }
        guard (oddSum * 7 - evenSum) % 10 == digits[9] else { return .invalid }
        guard digits.prefix(10).reduce(0, +) % 10 == digits[10] else { return .invalid }
        return .valid
    }

    /// Turkish plate: province code 01–81. Returns `.unknown` when the text is
    /// not plate-shaped at all, so the match keeps its pattern score.
    public static func turkishLicensePlate(_ text: String) -> Validation {
        let chars = Array(text)
        guard chars.count >= 3 else { return .unknown }
        let province = String(chars[0..<2])
        guard let code = Int(province), province.allSatisfy(\.isNumber)
        else { return .unknown }
        return (1...81).contains(code) ? .valid : .invalid
    }

    // MARK: - Sweden

    /// Luhn variant used by both Swedish numbers: the check digit is *added*
    /// rather than folded into the doubling pass, and doubling starts at the
    /// digit immediately left of the check digit.
    static func swedishLuhn(_ digits: [Int]) -> Bool {
        guard let check = digits.last else { return false }
        var sum = 0
        for (i, digit) in digits.dropLast().reversed().enumerated() {
            var d = digit
            if i % 2 == 0 {
                d *= 2
                if d > 9 { d -= 9 }
            }
            sum += d
        }
        return (sum + check) % 10 == 0
    }

    public static func swedishPersonnummer(_ text: String) -> Validation {
        // Upstream keeps only the *last* 10 digits, so a 12-digit form with a
        // century prefix normalizes to the same number.
        let all = Checksums.digits(text)
        guard all.count >= 10 else { return .invalid }
        let digits = Array(all.suffix(10))

        let month = digits[2] * 10 + digits[3]
        var day = digits[4] * 10 + digits[5]
        // Samordningsnummer add 60 to the day.
        if day >= 61 { day -= 60 }
        guard (1...12).contains(month), (1...31).contains(day) else { return .invalid }

        return swedishLuhn(digits) ? .valid : .invalid
    }

    public static func swedishOrganisationsnummer(_ text: String) -> Validation {
        let digits = Checksums.digits(text)
        guard digits.count == 10 else { return .invalid }
        // The third digit distinguishes an organisation from a person.
        guard digits[2] >= 2 else { return .invalid }
        return swedishLuhn(digits) ? .valid : .invalid
    }

    // MARK: - Korea

    private static let koreanWeights = [2, 3, 4, 5, 6, 7, 8, 9, 2, 3, 4, 5]

    /// Shared shape for RRN and FRN; they differ only in the modulus constant.
    ///
    /// Returns `.unknown` rather than `.invalid` on failure, because these
    /// checksums only apply to numbers issued before October 2020 — upstream
    /// deliberately returns `None` so later numbers are not discarded.
    static func korean(_ text: String, modulusBase: Int) -> Validation {
        let sanitized = Checksums.sanitize(text, replacing: [("-", "")])
        guard let digits = Checksums.digitValues(sanitized), digits.count == 13
        else { return .invalid }

        let region = digits[7] * 10 + digits[8]
        guard (0...95).contains(region) else { return .unknown }

        let sum = weightedSum(Array(digits.prefix(12)), koreanWeights)
        let check = (modulusBase - sum % 11) % 10
        return check == digits[12] ? .valid : .unknown
    }

    public static func koreanRrn(_ text: String) -> Validation {
        korean(text, modulusBase: 11)
    }

    public static func koreanFrn(_ text: String) -> Validation {
        korean(text, modulusBase: 13)
    }

    // MARK: - Australia

    public static func australianAbn(_ text: String) -> Validation {
        var digits = Checksums.digits(text)
        guard digits.count >= 11 else { return .invalid }
        digits[0] -= 1
        let weights = [10, 1, 3, 5, 7, 9, 11, 13, 15, 17, 19]
        return weightedSum(Array(digits.prefix(11)), weights) % 89 == 0 ? .valid : .invalid
    }

    public static func australianAcn(_ text: String) -> Validation {
        let digits = Checksums.digits(text)
        guard digits.count >= 9 else { return .invalid }
        let weights = [8, 7, 6, 5, 4, 3, 2, 1]
        let remainder = weightedSum(Array(digits.prefix(8)), weights) % 10
        return (10 - remainder) % 10 == digits[digits.count - 1] ? .valid : .invalid
    }

    public static func australianTfn(_ text: String) -> Validation {
        let digits = Checksums.digits(text)
        guard digits.count >= 9 else { return .invalid }
        let weights = [1, 4, 3, 7, 5, 8, 6, 9, 10]
        return weightedSum(Array(digits.prefix(9)), weights) % 11 == 0 ? .valid : .invalid
    }

    public static func australianMedicare(_ text: String) -> Validation {
        let digits = Checksums.digits(text)
        guard digits.count >= 9 else { return .invalid }
        let weights = [1, 3, 7, 9, 1, 3, 7, 9]
        return weightedSum(Array(digits.prefix(8)), weights) % 10 == digits[8]
            ? .valid : .invalid
    }

    // MARK: - Spain

    private static let spanishControl = Array("TRWAGMYFPDXBNJZSQVHLCKE")

    /// NIE: leading X/Y/Z is replaced by 0/1/2 before the mod-23 lookup.
    public static func spanishNie(_ text: String) -> Validation {
        let sanitized = Checksums.sanitize(
            text, replacing: [("-", ""), (" ", "")]
        ).uppercased()
        let chars = Array(sanitized)
        guard chars.count >= 8, chars.count <= 9, let letter = chars.last
        else { return .invalid }

        let body = String(chars[1..<(chars.count - 1)])
        guard body.allSatisfy(\.isNumber),
              let prefixIndex = "XYZ".firstIndex(of: chars[0])
        else { return .invalid }

        let prefixDigit = "XYZ".distance(from: "XYZ".startIndex, to: prefixIndex)
        guard let number = Int("\(prefixDigit)" + body) else { return .invalid }
        return spanishControl[number % 23] == letter ? .valid : .invalid
    }

    public static func spanishNif(_ text: String) -> Validation {
        let sanitized = Checksums.sanitize(
            text, replacing: [("-", ""), (" ", "")]
        ).uppercased()
        guard let letter = sanitized.last else { return .invalid }
        let digitsOnly = sanitized.filter(\.isNumber)
        guard !digitsOnly.isEmpty, let number = Int(digitsOnly) else { return .invalid }
        return spanishControl[number % 23] == letter ? .valid : .invalid
    }

    // MARK: - Italy

    public static func italianVatCode(_ text: String) -> Validation {
        // Note the underscore: this recognizer's replacement pairs are
        // [("-",""), (" ",""), ("_","")], so "01333550_323" is a valid code.
        let sanitized = Checksums.sanitize(
            text, replacing: [("-", ""), (" ", ""), ("_", "")]
        )
        guard let digits = Checksums.digitValues(sanitized), digits.count >= 11
        else { return .invalid }
        if sanitized == "00000000000" { return .invalid }

        var x = 0, y = 0
        for i in 0..<5 {
            x += digits[2 * i]
            var tmp = digits[2 * i + 1] * 2
            if tmp > 9 { tmp -= 9 }
            y += tmp
        }
        let c = (10 - (x + y) % 10) % 10
        return c == digits[10] ? .valid : .invalid
    }

    private static let italianOdd: [Character: Int] = [
        "0": 1, "1": 0, "2": 5, "3": 7, "4": 9, "5": 13, "6": 15, "7": 17,
        "8": 19, "9": 21, "A": 1, "B": 0, "C": 5, "D": 7, "E": 9, "F": 13,
        "G": 15, "H": 17, "I": 19, "J": 21, "K": 2, "L": 4, "M": 18, "N": 20,
        "O": 11, "P": 3, "Q": 6, "R": 8, "S": 12, "T": 14, "U": 16, "V": 10,
        "W": 22, "X": 25, "Y": 24, "Z": 23,
    ]

    private static func italianEven(_ c: Character) -> Int? {
        if let d = c.wholeNumberValue, c.isNumber, c.isASCII { return d }
        guard c.isASCII, c.isLetter,
              let ascii = c.unicodeScalars.first?.value, ascii >= 65, ascii <= 90
        else { return nil }
        return Int(ascii - 65)
    }

    /// Codice fiscale. Returns `.unknown` on mismatch, not `.invalid` —
    /// upstream returns `None`, keeping the match at its pattern score.
    public static func italianFiscalCode(_ text: String) -> Validation {
        let chars = Array(text.uppercased())
        guard chars.count >= 2, let control = chars.last else { return .unknown }
        let body = Array(chars.dropLast())

        var sum = 0
        for (index, character) in body.enumerated() {
            if index % 2 == 0 {
                guard let value = italianOdd[character] else { return .unknown }
                sum += value
            } else {
                guard let value = italianEven(character) else { return .unknown }
                sum += value
            }
        }
        let expected = Character(
            String(UnicodeScalar(UInt8(65 + sum % 26)))
        )
        return expected == control ? .valid : .unknown
    }

    // MARK: - United Kingdom

    /// Current-format (2001+) plates carry a two-digit age identifier:
    /// 02–29 for March, 51–79 for September. Prefix/suffix formats return
    /// `.unknown` so they keep their pattern score.
    public static func ukVehicleRegistration(_ text: String) -> Validation {
        let sanitized = Checksums.sanitize(text, replacing: [("-", ""), (" ", "")])
        let chars = Array(sanitized)
        guard chars.count == 7, chars[0].isLetter, chars[1].isLetter
        else { return .unknown }
        let ageText = String(chars[2..<4])
        guard ageText.allSatisfy(\.isNumber), let age = Int(ageText)
        else { return .unknown }
        return (2...29).contains(age) || (51...79).contains(age) ? .valid : .invalid
    }
}
