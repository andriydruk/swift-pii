import Foundation
import PresidioRegex

/// How strictly a candidate must look like a phone number to be accepted.
/// Values match libphonenumber's `Leniency`, which is what Presidio passes.
public enum PhoneLeniency: Int, Sendable {
    case possible = 0
    case valid = 1
    case strictGrouping = 2
    case exactGrouping = 3
}

/// A phone number found inside a larger text.
public struct PhoneMatch: Sendable, Hashable {
    /// Unicode scalar offsets, matching the rest of the package.
    public let start: Int
    public let end: Int
    public let raw: String
    public let number: PhoneNumber
}

/// A port of libphonenumber's `PhoneNumberMatcher`.
///
/// This is the piece `PhoneRecognizer` is actually built on: it finds numbers
/// *embedded in free text*, which no Swift phone library provides —
/// PhoneNumberKit offers parse/format/validate only. Without it the recognizer
/// cannot work at all, which is why the util port alone contributed nothing.
///
/// Candidate extraction, the reject filters and the inner-match fallback are
/// ported from `phonenumbermatcher.py`; the regexes come from the same metadata
/// extract, so they are Google's rather than approximations.
public struct PhoneNumberMatcher {

    struct Patterns: Decodable {
        let pattern: String
        let matchingBrackets: String
        let pubPages: String
        let slashDates: String
        let timeStamps: String
        let timeStampsSuffix: String
        let leadClass: String
        let unwantedEndChars: String
        let separator: String
        let extn: String
        let validPhoneNumber: String
        let minLengthForNSN: Int
        let innerMatches: [String]

        enum CodingKeys: String, CodingKey {
            case pattern
            case matchingBrackets = "matching_brackets"
            case pubPages = "pub_pages"
            case slashDates = "slash_dates"
            case timeStamps = "time_stamps"
            case timeStampsSuffix = "time_stamps_suffix"
            case leadClass = "lead_class"
            case unwantedEndChars = "unwanted_end_chars"
            case separator, extn
            case validPhoneNumber = "valid_phone_number"
            case minLengthForNSN = "min_length_for_nsn"
            case innerMatches = "inner_matches"
        }
    }

    struct Compiled {
        let candidate: PureRegex
        let matchingBrackets: PureRegex
        let pubPages: PureRegex
        let slashDates: PureRegex
        let timeStamps: PureRegex
        let timeStampsSuffix: PureRegex
        let leadClass: PureRegex
        let unwantedEndChars: PureRegex
        let separator: PureRegex
        let extn: PureRegex
        let validPhoneNumber: PureRegex
        let minLengthForNSN: Int
        let innerMatches: [PureRegex]
    }

    private static let compiled: Compiled? = {
        guard let url = Bundle.module.url(
            forResource: "phone_metadata", withExtension: "json"
        ),
        let bytes = try? Data(contentsOf: url),
        let root = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
        let raw = root["matcher"],
        let matcherBytes = try? JSONSerialization.data(withJSONObject: raw),
        let patterns = try? JSONDecoder().decode(Patterns.self, from: matcherBytes)
        else { return nil }

        func make(_ pattern: String) -> PureRegex? {
            // libphonenumber compiles these case-insensitively and without
            // DOTALL; `^`/`$` are string anchors.
            try? PureRegex(pattern, ignoreCase: true, dotAll: false, multiline: false)
        }
        guard let candidate = make(patterns.pattern),
              let brackets = make(patterns.matchingBrackets),
              let pubPages = make(patterns.pubPages),
              let slashDates = make(patterns.slashDates),
              let timeStamps = make(patterns.timeStamps),
              let timeStampsSuffix = make(patterns.timeStampsSuffix),
              let leadClass = make(patterns.leadClass),
              let unwanted = make(patterns.unwantedEndChars),
              let separator = make(patterns.separator),
              let extn = make(patterns.extn),
              let valid = make("^(?:" + patterns.validPhoneNumber + ")$")
        else { return nil }
        let inner = patterns.innerMatches.compactMap(make)
        guard inner.count == patterns.innerMatches.count else { return nil }

        return Compiled(
            candidate: candidate, matchingBrackets: brackets, pubPages: pubPages,
            slashDates: slashDates, timeStamps: timeStamps,
            timeStampsSuffix: timeStampsSuffix, leadClass: leadClass,
            unwantedEndChars: unwanted, separator: separator,
            extn: extn, validPhoneNumber: valid,
            minLengthForNSN: patterns.minLengthForNSN, innerMatches: inner
        )
    }()

    public static var isReady: Bool { compiled != nil }

    /// Exposed for diagnostics only.
    static var compiledForTesting: Compiled? { compiled }

    /// Runs of the characters libphonenumber allows between digit groups.
    /// Used by the formatter to split a formatted number into its groups.
    static var separatorRegex: PureRegex? { compiled?.separator }

    /// `_EXTN_PATTERN`, `_VALID_PHONE_NUMBER_PATTERN` and `_MIN_LENGTH_FOR_NSN`,
    /// which `PhoneNumberUtil.splitExtension` needs.
    static var extensionRegex: PureRegex? { compiled?.extn }
    static var viableNumberRegex: PureRegex? { compiled?.validPhoneNumber }
    static var minLengthForNSN: Int { compiled?.minLengthForNSN ?? 2 }

    private let text: String
    private let scalars: [Unicode.Scalar]
    private let region: String
    private let leniency: PhoneLeniency

    public init(text: String, region: String, leniency: PhoneLeniency = .valid) {
        self.text = text
        self.scalars = Array(text.unicodeScalars)
        self.region = region
        self.leniency = leniency
    }

    private func substring(_ range: Range<Int>) -> String {
        String(String.UnicodeScalarView(scalars[range]))
    }

    /// All matches, in order.
    ///
    /// The scan converts the text to scalar values once and searches from an
    /// advancing offset. The obvious formulation — re-slice the remaining text
    /// each round and take `matches(in:).first` — is quadratic twice over: it
    /// copies the tail per iteration, and it finds *every* remaining match only
    /// to discard all but the first. `PhoneRecognizer` runs this once per
    /// configured region, so that cost is multiplied by eight.
    public func matches() -> [PhoneMatch] {
        guard let compiled = Self.compiled else { return [] }
        var results: [PhoneMatch] = []
        var searchFrom = 0
        let values = PureRegex.scalarValues(of: text)

        while searchFrom < scalars.count {
            guard let hit = compiled.candidate.firstMatch(
                inScalars: values, from: searchFrom
            ) else { break }
            let start = hit.start
            var candidate = substring(start..<hit.end)

            // Trim characters that cannot end a number, so trailing punctuation
            // is not swallowed into the match.
            candidate = trimAfterFirstMatch(compiled.unwantedEndChars, candidate)

            if let match = extractMatch(candidate, offset: start) {
                results.append(match)
                searchFrom = match.end
            } else {
                searchFrom = start + max(candidate.unicodeScalars.count, 1)
            }
        }
        return results
    }

    private func trimAfterFirstMatch(_ regex: PureRegex, _ candidate: String) -> String {
        guard let hit = regex.matches(in: candidate).first else { return candidate }
        return String(String.UnicodeScalarView(
            Array(candidate.unicodeScalars)[0..<hit.0]
        ))
    }

    /// Port of `_extract_match`.
    private func extractMatch(_ candidate: String, offset: Int) -> PhoneMatch? {
        guard let compiled = Self.compiled else { return nil }

        // A date is not a phone number: "3/10/2011".
        if !compiled.slashDates.matches(in: candidate).isEmpty { return nil }

        // Nor is a timestamp — but only when a ":mm" actually follows.
        if !compiled.timeStamps.matches(in: candidate).isEmpty {
            let after = offset + candidate.unicodeScalars.count
            if after < scalars.count {
                let following = substring(after..<scalars.count)
                if compiled.timeStampsSuffix.matches(in: following).contains(where: { $0.0 == 0 }) {
                    return nil
                }
            }
        }

        if let match = parseAndVerify(candidate, offset: offset) { return match }
        return extractInnerMatch(candidate, offset: offset)
    }

    /// Port of `_extract_inner_match`: a candidate may contain a number rather
    /// than being one, e.g. when two numbers are run together.
    private func extractInnerMatch(_ candidate: String, offset: Int) -> PhoneMatch? {
        guard let compiled = Self.compiled else { return nil }

        for inner in compiled.innerMatches {
            var isFirst = true
            for hit in inner.matchesWithGroups(in: candidate) {
                if isFirst {
                    // Everything before the first inner hit is also a candidate.
                    let head = String(String.UnicodeScalarView(
                        Array(candidate.unicodeScalars)[0..<hit.start]
                    ))
                    let trimmed = trimAfterFirstMatch(compiled.unwantedEndChars, head)
                    if let match = parseAndVerify(trimmed, offset: offset) { return match }
                    isFirst = false
                }
                guard let group = hit.span(1) else { continue }
                let inner = String(String.UnicodeScalarView(
                    Array(candidate.unicodeScalars)[group]
                ))
                let trimmed = trimAfterFirstMatch(compiled.unwantedEndChars, inner)
                if let match = parseAndVerify(trimmed, offset: offset + group.lowerBound) {
                    return match
                }
            }
        }
        return nil
    }

    /// Port of `_is_latin_letter`.
    ///
    /// A letter *or* a non-spacing mark, and only in the Latin blocks —
    /// combining marks count because they attach to a preceding Latin
    /// character. The block test is the whole point: it is what makes
    /// "Привет4155550132" a match and "café4155550132" not one.
    ///
    /// An earlier version tested `isAlphabetic`, which is every script, so any
    /// Cyrillic, Greek or CJK character beside a number suppressed the match.
    /// That is stricter than upstream and silently loses real numbers.
    private func isLatinLetter(_ scalar: Unicode.Scalar) -> Bool {
        let category = scalar.properties.generalCategory
        let isLetter = category == .uppercaseLetter || category == .lowercaseLetter
            || category == .titlecaseLetter || category == .modifierLetter
            || category == .otherLetter
        guard isLetter || category == .nonspacingMark else { return false }

        switch scalar.value {
        case 0x0000...0x007F,   // Basic Latin
             0x0080...0x00FF,   // Latin-1 Supplement
             0x0100...0x017F,   // Latin Extended-A
             0x0180...0x024F,   // Latin Extended-B
             0x1E00...0x1EFF,   // Latin Extended Additional
             0x0300...0x036F:   // Combining Diacritical Marks
            return true
        default:
            return false
        }
    }

    /// Port of `_is_invalid_punctuation_symbol`: `%` or any currency symbol.
    ///
    /// Not the hand-picked `%$@` an earlier version used. `@` is not a
    /// currency symbol and must not suppress a match, while `£`, `€` and `¥`
    /// are and must.
    private func isInvalidPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "%" || scalar.properties.generalCategory == .currencySymbol
    }

    /// Port of `_parse_and_verify`.
    private func parseAndVerify(_ candidate: String, offset: Int) -> PhoneMatch? {
        guard let compiled = Self.compiled, !candidate.isEmpty else { return nil }

        // Formatting that a real number would not have.
        let length = candidate.unicodeScalars.count
        let bracketsOK = compiled.matchingBrackets.matches(in: candidate)
            .contains { $0.0 == 0 && $0.1 == length }
        guard bracketsOK, compiled.pubPages.matches(in: candidate).isEmpty
        else { return nil }

        if leniency.rawValue >= PhoneLeniency.valid.rawValue {
            // Reject numbers glued to letters: "abc8005001234".
            let startsWithLead = compiled.leadClass.matches(in: candidate)
                .contains { $0.0 == 0 }
            if offset > 0, !startsWithLead {
                let previous = scalars[offset - 1]
                if isInvalidPunctuation(previous) || isLatinLetter(previous) { return nil }
            }
            let after = offset + length
            if after < scalars.count {
                let next = scalars[after]
                if isInvalidPunctuation(next) || isLatinLetter(next) { return nil }
            }
        }

        guard let number = try? PhoneNumberUtil.parse(candidate, defaultRegion: region),
              verify(number, candidate: candidate)
        else { return nil }

        return PhoneMatch(
            start: offset, end: offset + length, raw: candidate, number: number
        )
    }

    /// Port of `_verify`.
    private func verify(_ number: PhoneNumber, candidate: String) -> Bool {
        switch leniency {
        case .possible:
            return PhoneNumberUtil.isPossible(number)
        case .valid:
            guard PhoneNumberUtil.isValid(number),
                  containsOnlyValidXChars(candidate, number: number)
            else { return false }
            return PhoneNumberUtil.isNationalPrefixPresentIfRequired(
                number, raw: candidate
            )
        case .strictGrouping, .exactGrouping:
            // Everything VALID requires, plus the slash rule, plus the
            // candidate's digit grouping matching a format for the region.
            guard PhoneNumberUtil.isValid(number),
                  containsOnlyValidXChars(candidate, number: number),
                  !containsMoreThanOneSlashInNationalNumber(number, candidate),
                  PhoneNumberUtil.isNationalPrefixPresentIfRequired(
                      number, raw: candidate
                  )
            else { return false }
            return checkNumberGroupingIsValid(
                number, candidate: candidate,
                checker: leniency == .strictGrouping
                    ? Self.allNumberGroupsRemainGrouped
                    : Self.allNumberGroupsAreExactlyPresent
            )
        }
    }

    // MARK: - Grouping leniencies

    /// Port of `_contains_more_than_one_slash_in_national_number`.
    ///
    /// One slash is fine, and a second is fine *only* when the first separated
    /// the country code — "+1/415/555-0132" is one slash too many, but
    /// "+1/415 555 0132" is a country code followed by the number.
    func containsMoreThanOneSlashInNationalNumber(
        _ number: PhoneNumber, _ candidate: String
    ) -> Bool {
        let scalars = Array(candidate.unicodeScalars)
        guard let first = scalars.firstIndex(of: "/") else { return false }
        guard let second = scalars[(first + 1)...].firstIndex(of: "/") else { return false }

        // A number whose country code came from the candidate itself may put
        // the first slash after that code.
        if !number.fromDefaultRegion {
            let head = String(String.UnicodeScalarView(scalars[0..<first]))
            if PhoneNumberUtil.digitsOnly(head) == String(number.countryCode) {
                return scalars[(second + 1)...].contains("/")
            }
        }
        return true
    }

    /// Port of `_check_number_grouping_is_valid`.
    func checkNumberGroupingIsValid(
        _ number: PhoneNumber,
        candidate: String,
        checker: (PhoneNumber, String, [String]) -> Bool
    ) -> Bool {
        // "normalized to only contain ASCII digits, but with non-digits
        // (spaces etc) retained".
        let normalized = Self.normalizeKeepingSeparators(candidate)

        if let groups = PhoneNumberUtil.nationalNumberGroups(number),
           checker(number, normalized, groups) {
            return true
        }
        // Fall back to the alternate formats for this country code.
        for format in PhoneNumberUtil.alternateFormats(
            countryCode: number.countryCode, nationalNumber: number.significantNumber
        ) {
            if let groups = PhoneNumberUtil.nationalNumberGroups(number, using: format),
               checker(number, normalized, groups) {
                return true
            }
        }
        return false
    }

    /// `normalize_digits_only(candidate, keep_non_digits=True)`: map every
    /// Unicode decimal digit to its ASCII form and leave everything else.
    static func normalizeKeepingSeparators(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if let value = Character(scalar).wholeNumberValue,
               scalar.properties.numericType == .decimal, value >= 0, value <= 9 {
                out.append(Unicode.Scalar(UInt8(48 + value)))
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }

    /// Port of `_all_number_groups_remain_grouped` — STRICT_GROUPING.
    ///
    /// Each formatted group must appear intact and in order; the candidate may
    /// group them differently as long as no group is *split*.
    static func allNumberGroupsRemainGrouped(
        _ number: PhoneNumber, _ normalized: String, _ groups: [String]
    ) -> Bool {
        let scalars = Array(normalized.unicodeScalars)
        var from = 0

        if !number.fromDefaultRegion {
            // Skip the country code when the candidate carried it.
            let code = String(number.countryCode)
            guard let range = Self.range(of: code, in: scalars, from: 0) else { return false }
            from = range.upperBound
        }

        for (index, group) in groups.enumerated() {
            guard let range = Self.range(of: group, in: scalars, from: from)
            else { return false }
            from = range.upperBound

            if index == 0, from < scalars.count {
                // Right after the national destination code. If the region has
                // a national prefix and the next character is another digit,
                // there was no separator there — which is only acceptable when
                // the whole number is unformatted.
                let region = PhoneNumberUtil.regionCode(for: number)
                    .flatMap { PhoneNumberUtil.metadata?.regions[$0] }
                    ?? PhoneNumberUtil.mainRegion(forCountryCode: number.countryCode)
                let prefix = region?.nationalPrefix ?? ""
                if !prefix.isEmpty,
                   Character(scalars[from]).isNumber {
                    let tail = String(String.UnicodeScalarView(
                        scalars[(from - group.unicodeScalars.count)...]
                    ))
                    return tail.hasPrefix(number.significantNumber)
                }
            }
        }

        // Guard against having matched the extension as the last group.
        let tail = String(String.UnicodeScalarView(scalars[from...]))
        return number.extensionDigits.isEmpty || tail.contains(number.extensionDigits)
    }

    /// Port of `_all_number_groups_are_exactly_present` — EXACT_GROUPING.
    static func allNumberGroupsAreExactlyPresent(
        _ number: PhoneNumber, _ normalized: String, _ groups: [String]
    ) -> Bool {
        let candidateGroups = normalized
            .split(whereSeparator: { !$0.isNumber || !$0.isASCII })
            .map(String.init)
        guard !candidateGroups.isEmpty else { return false }

        var candidateIndex = number.extensionDigits.isEmpty
            ? candidateGroups.count - 1
            : candidateGroups.count - 2
        guard candidateIndex >= 0 else { return false }

        // The whole national number written as one block is acceptable — it may
        // carry a national prefix or the country code in front of it.
        if candidateGroups.count == 1
            || candidateGroups[candidateIndex].contains(number.significantNumber) {
            return true
        }

        var formattedIndex = groups.count - 1
        while formattedIndex > 0 && candidateIndex >= 0 {
            if candidateGroups[candidateIndex] != groups[formattedIndex] { return false }
            formattedIndex -= 1
            candidateIndex -= 1
        }
        // The first group may have a national prefix in front, so only require
        // that it ends with the formatted group.
        return candidateIndex >= 0 && candidateGroups[candidateIndex].hasSuffix(groups[0])
    }

    /// `str.find(sub, from)` over scalars.
    static func range(
        of needle: String, in haystack: [Unicode.Scalar], from: Int
    ) -> Range<Int>? {
        let target = Array(needle.unicodeScalars)
        guard !target.isEmpty, from <= haystack.count else { return nil }
        guard haystack.count >= target.count else { return nil }
        var start = from
        while start + target.count <= haystack.count {
            if Array(haystack[start..<(start + target.count)]) == target {
                return start..<(start + target.count)
            }
            start += 1
        }
        return nil
    }

    /// Port of `_contains_only_valid_x_chars`: an 'x' is either a carrier code
    /// (two or more) or an extension marker (exactly one), never a stray letter
    /// inside the number.
    ///
    /// The single-'x' rule compares the *digits* after the marker against the
    /// number's parsed extension:
    ///
    ///     elif normalize_digits_only(candidate[ii:]) != numobj.extension:
    ///
    /// An earlier port read that as "everything after the x must be digits",
    /// which rejected every candidate written "…0132 ext. 22" — the 't' and the
    /// '.' are not digits — and cost twelve of the thirteen matcher
    /// divergences, one per configured region.
    private func containsOnlyValidXChars(
        _ candidate: String, number: PhoneNumber
    ) -> Bool {
        let characters = Array(candidate)
        guard characters.count > 1 else { return true }
        var index = 0
        while index < characters.count - 1 {
            if characters[index] == "x" || characters[index] == "X" {
                let next = characters[index + 1]
                if next == "x" || next == "X" {
                    // Carrier-code case: the 'x's precede the national
                    // significant number, so what follows must be the same
                    // number. Upstream calls `is_number_match` and requires
                    // NSN_MATCH; parsing the remainder is what makes that
                    // hold for a tail carrying its own country code, which
                    // comparing raw digits would not.
                    index += 1
                    let rest = String(characters[(index + 1)...])
                    guard let parsed = try? PhoneNumberUtil.parse(
                        rest, defaultRegion: region
                    ), parsed.significantNumber == number.significantNumber
                    else { return false }
                } else {
                    let rest = PhoneNumberUtil.digitsOnly(
                        String(characters[(index + 1)...])
                    )
                    if rest != number.extensionDigits { return false }
                }
            }
            index += 1
        }
        return true
    }
}
