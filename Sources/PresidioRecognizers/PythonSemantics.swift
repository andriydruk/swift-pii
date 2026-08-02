import Foundation

/// Swift equivalents of the Python string operations the validators are ported
/// from.
///
/// These exist because the obvious Swift spelling is subtly different, and the
/// difference is reachable: recognizer patterns use `\d`, which follows
/// Python's `regex` module and matches every Unicode decimal digit, so a
/// validator really can be handed Arabic-Indic or full-width digits.
enum Python {

    /// `str.isdigit()` for one character.
    ///
    /// Not `Character.isASCII && .isNumber`, which rejects every non-ASCII
    /// digit that `\d` happily matched, and not bare `.isNumber`, which
    /// accepts numeric forms with no digit value at all.
    static func isDigit(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first,
              character.unicodeScalars.count == 1
        else { return false }
        switch scalar.properties.numericType {
        case .decimal, .digit: return true
        default: return false
        }
    }

    /// `str.isdigit()` for a whole string. Empty is false, as in Python.
    static func isDigits(_ text: some StringProtocol) -> Bool {
        !text.isEmpty && text.allSatisfy(isDigit)
    }

    /// The digit value, for a character `isDigit` accepts.
    static func digitValue(_ character: Character) -> Int? {
        guard isDigit(character) else { return nil }
        return character.wholeNumberValue
    }

    /// `str.strip()`.
    ///
    /// Trims on the Unicode White_Space property, which is what Python uses.
    /// `trimmingCharacters(in: .whitespacesAndNewlines)` is *wider*: it also
    /// removes the zero-width space, so a value padded with U+200B validated
    /// here and did not in Python — a false positive, which is the direction
    /// that matters.
    static func strip(_ text: some StringProtocol) -> String {
        var scalars = Substring(String(text))
        while let first = scalars.first, first.unicodeScalars.allSatisfy({
            $0.properties.isWhitespace
        }) { scalars = scalars.dropFirst() }
        while let last = scalars.last, last.unicodeScalars.allSatisfy({
            $0.properties.isWhitespace
        }) { scalars = scalars.dropLast() }
        return String(scalars)
    }

    /// ASCII-only digits, for the places upstream really does mean `[0-9]`.
    static func isASCIIDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }
}

extension StringProtocol {
    /// `str.strip()` — see `Python.strip`.
    func pythonStripped() -> String { Python.strip(self) }
}

extension Python {
    /// `int(str)` for a run of digits.
    ///
    /// Swift's `Int(String)` parses ASCII only, while Python's `int()` accepts
    /// any Unicode decimal digit — so a value that passed an `isdigit()` guard
    /// could still fail to convert here, which crashed a force-unwrap.
    static func integer(_ text: some StringProtocol) -> Int? {
        var total = 0
        var any = false
        for character in text {
            guard let value = digitValue(character) else { return nil }
            let (multiplied, overflowA) = total.multipliedReportingOverflow(by: 10)
            guard !overflowA else { return nil }
            let (sum, overflowB) = multiplied.addingReportingOverflow(value)
            guard !overflowB else { return nil }
            total = sum
            any = true
        }
        return any ? total : nil
    }
}
