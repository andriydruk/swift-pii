/// Checksum algorithms used by Presidio's recognizers.
///
/// Presidio hand-rolls every one of these in-repo — it does **not** depend on
/// `python-stdnum` — so each is ported from the upstream source rather than
/// from a specification, and matches its quirks where they differ.
public enum Checksums {

    /// Presidio's `EntityRecognizer.sanitize_value`: ordered literal
    /// replacements, not a character-class strip.
    public static func sanitize(
        _ text: String, replacing pairs: [(String, String)]
    ) -> String {
        var out = text
        for (find, replace) in pairs where !find.isEmpty {
            // `replacing(_:with:)` is stdlib; `replacingOccurrences` is
            // Foundation, and this file stays portable.
            out = out.replacing(find, with: replace)
        }
        return out
    }

    /// Digit values of a string, or `nil` if any character is not a digit.
    ///
    /// Python's `int(dig)` would raise on a non-digit; returning `nil` keeps
    /// that as a validation failure rather than a crash.
    public static func digitValues(_ text: String) -> [Int]? {
        var out: [Int] = []
        out.reserveCapacity(text.count)
        for character in text {
            // Python's `int(ch)` accepts any Unicode decimal digit, and the
            // recognizer patterns use `\d`, which matches them — so requiring
            // ASCII here rejected values upstream validates.
            guard let value = Python.digitValue(character), (0...9).contains(value)
            else { return nil }
            out.append(value)
        }
        return out
    }

    /// Digit values, ignoring every non-digit character.
    public static func digits(_ text: String) -> [Int] {
        text.compactMap {
            guard let v = Python.digitValue($0), (0...9).contains(v) else { return nil }
            return v
        }
    }

    // MARK: - Luhn

    /// Luhn mod-10, as used by `CreditCardRecognizer`.
    ///
    /// Upstream sanitizes with `[("-", ""), (" ", "")]` before checking, so a
    /// card written with dashes or spaces validates but one written with dots
    /// does not — the pattern is what admits those forms.
    public static func luhn(digitsOf text: String) -> Bool {
        let sanitized = sanitize(text, replacing: [("-", ""), (" ", "")])
        guard let digits = digitValues(sanitized), !digits.isEmpty else { return false }
        return luhn(digits)
    }

    public static func luhn(_ digits: [Int]) -> Bool {
        guard !digits.isEmpty else { return false }
        var sum = 0
        // Python takes digits[-1::-2] as "odd" (from the right, every other)
        // and digits[-2::-2] as "even", doubling the latter and summing the
        // digits of each doubled value.
        for (offset, digit) in digits.reversed().enumerated() {
            if offset % 2 == 0 {
                sum += digit
            } else {
                let doubled = digit * 2
                sum += doubled >= 10 ? doubled - 9 : doubled
            }
        }
        return sum % 10 == 0
    }

    // MARK: - Verhoeff

    private static let verhoeffD: [[Int]] = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9],
        [1, 2, 3, 4, 0, 6, 7, 8, 9, 5],
        [2, 3, 4, 0, 1, 7, 8, 9, 5, 6],
        [3, 4, 0, 1, 2, 8, 9, 5, 6, 7],
        [4, 0, 1, 2, 3, 9, 5, 6, 7, 8],
        [5, 9, 8, 7, 6, 0, 4, 3, 2, 1],
        [6, 5, 9, 8, 7, 1, 0, 4, 3, 2],
        [7, 6, 5, 9, 8, 2, 1, 0, 4, 3],
        [8, 7, 6, 5, 9, 3, 2, 1, 0, 4],
        [9, 8, 7, 6, 5, 4, 3, 2, 1, 0],
    ]

    private static let verhoeffP: [[Int]] = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9],
        [1, 5, 7, 6, 2, 8, 3, 0, 9, 4],
        [5, 8, 0, 3, 7, 9, 6, 1, 4, 2],
        [8, 9, 1, 6, 0, 4, 3, 5, 2, 7],
        [9, 4, 5, 3, 1, 2, 6, 8, 7, 0],
        [4, 2, 8, 6, 5, 7, 3, 9, 0, 1],
        [2, 7, 9, 3, 8, 0, 6, 4, 1, 5],
        [7, 0, 4, 6, 9, 1, 3, 2, 5, 8],
    ]

    private static let verhoeffInv = [0, 4, 3, 2, 1, 5, 6, 7, 8, 9]

    /// Verhoeff check, used by the Aadhaar recognizer.
    public static func verhoeff(_ digits: [Int]) -> Bool {
        guard !digits.isEmpty else { return false }
        var c = 0
        for (i, digit) in digits.reversed().enumerated() {
            guard (0...9).contains(digit) else { return false }
            c = verhoeffD[c][verhoeffP[i % 8][digit]]
        }
        return verhoeffInv[c] == 0
    }

    // MARK: - PESEL

    /// Polish PESEL check digit.
    ///
    /// Weights `[1,3,7,9,1,3,7,9,1,3]`; check digit is
    /// `(10 - weightedSum % 10) % 10`.
    public static func pesel(_ digits: [Int]) -> Bool {
        guard digits.count == 11 else { return false }
        let weights = [1, 3, 7, 9, 1, 3, 7, 9, 1, 3]
        let weighted = zip(digits.prefix(10), weights).reduce(0) { $0 + $1.0 * $1.1 }
        return (10 - weighted % 10) % 10 == digits[10]
    }

    // MARK: - Weighted-sum checksums

    /// UK NHS number: digits weighted 10, 9, ... 1 with the check digit last;
    /// the total must be divisible by 11.
    public static func nhs(_ digits: [Int]) -> Bool {
        guard !digits.isEmpty else { return false }
        // Upstream zips the text against `reversed(range(11))` = 10, 9, ... 0,
        // so it silently tolerates lengths other than 10 by truncating.
        let weights = Array((0...10).reversed())
        let total = zip(digits, weights).reduce(0) { $0 + $1.0 * $1.1 }
        return total % 11 == 0
    }

    /// ABA routing number: weights 3, 7, 1 repeated over the first 9 digits.
    public static func abaRouting(_ digits: [Int]) -> Bool {
        guard digits.count >= 9 else { return false }
        let weights = [3, 7, 1, 3, 7, 1, 3, 7, 1]
        let total = zip(digits.prefix(9), weights).reduce(0) { $0 + $1.0 * $1.1 }
        return total % 10 == 0
    }

    /// US NPI: Luhn over the 10-digit NPI prefixed with the CMS "80840" issuer
    /// identifier, per the NPI Final Rule.
    public static func usNpi(_ digits: [Int]) -> Bool {
        guard digits.count == 10 else { return false }
        return luhn([8, 0, 8, 4, 0] + digits)
    }

    /// DEA / medical licence: a Luhn-like check over the digits *after* the two
    /// leading registrant letters.
    ///
    /// Upstream's arithmetic is unusual — it negates the check digit and adds
    /// `2 * sum(even) + sum(odd)` — so it is reproduced literally rather than
    /// normalized into a standard Luhn.
    public static func medicalLicense(_ text: String) -> Bool {
        let body = String(text.dropFirst(2))
        guard let digits = digitValues(body), digits.count >= 2 else { return false }

        var working = digits
        var checksum = -working.removeLast()
        // Python: even_digits = digits[-1::-2], odd_digits = digits[-2::-2],
        // taken after the check digit has been popped.
        for (offset, digit) in working.reversed().enumerated() {
            checksum += offset % 2 == 0 ? 2 * digit : digit
        }
        return checksum % 10 == 0
    }

    // MARK: - Helpers

    /// Port of `InAadhaarRecognizer._is_palindrome`.
    ///
    /// - Parameter caseInsensitive: upstream's optional second argument, which
    ///   does slightly more than its name says — it strips spaces as well as
    ///   lowercasing. The Aadhaar recognizer never passes it, since Aadhaar
    ///   numbers are digits, so this existed as a one-argument function until
    ///   the upstream table that exercises both arguments was harvested.
    public static func isPalindrome(
        _ text: String, caseInsensitive: Bool = false
    ) -> Bool {
        let subject = caseInsensitive
            ? text.replacing(" ", with: "").lowercased()
            : text
        return subject == String(subject.reversed())
    }
}
