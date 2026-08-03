import Foundation
import Yams
import PresidioCore
import PresidioAnalyzer
import PresidioRegex
import PresidioEngine

/// Reads Presidio's YAML recognizer configuration.
///
/// The engine reproduces Presidio's *defaults* without any YAML parser, because
/// the default config is resolved to JSON at build time. This is for the other
/// case: a caller who wants to point the engine at their own config file, in
/// the same format Presidio's `RecognizerRegistryProvider` accepts.
///
/// ```swift
/// let registry = try YAMLConfiguration.registry(atPath: "recognizers.yaml")
/// let engine = try AnalyzerEngine(registry: registry)
/// ```
public enum YAMLConfiguration {

    public enum ConfigError: Error, Equatable, CustomStringConvertible {
        case unreadable(path: String)
        case notAMapping
        case recognizersNotASequence
        case entryNotAMapping(index: Int)
        case missingName(index: Int)
        case unknownPredefinedRecognizer(String)
        case customWithoutPatternsOrDenyList(String)
        case badPattern(recognizer: String, reason: String)
        case badScoreThreshold(recognizer: String, reason: String)

        public var description: String {
            switch self {
            case .unreadable(let path):
                return "could not read the configuration at \(path)"
            case .notAMapping:
                return "the configuration's top level must be a mapping"
            case .recognizersNotASequence:
                return "'recognizers' must be a sequence"
            case .entryNotAMapping(let index):
                return "recognizer entry \(index) is not a mapping"
            case .missingName(let index):
                return "recognizer entry \(index) has no 'name'"
            case .unknownPredefinedRecognizer(let name):
                return "no predefined recognizer named '\(name)'; "
                    + "use type: custom to define one in the config"
            case .customWithoutPatternsOrDenyList(let name):
                return "custom recognizer '\(name)' has neither patterns nor a deny_list"
            case .badPattern(let recognizer, let reason):
                return "recognizer '\(recognizer)': \(reason)"
            case .badScoreThreshold(let recognizer, let reason):
                return "recognizer '\(recognizer)': \(reason)"
            }
        }
    }

    // MARK: - Registry configuration

    /// Parse a config file into the same `RegistryConfiguration` the bundled
    /// defaults decode to, so both paths converge on one type.
    public static func registryConfiguration(atPath path: String) throws -> RegistryConfiguration {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw ConfigError.unreadable(path: path)
        }
        return try registryConfiguration(yaml: text)
    }

    public static func registryConfiguration(yaml: String) throws -> RegistryConfiguration {
        let root = try parseMapping(yaml)
        let entries = try recognizerEntries(root).map { index, entry -> RegistryConfiguration.Entry in
            guard let name = entry["name"] as? String else {
                throw ConfigError.missingName(index: index)
            }
            return RegistryConfiguration.Entry(
                name: name,
                className: entry["class_name"] as? String ?? name,
                // Upstream's `_split_recognizers`: an entry is *custom* unless
                // it explicitly says `type: predefined`. Presidio's own
                // example config relies on this — none of its entries declare
                // a type, and all of them are custom.
                type: entry["type"] as? String ?? "custom",
                // Upstream's default is enabled; only an explicit false disables.
                enabled: entry["enabled"] as? Bool ?? true,
                languages: languageEntries(entry),
                countryCode: entry["country_code"] as? String,
                scoreThresholds: doubleMap(entry["score_thresholds"])
            )
        }

        return RegistryConfiguration(
            supportedLanguages: (root["supported_languages"] as? [Any])?
                .compactMap { $0 as? String } ?? ["en"],
            globalRegexFlags: root["global_regex_flags"] as? Int,
            recognizers: entries
        )
    }

    // MARK: - Registry

    /// Build a registry from a config file.
    ///
    /// Predefined entries are looked up in the catalogue; custom entries are
    /// constructed from their patterns or deny list. An entry naming a
    /// recognizer that does not exist is an error rather than a silent skip —
    /// a typo in a config that decides which PII is detected should not fail
    /// quietly.
    public static func registry(
        atPath path: String, languages: [String] = ["en"]
    ) throws -> RecognizerRegistry {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw ConfigError.unreadable(path: path)
        }
        return try registry(yaml: text, languages: languages)
    }

    public static func registry(
        yaml: String, languages: [String] = ["en"]
    ) throws -> RecognizerRegistry {
        let root = try parseMapping(yaml)
        let configuration = try registryConfiguration(yaml: yaml)
        let globalFlags = configuration.globalRegexFlags.map(RegexFlags.init(pythonFlags:))

        // Predefined entries resolve through the same path the bundled defaults
        // use, so a config that lists exactly the defaults produces exactly the
        // default registry.
        var registry = try RecognizerRegistry.loadPredefined(
            languages: languages, configuration: configuration
        )

        for (index, entry) in try recognizerEntries(root) {
            guard (entry["type"] as? String ?? "custom") == "custom" else { continue }
            guard entry["enabled"] as? Bool ?? true else { continue }
            guard let name = entry["name"] as? String else {
                throw ConfigError.missingName(index: index)
            }
            let language = entry["supported_language"] as? String ?? "en"
            guard languages.contains(language) else { continue }
            registry.add(
                try customRecognizer(name: name, entry: entry, globalFlags: globalFlags)
            )
        }
        return registry
    }

    /// Only the custom recognizers a config defines, for callers assembling a
    /// registry themselves.
    public static func customRecognizers(
        yaml: String, languages: [String] = ["en"]
    ) throws -> [PatternRecognizer] {
        let root = try parseMapping(yaml)
        let globalFlags = (root["global_regex_flags"] as? Int).map(RegexFlags.init(pythonFlags:))
        var out: [PatternRecognizer] = []
        for (index, entry) in try recognizerEntries(root) {
            guard (entry["type"] as? String ?? "custom") == "custom" else { continue }
            guard entry["enabled"] as? Bool ?? true else { continue }
            guard let name = entry["name"] as? String else {
                throw ConfigError.missingName(index: index)
            }
            guard languages.contains(entry["supported_language"] as? String ?? "en")
            else { continue }
            out.append(try customRecognizer(name: name, entry: entry, globalFlags: globalFlags))
        }
        return out
    }

    // MARK: - Building one custom recognizer

    private static func customRecognizer(
        name: String, entry: [String: Any], globalFlags: RegexFlags?
    ) throws -> PatternRecognizer {
        let entity = entry["supported_entity"] as? String ?? name
        let context = (entry["context"] as? [Any])?.compactMap { $0 as? String } ?? []
        let flags = (entry["global_regex_flags"] as? Int).map(RegexFlags.init(pythonFlags:))
            ?? globalFlags ?? .presidioDefault

        var patterns: [Pattern] = []
        for raw in (entry["patterns"] as? [Any] ?? []) {
            guard let spec = raw as? [String: Any] else {
                throw ConfigError.badPattern(recognizer: name, reason: "pattern is not a mapping")
            }
            guard let regex = spec["regex"] as? String else {
                throw ConfigError.badPattern(recognizer: name, reason: "pattern has no 'regex'")
            }
            patterns.append(
                Pattern(
                    name: spec["name"] as? String ?? "pattern",
                    regex: regex,
                    score: number(spec["score"]) ?? 0
                )
            )
        }

        // `deny_list` becomes one more pattern, exactly as upstream does it —
        // appended after the explicit patterns, so a recognizer may have both.
        if let terms = (entry["deny_list"] as? [Any])?.compactMap({ $0 as? String }),
           !terms.isEmpty {
            patterns.append(
                PatternRecognizer.denyListPattern(
                    terms,
                    score: number(entry["deny_list_score"])
                        ?? PatternRecognizer.defaultDenyListScore
                )
            )
        }

        guard !patterns.isEmpty else {
            throw ConfigError.customWithoutPatternsOrDenyList(name)
        }

        let recognizer = PatternRecognizer(
            name: name, entity: entity, patterns: patterns, context: context,
            flags: flags, language: entry["supported_language"] as? String ?? "en"
        )
        // A pattern that does not compile would otherwise just never match.
        if let failure = recognizer.compilationFailures.first {
            throw ConfigError.badPattern(
                recognizer: name,
                reason: "pattern '\(failure.pattern.name)' did not compile: \(failure.reason)"
            )
        }
        return recognizer
    }

    // MARK: - YAML plumbing

    private static func parseMapping(_ yaml: String) throws -> [String: Any] {
        guard let object = try Yams.load(yaml: yaml) else { return [:] }
        guard let mapping = object as? [String: Any] else { throw ConfigError.notAMapping }
        return mapping
    }

    private static func recognizerEntries(
        _ root: [String: Any]
    ) throws -> [(Int, [String: Any])] {
        guard let raw = root["recognizers"] else { return [] }
        guard let sequence = raw as? [Any] else { throw ConfigError.recognizersNotASequence }
        return try sequence.enumerated().map { index, element in
            // A bare string entry is shorthand for a predefined recognizer.
            if let name = element as? String { return (index, ["name": name]) }
            guard let mapping = element as? [String: Any] else {
                throw ConfigError.entryNotAMapping(index: index)
            }
            return (index, mapping)
        }
    }

    /// `supported_languages` is either a list of codes or a list of mappings
    /// carrying a per-language context override; `supported_language` (singular)
    /// is the custom-recognizer spelling.
    private static func languageEntries(
        _ entry: [String: Any]
    ) -> [RegistryConfiguration.LanguageEntry] {
        if let raw = entry["supported_languages"] as? [Any] {
            let entries = raw.compactMap { element -> RegistryConfiguration.LanguageEntry? in
                if let code = element as? String {
                    return RegistryConfiguration.LanguageEntry(language: code, context: nil)
                }
                guard let mapping = element as? [String: Any],
                      let code = mapping["language"] as? String else { return nil }
                return RegistryConfiguration.LanguageEntry(
                    language: code,
                    context: (mapping["context"] as? [Any])?.compactMap { $0 as? String }
                )
            }
            if !entries.isEmpty { return entries }
        }
        let single = entry["supported_language"] as? String ?? "en"
        return [RegistryConfiguration.LanguageEntry(language: single, context: nil)]
    }

    private static func number(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        return nil
    }

    private static func doubleMap(_ value: Any?) -> [String: Double] {
        guard let mapping = value as? [String: Any] else { return [:] }
        return mapping.compactMapValues(number)
    }
}
