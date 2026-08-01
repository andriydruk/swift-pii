import PresidioCore
import PresidioAnalyzer

/// Port of `ZaPhoneNumberRecognizer` and its two concrete subclasses.
///
/// Upstream splits South African numbers into mobile and telephone lines and
/// gives each its own entity, so a single recognizer would not do: the two
/// differ only in which classification they keep.
///
/// Classification is libphonenumber's `number_type` first, and a digit-prefix
/// fallback only when the metadata says UNKNOWN. That order matters — the
/// prefix rules alone would call 086 and 087 mobile, since both start with 8.
public struct ZaPhoneNumberRecognizer: EntityRecognizing {

    public enum Classification: Sendable {
        case mobile
        case telephone
    }

    /// `REGION`. Both subclasses scan this one region, not the default eight.
    public static let region = "ZA"

    /// `MOBILE_TYPES`.
    static let mobileTypes: Set<PhoneNumberType> = [.mobile, .fixedLineOrMobile]

    /// `TELEPHONE_TYPES`.
    static let telephoneTypes: Set<PhoneNumberType> = [
        .fixedLine, .tollFree, .premiumRate, .voip,
        .sharedCost, .personalNumber, .uan, .pager,
    ]

    /// `CONTEXT` — `PhoneRecognizer.CONTEXT` plus the ZA-specific additions.
    public static let defaultContext = PhoneRecognizer.defaultContext + [
        "cellular", "handset", "contact number", "landline", "tel",
        "home number", "work number", "office number", "sms", "whatsapp",
    ]

    public let name: String
    public var id: String { "\(name)#custom" }
    public let entity: String
    public var supportedEntities: [String] { [entity] }
    public let context: [String]
    public let target: Classification
    public let leniency: PhoneLeniency

    public init(
        name: String,
        entity: String,
        target: Classification,
        leniency: PhoneLeniency = .valid,
        context: [String] = ZaPhoneNumberRecognizer.defaultContext
    ) {
        self.name = name
        self.entity = entity
        self.target = target
        self.leniency = leniency
        self.context = context
    }

    public static func mobile(
        entity: String = "ZA_MOBILE_NUMBER", leniency: PhoneLeniency = .valid
    ) -> ZaPhoneNumberRecognizer {
        ZaPhoneNumberRecognizer(
            name: "ZaMobileNumberRecognizer", entity: entity,
            target: .mobile, leniency: leniency
        )
    }

    public static func telephone(
        entity: String = "ZA_TELEPHONE_NUMBER", leniency: PhoneLeniency = .valid
    ) -> ZaPhoneNumberRecognizer {
        ZaPhoneNumberRecognizer(
            name: "ZaTelephoneNumberRecognizer", entity: entity,
            target: .telephone, leniency: leniency
        )
    }

    /// Ignores `entities` and `artifacts`; see `PhoneRecognizer`.
    public func analyze(
        _ text: String, entities: [String], artifacts: NlpArtifacts?
    ) -> [RecognizerResult] {
        analyze(text)
    }

    public func analyze(_ text: String) -> [RecognizerResult] {
        var results: [RecognizerResult] = []
        let matcher = PhoneNumberMatcher(
            text: text, region: Self.region, leniency: leniency
        )
        for match in matcher.matches() {
            // A +44 number found while scanning as ZA is not a ZA number.
            guard PhoneNumberUtil.regionCode(for: match.number) == Self.region,
                  Self.classify(match.number) == target
            else { continue }
            results.append(
                RecognizerResult(
                    entityType: entity,
                    start: match.start,
                    end: match.end,
                    score: PhoneRecognizer.score,
                    recognitionMetadata: [
                        RecognizerResult.MetadataKey.recognizerName: name
                    ]
                )
            )
        }
        return PatternRecognizer.removeDuplicates(results)
    }

    /// Port of `_classify`.
    static func classify(_ number: PhoneNumber) -> Classification? {
        let type = PhoneNumberUtil.type(of: number)
        if mobileTypes.contains(type) { return .mobile }
        if telephoneTypes.contains(type) { return .telephone }
        // A type that is known but in neither set (voicemail) is neither.
        guard type == .unknown else { return nil }
        return classifyByNSNPrefix(number.nationalNumber)
    }

    /// Port of `_classify_by_nsn_prefix`.
    ///
    /// Upstream reads `str(parsed_number.national_number)`, which is the
    /// integer — so leading zeros are already gone and the first digit is the
    /// area/network code's first digit, not a trunk zero.
    static func classifyByNSNPrefix(_ nsn: String) -> Classification? {
        guard let first = nsn.first else { return nil }
        if first == "6" || first == "7" { return .mobile }
        if nsn.hasPrefix("80") || nsn.hasPrefix("86") || nsn.hasPrefix("87") {
            return .telephone
        }
        if first == "8" { return .mobile }
        if "123459".contains(first) { return .telephone }
        return nil
    }
}
