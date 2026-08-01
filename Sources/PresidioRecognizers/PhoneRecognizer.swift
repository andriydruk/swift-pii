import PresidioCore
import PresidioAnalyzer

/// Port of `presidio_analyzer.predefined_recognizers.PhoneRecognizer`.
///
/// Runs libphonenumber's matcher once per configured region and merges the
/// results. Scanning per region is upstream's own approach and is why the same
/// number can be found several times before deduplication.
public struct PhoneRecognizer: EntityRecognizing {

    /// `PhoneRecognizer.SCORE`.
    public static let score = 0.4

    /// `DEFAULT_SUPPORTED_REGIONS`.
    public static let defaultRegions = ["US", "GB", "DE", "FR", "IL", "IN", "CA", "BR"]

    public static let defaultContext = [
        "phone", "number", "telephone", "cell", "cellphone", "mobile", "call",
    ]

    public let name = "PhoneRecognizer"
    public let id = "PhoneRecognizer#custom"
    public let entity: String
    public var supportedEntities: [String] { [entity] }
    public let context: [String]
    public let regions: [String]
    public let leniency: PhoneLeniency

    public init(
        entity: String = "PHONE_NUMBER",
        regions: [String] = PhoneRecognizer.defaultRegions,
        leniency: PhoneLeniency = .valid,
        context: [String] = PhoneRecognizer.defaultContext
    ) {
        self.entity = entity
        self.regions = regions
        self.leniency = leniency
        self.context = context
    }

    /// Ignores `entities` and `artifacts` for the same reasons
    /// `PatternRecognizer` does — see its `EntityRecognizing` conformance.
    public func analyze(
        _ text: String, entities: [String], artifacts: NlpArtifacts?
    ) -> [RecognizerResult] {
        analyze(text)
    }

    public func analyze(_ text: String) -> [RecognizerResult] {
        var results: [RecognizerResult] = []
        for region in regions {
            let matcher = PhoneNumberMatcher(
                text: text, region: region, leniency: leniency
            )
            for match in matcher.matches() {
                results.append(
                    RecognizerResult(
                        entityType: entity,
                        start: match.start,
                        end: match.end,
                        score: Self.score,
                        recognitionMetadata: [
                            RecognizerResult.MetadataKey.recognizerName: name
                        ]
                    )
                )
            }
        }
        // The same number is usually found under several regions, so the
        // dedup pass is not optional here.
        return PatternRecognizer.removeDuplicates(results)
    }
}

/// Recognizers that cannot be built from the extracted pattern data.
///
/// Keyed by upstream class name, so the conformance suite can find them the
/// same way it finds pattern recognizers.
public enum CustomRecognizerRegistry {
    public static func make(_ className: String) -> (any EntityRecognizing)? {
        switch className {
        case "PhoneRecognizer": return PhoneRecognizer()
        case "ZaMobileNumberRecognizer": return ZaPhoneNumberRecognizer.mobile()
        case "ZaTelephoneNumberRecognizer": return ZaPhoneNumberRecognizer.telephone()
        default: return nil
        }
    }

    public static let implemented: Set<String> = [
        "PhoneRecognizer", "ZaMobileNumberRecognizer", "ZaTelephoneNumberRecognizer",
    ]
}
