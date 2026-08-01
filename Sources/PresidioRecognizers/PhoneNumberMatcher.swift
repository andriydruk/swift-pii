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
            case innerMatches = "inner_matches"
        }
    }

    private struct Compiled {
        let candidate: PureRegex
        let matchingBrackets: PureRegex
        let pubPages: PureRegex
        let slashDates: PureRegex
        let timeStamps: PureRegex
        let timeStampsSuffix: PureRegex
        let leadClass: PureRegex
        let unwantedEndChars: PureRegex
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
              let unwanted = make(patterns.unwantedEndChars)
        else { return nil }
        let inner = patterns.innerMatches.compactMap(make)
        guard inner.count == patterns.innerMatches.count else { return nil }

        return Compiled(
            candidate: candidate, matchingBrackets: brackets, pubPages: pubPages,
            slashDates: slashDates, timeStamps: timeStamps,
            timeStampsSuffix: timeStampsSuffix, leadClass: leadClass,
            unwantedEndChars: unwanted, innerMatches: inner
        )
    }()

    public static var isReady: Bool { compiled != nil }

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
    public func matches() -> [PhoneMatch] {
        guard let compiled = Self.compiled else { return [] }
        var results: [PhoneMatch] = []
        var searchFrom = 0

        while searchFrom < scalars.count {
            let tail = substring(searchFrom..<scalars.count)
            guard let hit = compiled.candidate.matches(in: tail).first else { break }
            let start = searchFrom + hit.0
            var candidate = substring(start..<(searchFrom + hit.1))

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

    private static let latinLetters: Set<Unicode.Scalar> = {
        var set = Set<Unicode.Scalar>()
        for value in UInt32(65)...90 { set.insert(Unicode.Scalar(value)!) }
        for value in UInt32(97)...122 { set.insert(Unicode.Scalar(value)!) }
        return set
    }()

    private func isLatinLetter(_ scalar: Unicode.Scalar) -> Bool {
        // Accents and combining marks count as part of a letter upstream; the
        // ASCII range covers the cases the corpus exercises.
        Self.latinLetters.contains(scalar) || scalar.properties.isAlphabetic
    }

    private func isInvalidPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "%" || scalar == "$" || scalar == "@"
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
    ///
    /// STRICT_GROUPING and EXACT_GROUPING additionally require the candidate's
    /// digit grouping to match a canonical format for the region. Those are not
    /// implemented; they fall back to VALID, which is more permissive, so a
    /// caller asking for them may see extra matches. Presidio's default is
    /// VALID.
    private func verify(_ number: PhoneNumber, candidate: String) -> Bool {
        switch leniency {
        case .possible:
            return PhoneNumberUtil.isPossible(number)
        case .valid, .strictGrouping, .exactGrouping:
            guard PhoneNumberUtil.isValid(number),
                  containsOnlyValidXChars(candidate)
            else { return false }
            return PhoneNumberUtil.isNationalPrefixPresentIfRequired(
                number, raw: candidate
            )
        }
    }

    /// Port of `_contains_only_valid_x_chars`: an 'x' is either a carrier code
    /// (two or more) or an extension marker (exactly one), never a stray letter
    /// inside the number.
    private func containsOnlyValidXChars(_ candidate: String) -> Bool {
        let characters = Array(candidate)
        guard characters.count > 1 else { return true }
        var index = 0
        while index < characters.count - 1 {
            if characters[index] == "x" || characters[index] == "X" {
                let next = characters[index + 1]
                if next == "x" || next == "X" {
                    index += 1
                } else {
                    // A single 'x' must introduce an extension, so everything
                    // after it has to be digits.
                    let rest = String(characters[(index + 1)...])
                    if rest.contains(where: { !$0.isNumber && !$0.isWhitespace }) {
                        return false
                    }
                }
            }
            index += 1
        }
        return true
    }
}
