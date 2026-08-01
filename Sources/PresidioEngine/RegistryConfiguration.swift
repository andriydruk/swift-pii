import Foundation
import PresidioCore
import PresidioAnalyzer

/// Presidio's default recognizer registry configuration.
///
/// `AnalyzerEngine()` does not load every predefined recognizer: upstream ships
/// `conf/default_recognizers.yaml`, and most country-specific entries carry
/// `enabled: false`. A default English engine loads **17** of the 88 in the
/// catalogue. Loading everything instead is not a superset — it is a different
/// product, reporting entities Presidio never would.
///
/// The YAML is resolved to JSON by `Tools/extract_registry_config.py`, so
/// reproducing Presidio's defaults needs no YAML parser here. Reading a
/// *user's* YAML at runtime is a separate feature and is not implemented.
public struct RegistryConfiguration: Sendable, Decodable {

    public struct LanguageEntry: Sendable, Decodable {
        public let language: String
        /// Overrides the recognizer class's own context words for this
        /// language when present.
        public let context: [String]?
    }

    public struct Entry: Sendable, Decodable {
        public let name: String
        /// The class to instantiate, which a config may alias to a different
        /// display `name`.
        public let className: String
        public let type: String
        public let enabled: Bool
        public let languages: [LanguageEntry]
        public let countryCode: String?
        public let scoreThresholds: [String: Double]

        enum CodingKeys: String, CodingKey {
            case name
            case className = "class_name"
            case type, enabled, languages
            case countryCode = "country_code"
            case scoreThresholds = "score_thresholds"
        }
    }

    public let supportedLanguages: [String]
    /// Python `re` flag bits: 26 == DOTALL | MULTILINE | IGNORECASE.
    public let globalRegexFlags: Int?
    public let recognizers: [Entry]

    enum CodingKeys: String, CodingKey {
        case supportedLanguages = "supported_languages"
        case globalRegexFlags = "global_regex_flags"
        case recognizers
    }

    public static let `default`: RegistryConfiguration? = {
        guard let url = Bundle.module.url(
            forResource: "registry_config", withExtension: "json"
        ),
        let bytes = try? Data(contentsOf: url),
        let decoded = try? JSONDecoder().decode(RegistryConfiguration.self, from: bytes)
        else { return nil }
        return decoded
    }()

    /// Class names enabled for a language, in configuration order.
    ///
    /// Order is preserved rather than sorted: it is the order upstream
    /// instantiates recognizers in, and although the engine normalizes its
    /// output ordering, it still decides which of two identical results is
    /// kept by `remove_duplicates`.
    public func enabledClassNames(language: String) -> [String] {
        recognizers.filter { entry in
            entry.enabled && entry.languages.contains { $0.language == language }
        }.map(\.className)
    }

    /// The context override for a recognizer in a language, if the config
    /// declares one.
    public func contextOverride(className: String, language: String) -> [String]? {
        for entry in recognizers where entry.className == className {
            for lang in entry.languages where lang.language == language {
                if let context = lang.context { return context }
            }
        }
        return nil
    }

    public func scoreThresholds(className: String) -> [String: Double] {
        recognizers.first { $0.className == className }?.scoreThresholds ?? [:]
    }
}
