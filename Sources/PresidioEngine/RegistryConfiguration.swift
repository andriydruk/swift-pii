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

        public init(language: String, context: [String]? = nil) {
            self.language = language
            self.context = context
        }
    }

    public struct Entry: Sendable, Decodable {
        public let name: String
        /// The class to instantiate, which a config may alias to a different
        /// display `name`.
        public let className: String
        public let type: String
        public let enabled: Bool
        /// `nil` means the entry declared no `supported_languages` **at all**,
        /// which upstream reads as "every language the registry was asked for"
        /// — not as English. Eleven of the default entries are in this state,
        /// and they are the ones that make e-mail, IP, URL, IBAN and phone work
        /// in a language nobody listed them under. Collapsing `nil` to `["en"]`
        /// is exactly the bug this type now prevents.
        public let languages: [LanguageEntry]?
        public let countryCode: String?
        public let scoreThresholds: [String: Double]

        enum CodingKeys: String, CodingKey {
            case name
            case className = "class_name"
            case type, enabled, languages
            case countryCode = "country_code"
            case scoreThresholds = "score_thresholds"
        }

        public init(
            name: String,
            className: String,
            type: String = "predefined",
            enabled: Bool = true,
            languages: [LanguageEntry]?,
            countryCode: String? = nil,
            scoreThresholds: [String: Double] = [:]
        ) {
            self.name = name
            self.className = className
            self.type = type
            self.enabled = enabled
            self.languages = languages
            self.countryCode = countryCode
            self.scoreThresholds = scoreThresholds
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

    public init(
        supportedLanguages: [String] = ["en"],
        globalRegexFlags: Int? = nil,
        recognizers: [Entry] = []
    ) {
        self.supportedLanguages = supportedLanguages
        self.globalRegexFlags = globalRegexFlags
        self.recognizers = recognizers
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

    /// One instantiation instruction per (recognizer, language) pair.
    ///
    /// Port of `RecognizerListLoader._get_recognizer_languages` composed with
    /// the `supported_languages` filter that follows it. Upstream builds a
    /// **separate recognizer object per language**, and this is the step that
    /// decides which: an entry that names its languages gets one per named
    /// language, an entry that names none gets one per *requested* language.
    ///
    /// Order follows the configuration, not the alphabet. It is the order
    /// upstream instantiates in, and although the engine normalizes its output
    /// ordering, it still decides which of two identical results survives
    /// `remove_duplicates`.
    public func instantiations(languages: [String]) -> [(entry: Entry, language: String, context: [String]?)] {
        var out: [(entry: Entry, language: String, context: [String]?)] = []
        for entry in recognizers where entry.enabled {
            guard let declared = entry.languages else {
                // No declaration: upstream builds it for every language asked
                // for. This is what makes EmailRecognizer a Spanish recognizer
                // when someone asks for Spanish.
                for language in languages {
                    out.append((entry, language, nil))
                }
                continue
            }
            for lang in declared where languages.contains(lang.language) {
                out.append((entry, lang.language, lang.context))
            }
        }
        return out
    }

    /// Class names enabled for a language, in configuration order.
    public func enabledClassNames(language: String) -> [String] {
        instantiations(languages: [language]).map(\.entry.className)
    }

    /// The context override for a recognizer in a language, if the config
    /// declares one.
    public func contextOverride(className: String, language: String) -> [String]? {
        for entry in recognizers where entry.className == className {
            for lang in entry.languages ?? [] where lang.language == language {
                if let context = lang.context { return context }
            }
        }
        return nil
    }

    public func scoreThresholds(className: String) -> [String: Double] {
        recognizers.first { $0.className == className }?.scoreThresholds ?? [:]
    }
}
