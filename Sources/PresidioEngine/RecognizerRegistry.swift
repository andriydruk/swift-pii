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

    public enum RegistryError: Error, Equatable {
        case noLanguage
        case noEntitiesRequested
        case noMatchingRecognizers
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
        var built: [any EntityRecognizing] = []

        let enabled: Set<String>? = configuration.map { config in
            Set(languages.flatMap { config.enabledClassNames(language: $0) })
        }
        func isEnabled(_ className: String) -> Bool {
            enabled?.contains(className) ?? true
        }

        for definition in try Catalog.definitions() {
            guard languages.contains(definition.language),
                  isEnabled(definition.class)
            else { continue }
            // The unqualified lookup returns the default variant, which is the
            // right one outside a fixture-specific conformance run.
            let logic = ValidatorRegistry.logic(for: definition.class)
            guard var recognizer = Catalog.makeRecognizer(definition, logic: logic)
            else { continue }
            // A config may override the class's context words per language.
            if let override = configuration?.contextOverride(
                className: definition.class, language: definition.language
            ) {
                recognizer = recognizer.withContext(override)
            }
            // ...and its regex flags, globally. See PatternRecognizer.withFlags.
            if let bits = configuration?.globalRegexFlags {
                recognizer = recognizer.withFlags(RegexFlags(pythonFlags: bits))
            }
            built.append(recognizer)
        }

        for className in CustomRecognizerRegistry.implemented.sorted()
        where isEnabled(className) {
            if let recognizer = CustomRecognizerRegistry.make(className) {
                built.append(recognizer)
            }
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

