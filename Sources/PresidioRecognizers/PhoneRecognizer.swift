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
    /// The language is part of the identity, not decoration. Upstream builds
    /// one instance per language, and a registry serving several would
    /// otherwise hold several recognizers sharing an id — which is the key the
    /// engine routes context enhancement back through.
    public var id: String { "PhoneRecognizer#custom#\(supportedLanguage)" }
    public let entity: String
    public var supportedEntities: [String] { [entity] }
    public let context: [String]
    public let regions: [String]
    public let leniency: PhoneLeniency
    public let supportedLanguage: String

    public init(
        entity: String = "PHONE_NUMBER",
        regions: [String] = PhoneRecognizer.defaultRegions,
        leniency: PhoneLeniency = .valid,
        context: [String] = PhoneRecognizer.defaultContext,
        supportedLanguage: String = "en"
    ) {
        self.entity = entity
        self.regions = regions
        self.leniency = leniency
        self.context = context
        self.supportedLanguage = supportedLanguage
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
    /// - Parameter language: which language this instance answers to. These are
    ///   *predefined* recognizers in upstream's sense — "custom" here means only
    ///   that they cannot be built from extracted pattern data — so they are
    ///   instantiated per language exactly like the pattern ones. Appending a
    ///   single English instance regardless of the requested language is how a
    ///   Japanese registry used to come back holding an English phone matcher.
    public static func make(
        _ className: String, language: String = "en"
    ) -> (any EntityRecognizing)? {
        switch className {
        case "PhoneRecognizer":
            return PhoneRecognizer(supportedLanguage: language)
        case "ZaMobileNumberRecognizer":
            return ZaPhoneNumberRecognizer.mobile(supportedLanguage: language)
        case "ZaTelephoneNumberRecognizer":
            return ZaPhoneNumberRecognizer.telephone(supportedLanguage: language)
        default: return nil
        }
    }

    public static let implemented: Set<String> = [
        "PhoneRecognizer", "ZaMobileNumberRecognizer", "ZaTelephoneNumberRecognizer",
    ]
}
