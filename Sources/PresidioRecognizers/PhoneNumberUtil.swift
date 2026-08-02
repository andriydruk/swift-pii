import Foundation
import PresidioRegex

/// A parsed phone number: country calling code plus national significant number.
public struct PhoneNumber: Sendable, Hashable {
    public let countryCode: Int
    /// Digits with the national prefix stripped and leading zeros removed —
    /// libphonenumber's `national_number`, which is an integer there.
    public let nationalNumber: String
    /// How many leading zeros the national number had.
    public let leadingZeros: Int
    /// True when the country code came from the default region rather than
    /// from a leading `+`. libphonenumber calls this
    /// `country_code_source == FROM_DEFAULT_COUNTRY`, and it decides whether a
    /// national prefix is required.
    public let fromDefaultRegion: Bool
    /// Digits after an extension marker ("ext.", "x", "#"), or empty.
    ///
    /// Kept rather than discarded because the matcher needs it: an `x` in a
    /// candidate is only legitimate when what follows it *is* this extension.
    public let extensionDigits: String

    public init(
        countryCode: Int, nationalNumber: String,
        leadingZeros: Int = 0, fromDefaultRegion: Bool = false,
        extensionDigits: String = ""
    ) {
        self.countryCode = countryCode
        self.nationalNumber = nationalNumber
        self.leadingZeros = leadingZeros
        self.fromDefaultRegion = fromDefaultRegion
        self.extensionDigits = extensionDigits
    }

    /// `national_significant_number`: the national number with its leading
    /// zeros put back.
    ///
    /// This, not `nationalNumber`, is what validation matches. Missing the
    /// distinction makes `parse("020 7946 0958", "US")` look like a valid US
    /// number — the zero is not a US national prefix, so it stays part of the
    /// number and makes it 11 digits, which matches nothing.
    public var significantNumber: String {
        String(repeating: "0", count: leadingZeros) + nationalNumber
    }
}

/// libphonenumber's number types, in its own numbering so the differential
/// oracle can compare integers directly.
public enum PhoneNumberType: Int, Sendable {
    case fixedLine = 0
    case mobile = 1
    case fixedLineOrMobile = 2
    case tollFree = 3
    case premiumRate = 4
    case sharedCost = 5
    case voip = 6
    case personalNumber = 7
    case pager = 8
    case uan = 9
    case voicemail = 10
    case unknown = 99
}

public enum PhoneParseError: Error, Equatable, CustomStringConvertible {
    /// Mirrors `NumberParseException.NOT_A_NUMBER` (0), `TOO_SHORT_NSN` (2),
    /// `TOO_LONG` (3) — the codes the oracle records.
    case notANumber
    case tooShort
    case tooLong

    public var description: String {
        switch self {
        case .notANumber: return "not a phone number"
        case .tooShort: return "national number is too short"
        case .tooLong: return "national number is too long"
        }
    }
}

/// A port of the parts of `phonenumbers` that `PhoneRecognizer` depends on.
///
/// Presidio's phone recognizer has no regex of its own — it delegates entirely
/// to libphonenumber — so the behaviour lives in Google's metadata plus this
/// algorithm. The metadata is extracted by `Tools/extract_phone_metadata.py`
/// for the twelve regions the recognizers configure.
public enum PhoneNumberUtil {

    // MARK: - Metadata

    struct Descriptor: Decodable {
        let nationalNumberPattern: String
        let possibleLength: [Int]
        let possibleLengthLocalOnly: [Int]

        enum CodingKeys: String, CodingKey {
            case nationalNumberPattern = "national_number_pattern"
            case possibleLength = "possible_length"
            case possibleLengthLocalOnly = "possible_length_local_only"
        }
    }

    struct Region: Decodable {
        let countryCode: Int
        let nationalPrefix: String?
        let nationalPrefixForParsing: String?
        let nationalPrefixTransformRule: String?
        let leadingDigits: String?
        let mainCountryForCode: Bool
        let sameMobileAndFixedLinePattern: Bool
        let generalDesc: Descriptor?
        let fixedLine: Descriptor?
        let mobile: Descriptor?
        let tollFree: Descriptor?
        let premiumRate: Descriptor?
        let sharedCost: Descriptor?
        let personalNumber: Descriptor?
        let voip: Descriptor?
        let pager: Descriptor?
        let uan: Descriptor?
        let voicemail: Descriptor?
        let numberFormat: [NumberFormat]?
        let intlNumberFormat: [NumberFormat]?

        enum CodingKeys: String, CodingKey {
            case countryCode = "country_code"
            case nationalPrefix = "national_prefix"
            case nationalPrefixForParsing = "national_prefix_for_parsing"
            case nationalPrefixTransformRule = "national_prefix_transform_rule"
            case leadingDigits = "leading_digits"
            case mainCountryForCode = "main_country_for_code"
            case sameMobileAndFixedLinePattern = "same_mobile_and_fixed_line_pattern"
            case generalDesc = "general_desc"
            case fixedLine = "fixed_line"
            case mobile, tollFree = "toll_free"
            case premiumRate = "premium_rate"
            case sharedCost = "shared_cost"
            case personalNumber = "personal_number"
            case voip, pager, uan, voicemail
            case numberFormat = "number_format"
            case intlNumberFormat = "intl_number_format"
        }
    }

    struct NumberFormat: Decodable {
        let pattern: String
        /// Replacement rule, `\1 \2 \3` style — what turns a national number
        /// into its printed groups.
        let format: String
        let leadingDigitsPattern: [String]
        let nationalPrefixFormattingRule: String?
        let nationalPrefixOptionalWhenFormatting: Bool

        enum CodingKeys: String, CodingKey {
            case pattern, format
            case leadingDigitsPattern = "leading_digits_pattern"
            case nationalPrefixFormattingRule = "national_prefix_formatting_rule"
            case nationalPrefixOptionalWhenFormatting =
                "national_prefix_optional_when_formatting"
        }
    }

    struct Metadata: Decodable {
        let regions: [String: Region]
        let regionsByCountryCode: [String: [String]]
        /// Extra formats, by country calling code, that the grouping leniencies
        /// retry against when the canonical format does not match.
        let altNumberFormats: [String: [NumberFormat]]

        enum CodingKeys: String, CodingKey {
            case regions
            case regionsByCountryCode = "regions_by_country_code"
            case altNumberFormats = "alt_number_formats"
        }
    }

    static let metadata: Metadata? = {
        guard let url = Bundle.module.url(
            forResource: "phone_metadata", withExtension: "json"
        ), let bytes = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Metadata.self, from: bytes)
    }()

    public static var isMetadataLoaded: Bool { metadata != nil }
    public static var supportedRegions: [String] {
        (metadata?.regions.keys).map { Array($0).sorted() } ?? []
    }

    // MARK: - Compiled pattern cache
    //
    // Every descriptor pattern is a regex that must be anchored as a full match.
    // Compiling on each call would dominate the runtime, so patterns are
    // compiled once, at first use, behind a lock.

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var patternCache: [String: PureRegex] = [:]

    static func regex(_ pattern: String) -> PureRegex? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = patternCache[pattern] { return cached }
        guard let compiled = try? PureRegex(
            pattern, ignoreCase: false, dotAll: false, multiline: false
        ) else { return nil }
        patternCache[pattern] = compiled
        return compiled
    }

    /// libphonenumber matches descriptor patterns as *full* matches.
    ///
    /// Anchored at compile time rather than by filtering the results, and the
    /// difference is not cosmetic. Searching for a match and then asking
    /// whether it happens to span the whole string finds only the *leftmost*
    /// one, and never backtracks into the remaining alternatives. Turkey's
    /// general descriptor is
    ///
    ///     4\d{6}|8\d{11,12}|(?:[2-58]\d\d|900)\d{7}
    ///
    /// so for "4321234567" the first branch matches seven characters, the
    /// filter rejects it for being short, and the branch that *would* have
    /// matched all ten is never tried — making every Turkish landline
    /// invalid. Wrapping the pattern makes the engine do the backtracking.
    // Anchoring costs ~46% of engine throughput (3.3 -> 4.9 ms/document),
    // because `$` forces the engine to backtrack through large alternations
    // instead of stopping at the first branch that matches anything. Memoizing
    // the result was tried and returned 4%: documents hold different numbers,
    // so the cache rarely hits, and it is not worth another lock-protected
    // global. Correctness wins here — the unanchored version silently reported
    // every Turkish landline as invalid.
    static func fullMatch(_ pattern: String, _ text: String) -> Bool {
        guard let regex = regex("^(?:" + pattern + ")$") else { return false }
        return regex.matchesAnchored(text)
    }

    // MARK: - Normalization

    static func digitsOnly(_ text: String) -> String {
        String(text.unicodeScalars.compactMap { scalar -> Character? in
            guard let value = Character(scalar).wholeNumberValue,
                  (0...9).contains(value)
            else { return nil }
            return Character(String(value))
        })
    }

    /// Remove a trailing extension, as libphonenumber's extension pattern does.
    /// Only the common ASCII markers are handled; the twelve regions here use
    /// no others.
    static func stripExtension(_ text: String) -> String {
        splitExtension(text).number
    }

    /// Port of `_maybe_strip_extension`.
    ///
    /// Driven by libphonenumber's own `_EXTN_PATTERN`, not a list of markers.
    /// The pattern covers far more than "ext"/"x"/"#": `extn`, `int`, `anexo`,
    /// `доб`, full-width forms, `~`, `;`, `,,` and a bare trailing `#`. A
    /// hand-written marker list silently truncated every spelling it had not
    /// been told about, keeping the number but losing the extension — which
    /// then made the matcher reject the candidate for having a stray letter.
    ///
    /// The extension is only accepted when the text *before* the marker could
    /// itself be a phone number, so a "#" in the middle of prose is not read
    /// as one.
    static func splitExtension(_ text: String) -> (number: String, extension: String) {
        guard let extn = PhoneNumberMatcher.extensionRegex,
              let viable = PhoneNumberMatcher.viableNumberRegex
        else { return (text, "") }

        let scalars = Array(text.unicodeScalars)
        for match in extn.matchesWithGroups(in: text) {
            let head = String(String.UnicodeScalarView(scalars[0..<match.start]))
            guard head.unicodeScalars.count >= PhoneNumberMatcher.minLengthForNSN,
                  viable.matchesAnchored(head)
            else { continue }
            // "We go through the capturing groups until we find one that
            // captured some digits."
            guard match.groupCount >= 1 else { continue }
            for group in 1...match.groupCount {
                guard let span = match.span(group) else { continue }
                let digits = String(String.UnicodeScalarView(scalars[span]))
                if !digits.isEmpty { return (head, digits) }
            }
            return (head, "")
        }
        return (text, "")
    }

    // MARK: - Parse

    /// Port of `phonenumbers.parse`, reduced to what the recognizer needs:
    /// no extensions, no alpha characters, no raw-input retention.
    public static func parse(
        _ text: String, defaultRegion: String?
    ) throws(PhoneParseError) -> PhoneNumber {
        guard let metadata else { throw .notANumber }

        let trimmed = text.pythonStripped()
        guard !trimmed.isEmpty else { throw .notANumber }

        let hasPlus = trimmed.contains("+")
        // Strip an extension before taking digits, or "ext. 22" would be
        // appended to the national number and every such case would fail.
        let split = splitExtension(trimmed)
        var digits = digitsOnly(split.number)
        guard !digits.isEmpty else { throw .notANumber }

        var countryCode = 0
        if hasPlus {
            // An international number carries its own country code; find the
            // longest prefix (1-3 digits) that names a known code.
            var matched = false
            for length in 1...min(3, digits.count) {
                let candidate = String(digits.prefix(length))
                if metadata.regionsByCountryCode[candidate] != nil {
                    countryCode = Int(candidate) ?? 0
                    digits = String(digits.dropFirst(length))
                    matched = true
                    break
                }
            }
            guard matched else { throw .notANumber }
        } else {
            guard let region = defaultRegion,
                  let regionData = metadata.regions[region]
            else { throw .notANumber }
            countryCode = regionData.countryCode

            // A number may carry its own country code with no leading "+",
            // as "91-415-555-0132" and "11 98456 5666" do. Port of the
            // default-region branch of `_maybe_extract_country_code`: strip
            // the region's own calling code, then its national prefix, and
            // keep that reading only when it is *better* -- the original did
            // not match the general descriptor and the stripped one does, or
            // the original was too long to be dialable at all.
            let callingCode = String(regionData.countryCode)
            var extracted = false
            if digits.hasPrefix(callingCode), let general = regionData.generalDesc {
                let remainder = String(digits.dropFirst(callingCode.count))
                // The *raw* strip: inside `_maybe_extract_country_code`
                // upstream calls `_maybe_strip_national_prefix_carrier_code`
                // directly, and the length gate is a separate later step in
                // `parse`. Gating here would keep the "1" in "1984565666" and
                // lose the reading this branch exists to find.
                let candidate = stripNationalPrefix(remainder, region: regionData)
                let originalMatches = fullMatch(general.nationalNumberPattern, digits)
                let candidateMatches = fullMatch(general.nationalNumberPattern, candidate)
                if (!originalMatches && candidateMatches)
                    || testNumberLength(digits, region: regionData) == .tooLong {
                    digits = candidate
                    extracted = true
                }
            }

            // Upstream strips, then *checks the length of the result* and
            // keeps the original if stripping made it implausible:
            //
            //   validation_result = _test_number_length(potential, metadata)
            //   if validation_result not in (TOO_SHORT, IS_POSSIBLE_LOCAL_ONLY,
            //                                INVALID_LENGTH):
            //       normalized_national_number = potential
            //
            // Without that second gate, "123" in the US loses its leading 1 to
            // become "23", and a GB number written "09-7625400" loses the 0 it
            // needs — the strip is only accepted when it leaves something the
            // region could actually dial.
            if !extracted {
                digits = strippingNationalPrefix(digits, region: regionData)
            }
        }

        guard digits.count >= 2 else { throw .tooShort }
        guard digits.count <= 17 else { throw .tooLong }
        let stripped = String(digits.drop { $0 == "0" })
        let zeros = digits.count - stripped.count
        return PhoneNumber(
            countryCode: countryCode,
            nationalNumber: stripped.isEmpty ? digits : stripped,
            leadingZeros: stripped.isEmpty ? 0 : zeros,
            fromDefaultRegion: !hasPlus,
            extensionDigits: split.extension
        )
    }

    /// The national prefix removed, but only when the result is still a
    /// plausible length for the region — the two gates upstream applies in
    /// sequence. Returns the input unchanged when either gate refuses.
    static func strippingNationalPrefix(_ digits: String, region: Region) -> String {
        let candidate = stripNationalPrefix(digits, region: region)
        guard candidate != digits else { return digits }
        switch testNumberLength(candidate, region: region) {
        case .tooShort, .possibleLocalOnly, .invalidLength:
            return digits
        case .possible, .tooLong:
            return candidate
        }
    }

    /// Remove the national dialling prefix, honouring the region's parsing
    /// pattern and transform rule.
    static func stripNationalPrefix(_ digits: String, region: Region) -> String {
        guard let parsing = region.nationalPrefixForParsing, !parsing.isEmpty,
              let regex = regex("^(?:" + parsing + ")")
        else { return digits }
        guard let match = regex.matchesWithGroups(in: digits).first,
              match.start == 0, match.end > 0
        else { return digits }

        let scalars = Array(digits.unicodeScalars)
        let remainder = String(String.UnicodeScalarView(scalars[match.end...]))
        // A transform rule rewrites the number using the captured groups, as
        // Brazil's carrier-code handling does.
        if let rule = region.nationalPrefixTransformRule, !rule.isEmpty,
           match.groupCount >= 1, let first = match.span(1) {
            let captured = String(String.UnicodeScalarView(scalars[first]))
            let transformed = rule.replacingOccurrences(of: "$1", with: captured)
            return transformed + remainder
        }
        // Stripping must not produce something the region cannot represent.
        if let general = region.generalDesc?.nationalNumberPattern,
           fullMatch(general, digits), !fullMatch(general, remainder) {
            return digits
        }
        return remainder
    }

    // MARK: - Formatting
    //
    // Only as much of it as the grouping leniencies need: the digit groups a
    // number would be printed in. Ported from `_format_nsn` +
    // `_format_nsn_using_pattern` for RFC3966, which is the format upstream
    // uses precisely because its separator is unambiguous.

    /// The digit groups this number would be formatted into, or nil when no
    /// format pattern applies.
    ///
    /// Port of `_get_national_number_groups_without_pattern`, which formats as
    /// RFC3966 (`+CC-DG1-DG2-DGX`) and splits on the dashes.
    static func nationalNumberGroups(
        _ number: PhoneNumber, using explicit: NumberFormat? = nil
    ) -> [String]? {
        guard let region = mainRegion(forCountryCode: number.countryCode)
        else { return nil }
        let national = number.significantNumber

        let format: NumberFormat?
        if let explicit {
            format = explicit
        } else {
            // `_format_nsn`: international formats win when present, and
            // RFC3966 is an international format.
            let intl = region.intlNumberFormat ?? []
            let available = intl.isEmpty ? (region.numberFormat ?? []) : intl
            format = chooseFormat(available, for: national)
        }
        guard let format else { return nil }
        guard let formatted = applyFormat(format, to: national) else { return nil }
        return splitOnSeparators(formatted)
    }

    /// Alternate formats for a country code whose leading digits admit `nsn`.
    static func alternateFormats(
        countryCode: Int, nationalNumber nsn: String
    ) -> [NumberFormat] {
        guard let formats = metadata?.altNumberFormats[String(countryCode)]
        else { return [] }
        return formats.filter { format in
            // "There is only one leading digits pattern for alternate formats."
            guard let leading = format.leadingDigitsPattern.first else { return true }
            guard let regex = regex(leading) else { return false }
            return regex.matches(in: nsn).contains { $0.0 == 0 }
        }
    }

    /// Apply a format rule's backreferences to the national number.
    ///
    /// `re.sub(pattern, "\1 \2 \3", nsn)` in one step: full-match the
    /// pattern to capture the groups, then substitute them into the rule.
    static func applyFormat(_ format: NumberFormat, to national: String) -> String? {
        guard let regex = regex("^(?:" + format.pattern + ")$"),
              let match = regex.matchesWithGroups(in: national).first,
              match.start == 0
        else { return nil }

        let scalars = Array(national.unicodeScalars)
        var out = String.UnicodeScalarView()
        var iterator = Array(format.format.unicodeScalars).makeIterator()
        var pending: Unicode.Scalar? = iterator.next()
        while let scalar = pending {
            pending = iterator.next()
            guard scalar == "\\", let digit = pending,
                  let index = digit.properties.numericValue.map(Int.init), index >= 1
            else {
                out.append(scalar)
                continue
            }
            pending = iterator.next()
            guard index <= match.groupCount, let span = match.span(index) else {
                continue  // a group that did not participate contributes nothing
            }
            out.append(contentsOf: scalars[span])
        }
        return String(out)
    }

    /// RFC3966 post-processing: drop a leading separator run, then collapse
    /// every remaining run to a single dash — and return the pieces.
    static func splitOnSeparators(_ formatted: String) -> [String] {
        guard let separator = PhoneNumberMatcher.separatorRegex else {
            return [formatted]
        }
        var groups: [String] = []
        var current = String.UnicodeScalarView()
        let spans = separator.matches(in: formatted)
        let scalars = Array(formatted.unicodeScalars)
        var index = 0
        var inSeparator = 0
        for (start, end) in spans where end > start {
            while index < start { current.append(scalars[index]); index += 1 }
            if !current.isEmpty { groups.append(String(current)) }
            current = String.UnicodeScalarView()
            index = end
            inSeparator += 1
        }
        while index < scalars.count { current.append(scalars[index]); index += 1 }
        if !current.isEmpty { groups.append(String(current)) }
        return groups
    }

    /// Port of `ValidationResult`, for the length test below.
    enum LengthValidation {
        case possible
        case possibleLocalOnly
        case tooShort
        case tooLong
        case invalidLength
    }

    /// Port of `_test_number_length` with `numtype=UNKNOWN`, which resolves to
    /// the general description.
    ///
    /// Note `invalidLength` is distinct from `tooShort`/`tooLong`: a region
    /// whose possible lengths are 7, 9 and 10 rejects 8 as *invalid* rather
    /// than as too short. Collapsing the two would accept strips that upstream
    /// refuses.
    static func testNumberLength(
        _ national: String, region: Region
    ) -> LengthValidation {
        guard let general = region.generalDesc else { return .invalidLength }
        let lengths = general.possibleLength
        guard !lengths.isEmpty else { return .possible }

        let actual = national.count
        if general.possibleLengthLocalOnly.contains(actual) { return .possibleLocalOnly }

        let minimum = lengths[0]
        if minimum == actual { return .possible }
        if minimum > actual { return .tooShort }
        if let maximum = lengths.last, maximum < actual { return .tooLong }
        return lengths.dropFirst().contains(actual) ? .possible : .invalidLength
    }

    // MARK: - Validation
    //
    // Ported from `_number_type_helper`, `_is_number_matching_desc`,
    // `region_code_for_number` and `is_valid_number_for_region`. The structure
    // matters more than it looks: an earlier version required validity for
    // *every* region, which is not what libphonenumber does, and cost 32% of
    // region-resolution agreement.

    /// `_is_number_matching_desc`: possible-length gate, then a full pattern
    /// match. An empty pattern never matches.
    static func matchesDescriptor(_ national: String, _ descriptor: Descriptor?) -> Bool {
        guard let descriptor else { return false }
        if !descriptor.possibleLength.isEmpty,
           !descriptor.possibleLength.contains(national.count) {
            return false
        }
        guard !descriptor.nationalNumberPattern.isEmpty else { return false }
        return fullMatch(descriptor.nationalNumberPattern, national)
    }

    /// `_number_type_helper`. The general descriptor gates everything, and the
    /// specific types are checked before the fixed-line/mobile pair.
    static func numberTypeHelper(_ national: String, _ region: Region) -> PhoneNumberType {
        guard matchesDescriptor(national, region.generalDesc) else { return .unknown }
        if matchesDescriptor(national, region.premiumRate) { return .premiumRate }
        if matchesDescriptor(national, region.tollFree) { return .tollFree }
        if matchesDescriptor(national, region.sharedCost) { return .sharedCost }
        if matchesDescriptor(national, region.voip) { return .voip }
        if matchesDescriptor(national, region.personalNumber) { return .personalNumber }
        if matchesDescriptor(national, region.pager) { return .pager }
        if matchesDescriptor(national, region.uan) { return .uan }
        if matchesDescriptor(national, region.voicemail) { return .voicemail }

        if matchesDescriptor(national, region.fixedLine) {
            if region.sameMobileAndFixedLinePattern { return .fixedLineOrMobile }
            return matchesDescriptor(national, region.mobile) ? .fixedLineOrMobile : .fixedLine
        }
        if matchesDescriptor(national, region.mobile) { return .mobile }
        return .unknown
    }

    /// `is_possible_number`: a wrapper over `_test_number_length` that accepts
    /// both IS_POSSIBLE and IS_POSSIBLE_LOCAL_ONLY.
    ///
    /// Routed through the same length test the parser uses rather than
    /// re-deriving the rule, so the two cannot drift — an inline version here
    /// treated an out-of-range length as possible when the region declared no
    /// lengths, which `_test_number_length` does not.
    public static func isPossible(_ number: PhoneNumber) -> Bool {
        guard let region = mainRegion(forCountryCode: number.countryCode)
        else { return false }
        switch testNumberLength(number.significantNumber, region: region) {
        case .possible, .possibleLocalOnly: return true
        case .tooShort, .tooLong, .invalidLength: return false
        }
    }

    /// `is_valid_number`: resolve the region, then check the number really is
    /// of some known type there.
    public static func isValid(_ number: PhoneNumber) -> Bool {
        guard let code = regionCode(for: number),
              let region = metadata?.regions[code],
              region.countryCode == number.countryCode
        else { return false }
        return numberTypeHelper(number.significantNumber, region) != .unknown
    }

    public static func type(of number: PhoneNumber) -> PhoneNumberType {
        guard let code = regionCode(for: number),
              let region = metadata?.regions[code]
        else { return .unknown }
        return numberTypeHelper(number.significantNumber, region)
    }

    /// `region_code_for_number`.
    ///
    /// A country code with exactly one region returns it **unconditionally** —
    /// no validation at all. Only a shared code (+1 spans the US, Canada and
    /// the Caribbean; +44 spans GB, GG, IM and JE) is disambiguated, which is
    /// why the metadata includes every region sharing a code rather than just
    /// the twelve the recognizers name.
    public static func regionCode(for number: PhoneNumber) -> String? {
        guard let metadata,
              let candidates = metadata.regionsByCountryCode[String(number.countryCode)],
              !candidates.isEmpty
        else { return nil }
        if candidates.count == 1 { return candidates[0] }

        for code in candidates {
            guard let region = metadata.regions[code] else { continue }
            if let leading = region.leadingDigits, !leading.isEmpty {
                // A prefix match, not a full one — and note the `elif`: when
                // leading digits are present but do not match, the region is
                // skipped rather than falling through to the type check.
                if let regex = regex("^(?:" + leading + ")"),
                   regex.matches(in: number.significantNumber).contains(where: { $0.0 == 0 }) {
                    return code
                }
            } else if numberTypeHelper(number.significantNumber, region) != .unknown {
                return code
            }
        }
        return nil
    }

    /// Port of `_is_national_prefix_present_if_required`.
    ///
    /// A number written in international form never needs a national prefix.
    /// One written nationally does, when the format rule that applies to it
    /// says so — which is what rejects a Philippine mobile typed without its
    /// leading 0.
    public static func isNationalPrefixPresentIfRequired(
        _ number: PhoneNumber, raw: String
    ) -> Bool {
        guard number.fromDefaultRegion else { return true }
        guard let code = regionCode(for: number),
              let region = metadata?.regions[code],
              let formats = region.numberFormat
        else { return true }

        let national = number.significantNumber
        guard let rule = chooseFormat(formats, for: national),
              let prefixRule = rule.nationalPrefixFormattingRule,
              !prefixRule.isEmpty
        else { return true }
        if rule.nationalPrefixOptionalWhenFormatting { return true }
        // A rule that is just the first group plus punctuation does not carry a
        // national prefix, so none is required.
        if formattingRuleHasFirstGroupOnly(prefixRule) { return true }

        guard let prefix = region.nationalPrefix, !prefix.isEmpty else { return true }
        return digitsOnly(raw).hasPrefix(prefix)
    }

    /// `_choose_formatting_pattern_for_number`.
    static func chooseFormat(
        _ formats: [NumberFormat], for national: String
    ) -> NumberFormat? {
        for format in formats {
            let leading = format.leadingDigitsPattern
            // Only the last leading-digits pattern is checked, as a prefix.
            if let last = leading.last {
                guard let regex = regex("^(?:" + last + ")"),
                      regex.matches(in: national).contains(where: { $0.0 == 0 })
                else { continue }
            }
            if fullMatch(format.pattern, national) { return format }
        }
        return nil
    }

    /// `_formatting_rule_has_first_group_only`: the rule is `$1` with optional
    /// surrounding punctuation.
    static func formattingRuleHasFirstGroupOnly(_ rule: String) -> Bool {
        // `_FIRST_GROUP_ONLY_PREFIX_PATTERN` is `\(?\\1\)?` — an optional open
        // paren, the literal backreference, an optional close paren, matched in
        // full. Nothing else is permitted, so a rule carrying the national
        // prefix (`0\1`) or extra punctuation correctly fails.
        //
        // The backreference is spelled `\1`, not `$1`: `$1` is libphonenumber's
        // Java convention, and this metadata comes from python-phonenumbers,
        // which rewrites it. Testing for `$1` here silently never matched, so
        // every region whose format rule is first-group-only — Brazil's
        // `(\1)` among them — was treated as requiring a national prefix, and
        // every bare national number was rejected as a false positive.
        if rule.isEmpty { return true }
        var scalars = Substring(rule)
        if scalars.first == "(" { scalars = scalars.dropFirst() }
        if scalars.last == ")" { scalars = scalars.dropLast() }
        return scalars == "\\1"
    }

    static func mainRegion(forCountryCode code: Int) -> Region? {
        guard let metadata,
              let candidates = metadata.regionsByCountryCode[String(code)],
              let first = candidates.first
        else { return nil }
        return metadata.regions[first]
    }
}
