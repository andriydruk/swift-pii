import Foundation
import PresidioRegex

/// A parsed phone number: country calling code plus national significant number.
public struct PhoneNumber: Sendable, Hashable {
    public let countryCode: Int
    /// Digits only, national prefix stripped, leading zeros removed — the same
    /// normalization libphonenumber applies before validation.
    public let nationalNumber: String

    public init(countryCode: Int, nationalNumber: String) {
        self.countryCode = countryCode
        self.nationalNumber = nationalNumber
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

public enum PhoneParseError: Error, Equatable {
    /// Mirrors `NumberParseException.NOT_A_NUMBER` (0), `TOO_SHORT_NSN` (2),
    /// `TOO_LONG` (3) — the codes the oracle records.
    case notANumber
    case tooShort
    case tooLong
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

        enum CodingKeys: String, CodingKey {
            case countryCode = "country_code"
            case nationalPrefix = "national_prefix"
            case nationalPrefixForParsing = "national_prefix_for_parsing"
            case nationalPrefixTransformRule = "national_prefix_transform_rule"
            case leadingDigits = "leading_digits"
            case mainCountryForCode = "main_country_for_code"
            case generalDesc = "general_desc"
            case fixedLine = "fixed_line"
            case mobile, tollFree = "toll_free"
            case premiumRate = "premium_rate"
            case sharedCost = "shared_cost"
            case personalNumber = "personal_number"
            case voip, pager, uan, voicemail
        }
    }

    struct Metadata: Decodable {
        let regions: [String: Region]
        let regionsByCountryCode: [String: [String]]

        enum CodingKeys: String, CodingKey {
            case regions
            case regionsByCountryCode = "regions_by_country_code"
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
    static func fullMatch(_ pattern: String, _ text: String) -> Bool {
        guard let regex = regex(pattern) else { return false }
        let length = text.unicodeScalars.count
        return regex.matches(in: text).contains { $0.0 == 0 && $0.1 == length }
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
        let markers = ["ext.", "ext", "extension", "x", "#", ";"]
        let lowered = text.lowercased()
        var cut: String.Index?
        for marker in markers {
            guard let range = lowered.range(of: marker) else { continue }
            // The marker must follow at least one digit, so a leading "#" in a
            // short code is not mistaken for an extension.
            let head = lowered[lowered.startIndex..<range.lowerBound]
            guard head.contains(where: \.isNumber) else { continue }
            if cut == nil || range.lowerBound < cut! { cut = range.lowerBound }
        }
        guard let cut else { return text }
        return String(text[text.startIndex..<cut])
    }

    // MARK: - Parse

    /// Port of `phonenumbers.parse`, reduced to what the recognizer needs:
    /// no extensions, no alpha characters, no raw-input retention.
    public static func parse(
        _ text: String, defaultRegion: String?
    ) throws(PhoneParseError) -> PhoneNumber {
        guard let metadata else { throw .notANumber }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .notANumber }

        let hasPlus = trimmed.contains("+")
        // Strip an extension before taking digits, or "ext. 22" would be
        // appended to the national number and every such case would fail.
        var digits = digitsOnly(stripExtension(trimmed))
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
            digits = stripNationalPrefix(digits, region: regionData)
        }

        guard digits.count >= 2 else { throw .tooShort }
        guard digits.count <= 17 else { throw .tooLong }
        // libphonenumber drops leading zeros from the national number unless
        // the region marks them significant; none of the twelve here does.
        let national = String(digits.drop { $0 == "0" })
        return PhoneNumber(
            countryCode: countryCode,
            nationalNumber: national.isEmpty ? digits : national
        )
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

    // MARK: - Validation

    public static func isPossible(_ number: PhoneNumber) -> Bool {
        guard let region = mainRegion(forCountryCode: number.countryCode),
              let general = region.generalDesc
        else { return false }
        let length = number.nationalNumber.count
        if general.possibleLength.isEmpty { return true }
        return general.possibleLength.contains(length)
            || general.possibleLengthLocalOnly.contains(length)
    }

    public static func isValid(_ number: PhoneNumber) -> Bool {
        regionCode(for: number) != nil
    }

    public static func type(of number: PhoneNumber) -> PhoneNumberType {
        guard let code = regionCode(for: number),
              let region = metadata?.regions[code]
        else { return .unknown }
        return type(of: number.nationalNumber, in: region)
    }

    static func type(of national: String, in region: Region) -> PhoneNumberType {
        func matches(_ descriptor: Descriptor?) -> Bool {
            guard let descriptor, !descriptor.nationalNumberPattern.isEmpty
            else { return false }
            return fullMatch(descriptor.nationalNumberPattern, national)
        }
        // Order matters: libphonenumber checks the specific types before the
        // fixed-line/mobile pair, and reports fixedLineOrMobile when both hit.
        if matches(region.premiumRate) { return .premiumRate }
        if matches(region.tollFree) { return .tollFree }
        if matches(region.sharedCost) { return .sharedCost }
        if matches(region.voip) { return .voip }
        if matches(region.personalNumber) { return .personalNumber }
        if matches(region.pager) { return .pager }
        if matches(region.uan) { return .uan }
        if matches(region.voicemail) { return .voicemail }

        let fixed = matches(region.fixedLine)
        let mobile = matches(region.mobile)
        if fixed { return mobile ? .fixedLineOrMobile : .fixedLine }
        if mobile { return .mobile }
        return .unknown
    }

    /// Which region a number belongs to, or nil when it is not valid anywhere
    /// under its country code.
    public static func regionCode(for number: PhoneNumber) -> String? {
        guard let metadata,
              let candidates = metadata.regionsByCountryCode[String(number.countryCode)]
        else { return nil }
        // A single-region code needs only a validity check; a shared code
        // (+1 is US and CA) is disambiguated by leading digits, then by which
        // region's patterns the number actually matches.
        for code in candidates {
            guard let region = metadata.regions[code] else { continue }
            if let leading = region.leadingDigits, !leading.isEmpty {
                if let regex = regex("^(?:" + leading + ")"),
                   regex.matches(in: number.nationalNumber).contains(where: { $0.0 == 0 }) {
                    return code
                }
                continue
            }
            // Full validity, not just a general-descriptor match: the general
            // pattern is deliberately loose, so accepting it alone reports a
            // region for numbers libphonenumber rejects outright.
            if isValid(number.nationalNumber, in: region) { return code }
        }
        return nil
    }

    /// A number is valid for a region when its length is possible *and* it
    /// matches the general descriptor *and* it resolves to a known type.
    static func isValid(_ national: String, in region: Region) -> Bool {
        guard let general = region.generalDesc else { return false }
        if !general.possibleLength.isEmpty,
           !general.possibleLength.contains(national.count) {
            return false
        }
        guard fullMatch(general.nationalNumberPattern, national) else { return false }
        return type(of: national, in: region) != .unknown
    }

    static func mainRegion(forCountryCode code: Int) -> Region? {
        guard let metadata,
              let candidates = metadata.regionsByCountryCode[String(code)],
              let first = candidates.first
        else { return nil }
        return metadata.regions[first]
    }
}
