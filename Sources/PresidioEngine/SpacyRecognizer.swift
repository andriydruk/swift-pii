import PresidioCore
import PresidioAnalyzer

/// Port of `NerModelConfiguration`'s label handling.
///
/// The spaCy model emits its own labels (`GPE`, `ORG`, `NORP`); Presidio entity
/// types are different names with a many-to-one mapping. Upstream applies this
/// in the *NLP engine*, before any recognizer sees the artifacts, which is why
/// `SpacyRecognizer` compares `label_` directly against Presidio entity names.
public struct NerModelConfiguration: Sendable {

    /// `MODEL_TO_PRESIDIO_ENTITY_MAPPING`.
    public static let defaultMapping: [String: String] = [
        "PER": "PERSON", "PERSON": "PERSON",
        "LOC": "LOCATION", "LOCATION": "LOCATION", "GPE": "LOCATION",
        "ORG": "ORGANIZATION",
        "DATE": "DATE_TIME", "TIME": "DATE_TIME",
        "NORP": "NRP",
        "AGE": "AGE", "ID": "ID", "EMAIL": "EMAIL",
        "PATIENT": "PERSON", "STAFF": "PERSON", "HCW": "PERSON",
        "HOSP": "ORGANIZATION", "PATORG": "ORGANIZATION",
        "HOSPITAL": "ORGANIZATION",
        "PHONE": "PHONE_NUMBER",
    ]

    public let mapping: [String: String]
    public let labelsToIgnore: Set<String>
    /// spaCy reports no per-entity confidence, so every entity gets this.
    public let defaultScore: Double
    public let lowScoreEntityNames: Set<String>
    public let lowConfidenceScoreMultiplier: Double

    public init(
        mapping: [String: String] = NerModelConfiguration.defaultMapping,
        labelsToIgnore: Set<String> = [],
        defaultScore: Double = 0.85,
        lowScoreEntityNames: Set<String> = [],
        lowConfidenceScoreMultiplier: Double = 0.4
    ) {
        self.mapping = mapping
        self.labelsToIgnore = labelsToIgnore
        self.defaultScore = defaultScore
        self.lowScoreEntityNames = lowScoreEntityNames
        self.lowConfidenceScoreMultiplier = lowConfidenceScoreMultiplier
    }

    /// Port of `_get_updated_entities`.
    ///
    /// An unmapped label is kept under its own name rather than dropped —
    /// upstream logs a warning and carries on, so a model emitting a label
    /// Presidio has never heard of still produces results.
    public func applyMapping(
        _ entities: [NlpEntity], scores: [Double]
    ) -> ([NlpEntity], [Double]) {
        var outEntities: [NlpEntity] = []
        var outScores: [Double] = []
        for (entity, score) in zip(entities, scores) {
            guard !labelsToIgnore.contains(entity.label) else { continue }
            let label = mapping[entity.label] ?? entity.label
            var adjusted = score
            if lowScoreEntityNames.contains(label) {
                adjusted *= lowConfidenceScoreMultiplier
            }
            outEntities.append(
                NlpEntity(text: entity.text, label: label,
                          start: entity.start, end: entity.end)
            )
            outScores.append(adjusted)
        }
        return (outEntities, outScores)
    }
}

/// Port of `SpacyRecognizer`.
///
/// Runs no model of its own: the pipeline already ran, so this only lifts
/// entities out of the artifacts and re-labels them as recognizer results.
public struct SpacyRecognizer: EntityRecognizing {

    /// `SpacyRecognizer.ENTITIES`.
    public static let defaultEntities = [
        "DATE_TIME", "NRP", "LOCATION", "PERSON", "ORGANIZATION",
    ]

    public let id = "SpacyRecognizer#nlp"
    public let name = "SpacyRecognizer"
    public let supportedEntities: [String]
    public let supportedLanguage: String
    public let context: [String] = []

    public init(
        supportedEntities: [String] = SpacyRecognizer.defaultEntities,
        supportedLanguage: String = "en"
    ) {
        self.supportedEntities = supportedEntities
        self.supportedLanguage = supportedLanguage
    }

    public func analyze(
        _ text: String, entities: [String], artifacts: NlpArtifacts?
    ) -> [RecognizerResult] {
        // "Skipping SpaCy, nlp artifacts not provided" — no artifacts means no
        // results, not an error.
        guard let artifacts else { return [] }

        var results: [RecognizerResult] = []
        for (entity, score) in zip(artifacts.entities, artifacts.scores) {
            guard entities.contains(entity.label),
                  supportedEntities.contains(entity.label)
            else { continue }
            results.append(
                RecognizerResult(
                    entityType: entity.label,
                    start: entity.start,
                    end: entity.end,
                    score: score,
                    recognitionMetadata: [
                        RecognizerResult.MetadataKey.recognizerName: name,
                        RecognizerResult.MetadataKey.recognizerIdentifier: id,
                    ]
                )
            )
        }
        return results
    }
}
