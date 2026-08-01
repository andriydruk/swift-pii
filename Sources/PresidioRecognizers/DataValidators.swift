import Foundation
import PresidioCore
import PresidioAnalyzer

/// Validators that need bulk data rather than arithmetic.
///
/// These were the last recognizers blocked: a public suffix list, India's RTO
/// district tables, Singapore's UEN alphabets, South Africa's legacy company
/// prefixes, and Bitcoin's base58/bech32 encodings. The data is extracted by
/// `Tools/extract_recognizer_data.py`; only the logic lives here.
public enum DataValidators {

    struct Data: Decodable {
        struct PSL: Decodable {
            let normal: [String]
            let wildcard: [String]
            let exception: [String]
        }
        struct India: Decodable {
            let stateRtoDistrictMap: [String: [String]]
            let diplomaticCodes: [String]
            let foreignMissionCodes: [Int]
            let twoFactorRegistrationPrefix: [String]

            enum CodingKeys: String, CodingKey {
                case stateRtoDistrictMap = "state_rto_district_map"
                case diplomaticCodes = "diplomatic_codes"
                case foreignMissionCodes = "foreign_mission_codes"
                case twoFactorRegistrationPrefix = "two_factor_registration_prefix"
            }
        }
        struct SgUen: Decodable {
            let formatAWeight: [Int]
            let formatAAlphabet: String
            let formatBWeight: [Int]
            let formatBAlphabet: String
            let formatCWeight: [Int]
            let formatCAlphabet: String
            let formatCPrefix: [String]
            let formatCEntityType: [String]

            enum CodingKeys: String, CodingKey {
                case formatAWeight = "UEN_FORMAT_A_WEIGHT"
                case formatAAlphabet = "UEN_FORMAT_A_ALPHABET"
                case formatBWeight = "UEN_FORMAT_B_WEIGHT"
                case formatBAlphabet = "UEN_FORMAT_B_ALPHABET"
                case formatCWeight = "UEN_FORMAT_C_WEIGHT"
                case formatCAlphabet = "UEN_FORMAT_C_ALPHABET"
                case formatCPrefix = "UEN_FORMAT_C_PREFIX"
                case formatCEntityType = "UEN_FORMAT_C_ENTITY_TYPE"
            }
        }
        struct ZaCompany: Decodable {
            let legacyPrefixes: [String]
            enum CodingKeys: String, CodingKey {
                case legacyPrefixes = "LEGACY_PREFIXES"
            }
        }

        let publicSuffixList: PSL
        let indiaVehicle: India
        let sgUen: SgUen
        let zaCompany: ZaCompany

        enum CodingKeys: String, CodingKey {
            case publicSuffixList = "public_suffix_list"
            case indiaVehicle = "india_vehicle"
            case sgUen = "sg_uen"
            case zaCompany = "za_company"
        }
    }

    /// Why the bundled data failed to load, if it did.
    ///
    /// A nil `data` makes every validator here return `.invalid`, which looks
    /// exactly like "nothing validates" rather than "the resource is broken".
    /// One missing key — `LEGACY_PREFIXES`, which the extractor initially
    /// skipped because `frozenset(...)` is a call rather than a literal — took
    /// all five validators down silently. `loadFailure` exists so a test can
    /// assert the data is actually present.
    static let loaded: Result<Data, LoadError> = {
        guard let url = Bundle.module.url(
            forResource: "recognizer_data", withExtension: "json"
        ) else { return .failure(.missing) }
        do {
            return .success(try JSONDecoder().decode(
                Data.self, from: try Foundation.Data(contentsOf: url)
            ))
        } catch {
            return .failure(.undecodable(String(describing: error)))
        }
    }()

    enum LoadError: Error {
        case missing
        case undecodable(String)
    }

    static var data: Data? { try? loaded.get() }

    /// True when the bundled data decoded. Asserted by the conformance suite.
    public static var isDataLoaded: Bool { data != nil }

    /// Why the data failed to load, if it did.
    public static var loadFailure: String? {
        switch loaded {
        case .success: return nil
        case .failure(.missing): return "recognizer_data.json missing from the bundle"
        case .failure(.undecodable(let detail)): return "recognizer_data.json: \(detail)"
        }
    }

    private static let normalSuffixes: Set<String> =
        Set(data?.publicSuffixList.normal ?? [])
    private static let wildcardSuffixes: Set<String> =
        Set(data?.publicSuffixList.wildcard ?? [])
    private static let exceptionSuffixes: Set<String> =
        Set(data?.publicSuffixList.exception ?? [])

    // MARK: - Email

    /// `EmailRecognizer.validate_result` is `tldextract.extract(text).fqdn != ""`,
    /// which is true when the host has a recognized public suffix *and* a
    /// non-empty registrable label in front of it.
    ///
    /// So `user@presidio.site` validates, `user@presidio.` does not, and a bare
    /// public suffix such as `user@co.uk` does not either — the suffix consumes
    /// the whole host, leaving no domain.
    public static func email(_ text: String) -> Validation {
        guard let atIndex = text.lastIndex(of: "@") else { return .invalid }
        let host = String(text[text.index(after: atIndex)...]).lowercased()
        guard !host.isEmpty else { return .invalid }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
            .map(String.init)
        guard labels.count >= 2, !labels.contains(where: \.isEmpty) else { return .invalid }

        let suffixLabels = publicSuffixLength(labels)
        // A registrable domain needs at least one label ahead of the suffix.
        guard suffixLabels > 0, labels.count > suffixLabels else { return .invalid }
        return .valid
    }

    /// Number of trailing labels forming the public suffix, per PSL rules:
    /// exceptions beat wildcards, wildcards beat exact matches, longest wins.
    static func publicSuffixLength(_ labels: [String]) -> Int {
        var best = 0
        for start in 0..<labels.count {
            let candidate = labels[start...].joined(separator: ".")
            let length = labels.count - start
            if exceptionSuffixes.contains(candidate) {
                // `!city.kawasaki.jp` means the wildcard does not apply here,
                // so the suffix is one label shorter.
                return max(length - 1, 0)
            }
            if normalSuffixes.contains(candidate) { best = max(best, length) }
            if start > 0 {
                let parent = labels[start...].joined(separator: ".")
                if wildcardSuffixes.contains(parent) { best = max(best, length + 1) }
            }
        }
        // An unknown TLD still counts as a suffix, which is what tldextract's
        // `suffix` does for the ICANN-plus-private list it ships.
        if best == 0, let last = labels.last, normalSuffixes.contains(last) { best = 1 }
        return best
    }

    // MARK: - Singapore UEN

    public static func singaporeUen(_ text: String) -> Validation {
        guard let sg = data?.sgUen else { return .invalid }
        let value = Array(text.uppercased())

        func weighted(_ characters: ArraySlice<Character>, _ weights: [Int]) -> Int? {
            var sum = 0
            for (character, weight) in zip(characters, weights) {
                guard let digit = character.wholeNumberValue, character.isNumber
                else { return nil }
                sum += digit * weight
            }
            return sum
        }

        switch value.count {
        case 9:
            // Format A: 8 digits plus an alphabet check character.
            guard let sum = weighted(value.dropLast(), sg.formatAWeight) else { return .invalid }
            let alphabet = Array(sg.formatAAlphabet)
            return alphabet[sum % 11] == value[8] ? .valid : .invalid

        case 10 where value[0].isLetter:
            // Format C: T/S/R prefix, a two-letter entity type, and a check
            // character drawn from a 32-symbol alphabet.
            guard sg.formatCPrefix.contains(String(value[0])) else { return .invalid }
            let entityType = String(value[3..<5])
            guard sg.formatCEntityType.contains(entityType) else { return .invalid }
            let alphabet = Array(sg.formatCAlphabet)
            var sum = 0
            for (character, weight) in zip(value.dropLast(), sg.formatCWeight) {
                guard let index = alphabet.firstIndex(of: character) else { return .invalid }
                sum += index * weight
            }
            // Python's `%` on a negative left operand returns a non-negative
            // result; Swift's does not, so normalize.
            let index = ((sum - 5) % 11 + 11) % 11
            return alphabet[index] == value[9] ? .valid : .invalid

        case 10:
            // Format B: year of registration then 5 digits and a check letter.
            guard let year = Int(String(value[0..<4])) else { return .invalid }
            // Compares against the current year, so this validator is
            // time-dependent by construction — as upstream's is.
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let currentYear = calendar.component(.year, from: Foundation.Date())
            guard year <= currentYear else { return .invalid }
            guard let sum = weighted(value.dropLast(), sg.formatBWeight) else { return .invalid }
            let alphabet = Array(sg.formatBAlphabet)
            return alphabet[sum % 11] == value[9] ? .valid : .invalid

        default:
            return .invalid
        }
    }

    // MARK: - South Africa company registration

    public static func zaCompanyRegistration(_ text: String) -> Validation {
        guard let za = data?.zaCompany else { return .invalid }
        let value = text.uppercased()
        let parts = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let currentYear = calendar.component(.year, from: Foundation.Date())

        func plausibleYear(_ text: String) -> Bool {
            guard text.count == 4, text.allSatisfy(\.isNumber), let year = Int(text)
            else { return false }
            return year >= 1800 && year <= currentYear
        }

        // Modern: YYYY/NNNNNN/TT
        if parts.count == 3, parts[0].allSatisfy(\.isNumber) {
            guard parts[1].allSatisfy(\.isNumber), parts[2].allSatisfy(\.isNumber),
                  parts[0].count == 4, parts[1].count == 6, parts[2].count == 2,
                  plausibleYear(parts[0])
            else { return .invalid }
            return .valid
        }

        // Legacy: <prefix>YYYY/NNNNNN, e.g. CK2001/123456
        if parts.count == 2 {
            let prefixAndYear = parts[0]
            guard parts[1].count == 6, parts[1].allSatisfy(\.isNumber) else { return .invalid }
            // Longest prefix first, so "NR" is preferred over "N".
            for prefix in za.legacyPrefixes.sorted(by: { $0.count > $1.count })
            where prefixAndYear.hasPrefix(prefix) {
                let year = String(prefixAndYear.dropFirst(prefix.count))
                if plausibleYear(year) { return .valid }
            }
            return .invalid
        }
        return .invalid
    }

    // MARK: - India vehicle registration

    /// Note the tri-state. Upstream initialises `is_valid_registration` to
    /// `None` and only ever sets it to `True`, so anything that fails to match
    /// returns **None**, not False — the plate keeps its pattern score instead
    /// of being discarded. Returning `.invalid` here silently drops four of the
    /// ten upstream cases.
    public static func indiaVehicleRegistration(_ text: String) -> Validation {
        guard let india = data?.indiaVehicle else { return .unknown }
        let sanitized = Checksums.sanitize(
            text, replacing: [("-", ""), (" ", ""), (":", "")]
        )
        guard sanitized.count >= 8 else { return .unknown }
        let value = Array(sanitized)
        let statePrefix = String(value[0..<2]).uppercased()

        // Standard registration: state prefix, 1-2 digit district code, and a
        // trailing 4-digit serial.
        if india.twoFactorRegistrationPrefix.contains(statePrefix), value[2].isNumber {
            let districtCode = value[3].isNumber
                ? String(value[2..<4])
                : String(value[2..<3])
            let serial = String(value.suffix(4))
            if serial.allSatisfy(\.isNumber), let number = Int(serial),
               number > 0, number <= 9999,
               let districts = india.stateRtoDistrictMap[statePrefix] {
                // Upstream accepts the code with or without a leading zero.
                let unpadded = Int(districtCode).map(String.init) ?? districtCode
                if districts.contains(districtCode) || districts.contains(unpadded) {
                    return .valid
                }
            }
        }

        // Diplomatic plates: a numeric mission code, then CC/CD/UN.
        for code in india.diplomaticCodes {
            guard let range = sanitized.range(of: code) else { continue }
            let prefix = String(sanitized[sanitized.startIndex..<range.lowerBound])
            guard !prefix.isEmpty, prefix.allSatisfy(\.isNumber),
                  let number = Int(prefix) else { continue }
            if (1...80).contains(number) || india.foreignMissionCodes.contains(number) {
                return .valid
            }
        }
        return .unknown
    }

    // MARK: - Crypto

    private static let base58Alphabet = Array(
        "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
    )

    /// Base58 decode, reproducing upstream's leading-zero handling: leading '1'
    /// characters become leading zero bytes.
    static func decodeBase58(_ text: String) -> [UInt8]? {
        let characters = Array(text)
        let originalLength = characters.count
        var stripped = characters.drop { $0 == "1" }
        let leadingZeros = originalLength - stripped.count

        // The value can exceed 64 bits, so accumulate base-256 digits by hand.
        var bytes: [UInt8] = []
        for character in stripped {
            guard let digit = base58Alphabet.firstIndex(of: character) else { return nil }
            var carry = digit
            for index in bytes.indices.reversed() {
                let value = Int(bytes[index]) * 58 + carry
                bytes[index] = UInt8(value & 0xFF)
                carry = value >> 8
            }
            while carry > 0 {
                bytes.insert(UInt8(carry & 0xFF), at: 0)
                carry >>= 8
            }
        }
        stripped = ArraySlice([])
        return [UInt8](repeating: 0, count: leadingZeros) + bytes
    }

    private static let bech32Charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
    private static let bech32mConstant = 0x2BC830A3

    static func bech32Polymod(_ values: [Int]) -> Int {
        let generator = [0x3B6A57B2, 0x26508E6D, 0x1EA119FA, 0x3D4233DD, 0x2A1462B3]
        var checksum = 1
        for value in values {
            let top = checksum >> 25
            checksum = ((checksum & 0x1FFFFFF) << 5) ^ value
            for index in 0..<5 where (top >> index) & 1 == 1 {
                checksum ^= generator[index]
            }
        }
        return checksum
    }

    static func bech32Valid(_ address: String) -> Bool {
        // Mixed case is rejected outright, as is anything outside printable
        // ASCII — both are bech32 rules, not conveniences.
        guard address.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 }),
              address.lowercased() == address || address.uppercased() == address
        else { return false }
        let lowered = address.lowercased()
        guard lowered.count <= 90, let separator = lowered.lastIndex(of: "1") else { return false }
        let position = lowered.distance(from: lowered.startIndex, to: separator)
        guard position >= 1, position + 7 <= lowered.count else { return false }

        let humanReadable = String(lowered[lowered.startIndex..<separator])
        let payload = lowered[lowered.index(after: separator)...]
        var data: [Int] = []
        for character in payload {
            guard let index = bech32Charset.firstIndex(of: character) else { return false }
            data.append(index)
        }

        var expanded = humanReadable.unicodeScalars.map { Int($0.value) >> 5 }
        expanded.append(0)
        expanded += humanReadable.unicodeScalars.map { Int($0.value) & 31 }
        let checksum = bech32Polymod(expanded + data)
        return checksum == 1 || checksum == bech32mConstant
    }

    /// `CryptoRecognizer.validate_result`: base58 double-SHA-256 for legacy
    /// addresses, bech32/bech32m for `bc1`.
    public static func crypto(_ text: String) -> Validation {
        if text.hasPrefix("bc1") {
            return bech32Valid(text) ? .valid : .invalid
        }
        guard text.hasPrefix("1") || text.hasPrefix("3") else { return .invalid }
        guard let decoded = decodeBase58(text), decoded.count > 4 else { return .invalid }
        let body = Array(decoded[..<(decoded.count - 4)])
        let expected = Array(decoded[(decoded.count - 4)...])
        let checksum = Array(SHA2.sha256(SHA2.sha256(body)).prefix(4))
        return checksum == expected ? .valid : .invalid
    }
}
