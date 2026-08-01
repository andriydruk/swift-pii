import PresidioCore
import PresidioAnalyzer
import PresidioRecognizers
import PresidioNLP

/// Whether every bundled data file loaded, and what it contains.
///
/// This exists because of a specific failure mode this package has already hit
/// twice. Every resource loads through `Bundle.module` into an optional, and
/// every consumer of a failed load degrades *quietly*: a validator that cannot
/// read its table returns `.invalid` for everything, which is indistinguishable
/// from "nothing matched". One missing key in the extractor once disabled five
/// recognizers with no error anywhere.
///
/// So each check probes decoded *content*, not file presence — a truncated or
/// schema-drifted file passes an existence check and fails here.
///
/// ```swift
/// let unhealthy = Diagnostics.resourceHealth().filter { !$0.isHealthy }
/// ```
public enum Diagnostics {

    public struct ResourceStatus: Sendable, Hashable {
        /// The bundled file this covers.
        public let resource: String
        /// The module whose bundle carries it.
        public let module: String
        public let isHealthy: Bool
        /// What was found — a count, or the reason it failed.
        public let detail: String
    }

    /// Every bundled resource, probed.
    ///
    /// Deliberately returns statuses rather than throwing: a caller
    /// investigating a misbehaving build wants the whole picture, not the first
    /// failure.
    public static func resourceHealth() -> [ResourceStatus] {
        [
            recognizerCatalogue(),
            recognizerData(),
            publicSuffixList(),
            ibanCountries(),
            phoneMetadata(),
            phoneMatcherPatterns(),
            registryConfig(),
            lexicalTables(),
            tokenizerRules(),
        ]
    }

    /// True when every bundled resource loaded with plausible content.
    public static var allResourcesHealthy: Bool {
        resourceHealth().allSatisfy(\.isHealthy)
    }

    /// A one-line-per-resource report, for logs and bug reports.
    public static func report() -> String {
        resourceHealth()
            .map { "\($0.isHealthy ? "ok  " : "FAIL") \($0.module)/\($0.resource): \($0.detail)" }
            .joined(separator: "\n")
    }

    // MARK: - Individual probes

    private static func status(
        _ resource: String, _ module: String, _ healthy: Bool, _ detail: String
    ) -> ResourceStatus {
        ResourceStatus(
            resource: resource, module: module, isHealthy: healthy, detail: detail
        )
    }

    private static func recognizerCatalogue() -> ResourceStatus {
        do {
            let definitions = try Catalog.definitions()
            let withPatterns = definitions.filter { !$0.patterns.isEmpty }
            return status(
                "recognizers.json", "PresidioRecognizers",
                definitions.count >= 80 && withPatterns.count >= 80,
                "\(definitions.count) definitions, \(withPatterns.count) with patterns"
            )
        } catch {
            return status("recognizers.json", "PresidioRecognizers", false, "\(error)")
        }
    }

    private static func recognizerData() -> ResourceStatus {
        // Spot-checks one constant from each section: a partially-decoded
        // payload would otherwise look loaded.
        let healthy = DataValidators.isDataLoaded
            && DataValidators.crypto("bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4") == .valid
        return status(
            "recognizer_data.json", "PresidioRecognizers", healthy,
            healthy ? "all sections decoded"
                    : (DataValidators.loadFailure ?? "a section is missing")
        )
    }

    private static func publicSuffixList() -> ResourceStatus {
        let twoLevel = DataValidators.publicSuffixLength(["example", "co", "uk"]) == 2
        let oneLevel = DataValidators.publicSuffixLength(["example", "site"]) == 1
        return status(
            "public_suffix_list.json", "PresidioRecognizers", twoLevel && oneLevel,
            twoLevel && oneLevel ? "multi-level suffixes resolve" : "suffix lookup wrong"
        )
    }

    private static func ibanCountries() -> ResourceStatus {
        let count = IbanValidator.countryCount
        return status(
            "iban_countries.json", "PresidioRecognizers", count >= 70,
            "\(count) country formats"
        )
    }

    private static func phoneMetadata() -> ResourceStatus {
        let regions = PhoneNumberUtil.supportedRegions
        let healthy = PhoneNumberUtil.isMetadataLoaded && regions.count >= 39
        return status(
            "phone_metadata.json", "PresidioRecognizers", healthy,
            "\(regions.count) regions"
        )
    }

    private static func phoneMatcherPatterns() -> ResourceStatus {
        // Separate from the metadata: the matcher's own regexes live in the
        // same file but compile independently, and a compile failure there
        // silently makes PhoneRecognizer find nothing at all.
        status(
            "phone_metadata.json (matcher)", "PresidioRecognizers",
            PhoneNumberMatcher.isReady,
            PhoneNumberMatcher.isReady ? "matcher patterns compiled"
                                       : "matcher patterns failed to compile"
        )
    }

    private static func registryConfig() -> ResourceStatus {
        guard let config = RegistryConfiguration.default else {
            return status("registry_config.json", "PresidioEngine", false, "did not decode")
        }
        let enabled = config.enabledClassNames(language: "en")
        return status(
            "registry_config.json", "PresidioEngine",
            enabled.count == 17 && config.globalRegexFlags == 26,
            "\(enabled.count) English recognizers enabled, flags \(config.globalRegexFlags ?? -1)"
        )
    }

    private static func lexicalTables() -> ResourceStatus {
        let count = LexicalTables.englishStopWords.count
        return status(
            "en_lexical.json", "PresidioEngine",
            count == 326 && LexicalTables.isStopWord("The", language: "en"),
            "\(count) stop words"
        )
    }

    private static func tokenizerRules() -> ResourceStatus {
        do {
            let tokenizer = try SpacyTokenizer.english()
            let tokens = tokenizer.tokenize("Dr. Smith isn't here.")
            return status(
                "en_tokenizer.json", "PresidioNLP", tokens.count == 6,
                "spaCy \(tokenizer.spacyVersion), \(tokens.count) tokens on the probe"
            )
        } catch {
            return status("en_tokenizer.json", "PresidioNLP", false, "\(error)")
        }
    }
}
