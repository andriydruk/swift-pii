import PresidioCore
import PresidioAnalyzer
import PresidioRecognizers
import PresidioRegex

/// Port of `RecognizerRegistry`.
///
/// Holds the recognizers available to an `AnalyzerEngine` and answers "which
/// of you can find these entities in this language".
public struct RecognizerRegistry: Sendable {

    public private(set) var recognizers: [any EntityRecognizing]
    public let supportedLanguages: [String]

    public init(
        recognizers: [any EntityRecognizing] = [],
        supportedLanguages: [String] = ["en"]
    ) {
        self.recognizers = recognizers
        self.supportedLanguages = supportedLanguages
    }

    public enum RegistryError: Error, Equatable, CustomStringConvertible {
        case noLanguage
        case noEntitiesRequested
        case noMatchingRecognizers

        public var description: String {
            switch self {
            case .noLanguage:
                return "no language provided"
            case .noEntitiesRequested:
                return "no entities requested and allFields is false"
            case .noMatchingRecognizers:
                return "no recognizer supports the requested entities in this language"
            }
        }
    }

    /// Port of `load_predefined_recognizers`.
    ///
    /// Two differences from upstream, both deliberate. Upstream discovers
    /// classes reflectively via `__subclasses__()`; there is no equivalent in
    /// Swift and the catalogue is already data, so this is a load rather than a
    /// scan. And the set loaded is driven by `RegistryConfiguration`, because
    /// a default Presidio engine loads 17 recognizers, not all 88 — most
    /// country-specific entries ship `enabled: false`.
    ///
    /// Pass `configuration: nil` to load the entire catalogue instead. That is
    /// a superset of Presidio's default behaviour and will report entities it
    /// would not.
    public static func loadPredefined(
        languages: [String] = ["en"],
        configuration: RegistryConfiguration? = RegistryConfiguration.default
    ) throws -> RecognizerRegistry {
        let definitions = try Catalog.definitions()
        var built: [any EntityRecognizing] = []

        /// Build one recognizer for one language.
        ///
        /// The catalogue definition supplies the patterns; the *language* comes
        /// from the caller, not from the definition. A definition's own
        /// `language` field records which upstream file it was harvested from,
        /// which is not the same question as which languages it is loaded for —
        /// `CreditCardRecognizer` lives in an English file and is configured
        /// for en, es, it and pl.
        func build(
            className: String, language: String, context: [String]?
        ) -> (any EntityRecognizing)? {
            if let definition = definitions.first(where: { $0.class == className }) {
                // The unqualified lookup returns the default variant, which is
                // the right one outside a fixture-specific conformance run.
                let logic = ValidatorRegistry.logic(for: className)
                guard var recognizer = Catalog.makeRecognizer(definition, logic: logic)
                else { return nil }
                recognizer = recognizer.withLanguage(language)
                // A config may override the class's context words per language.
                if let context = context ?? configuration?.contextOverride(
                    className: className, language: language
                ) {
                    recognizer = recognizer.withContext(context)
                }
                // ...and its regex flags, globally. See PatternRecognizer.withFlags.
                if let bits = configuration?.globalRegexFlags {
                    recognizer = recognizer.withFlags(RegexFlags(pythonFlags: bits))
                }
                return recognizer
            }
            return CustomRecognizerRegistry.make(className, language: language)
        }

        guard let configuration else {
            // No configuration: load the whole catalogue for the requested
            // languages. Each definition keeps its own language here, because
            // without a config there is nothing that says otherwise — and the
            // hand-written recognizers are filtered the same way rather than
            // being appended to every language indiscriminately, which is how
            // `ja` and `zh` used to come back with three Swift recognizers
            // written for English text.
            for definition in definitions where languages.contains(definition.language) {
                let logic = ValidatorRegistry.logic(for: definition.class)
                if let recognizer = Catalog.makeRecognizer(definition, logic: logic) {
                    built.append(recognizer)
                }
            }
            for className in CustomRecognizerRegistry.implemented.sorted() {
                guard let recognizer = CustomRecognizerRegistry.make(className),
                      languages.contains(recognizer.supportedLanguage)
                else { continue }
                built.append(recognizer)
            }
            return RecognizerRegistry(recognizers: built, supportedLanguages: languages)
        }

        for instruction in configuration.instantiations(languages: languages) {
            guard let recognizer = build(
                className: instruction.entry.className,
                language: instruction.language,
                context: instruction.context
            ) else { continue }
            built.append(recognizer)
        }
        return RecognizerRegistry(recognizers: built, supportedLanguages: languages)
    }

    public mutating func add(_ recognizer: any EntityRecognizing) {
        recognizers.append(recognizer)
    }

    /// Port of `remove_recognizer`: removes by name, not by identity.
    @discardableResult
    public mutating func remove(name: String) -> Int {
        let before = recognizers.count
        recognizers.removeAll { $0.name == name }
        return before - recognizers.count
    }

    /// Port of `get_recognizers`.
    ///
    /// Note the asymmetry inherited from upstream: an entity with no
    /// recognizer is merely logged and skipped, but an empty *overall* result
    /// raises. Asking for one unknown entity alongside a known one succeeds;
    /// asking for only unknown ones fails.
    public func recognizers(
        language: String,
        entities: [String]? = nil,
        allFields: Bool = false,
        adHoc: [any EntityRecognizing] = []
    ) throws -> [any EntityRecognizing] {
        guard !language.isEmpty else { throw RegistryError.noLanguage }
        guard entities != nil || allFields else { throw RegistryError.noEntitiesRequested }

        let candidates = recognizers + adHoc
        var selected: [any EntityRecognizing]

        if allFields {
            selected = candidates.filter { $0.supportedLanguage == language }
        } else {
            var picked: [String: any EntityRecognizing] = [:]
            for entity in entities ?? [] {
                for recognizer in candidates
                where recognizer.supportedEntities.contains(entity)
                    && recognizer.supportedLanguage == language {
                    picked[recognizer.id] = recognizer
                }
            }
            selected = Array(picked.values)
        }

        guard !selected.isEmpty else { throw RegistryError.noMatchingRecognizers }

        // Python returns `list(set(...))`, whose order is hash-randomized. The
        // engine's own output ordering is normalized downstream, but recognizer
        // order still decides which of two equal-scoring duplicates survives
        // `remove_duplicates`, so it is pinned here instead of left to chance.
        selected.sort { $0.id < $1.id }
        return selected
    }

    public func supportedEntities(language: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for recognizer in recognizers where recognizer.supportedLanguage == language {
            for entity in recognizer.supportedEntities where seen.insert(entity).inserted {
                out.append(entity)
            }
        }
        return out.sorted()
    }
}

