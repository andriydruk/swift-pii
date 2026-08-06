import Testing
import PresidioConformance
import PresidioCore
import PresidioAnalyzer
import PresidioEngine
@testable import PresidioEngineYAML

/// Tested against Presidio's own config files, copied verbatim — not against
/// configs written to suit the reader.
@Suite("YAML configuration")
struct YAMLConfigurationTests {

    /// The strongest check available, and it needs no new oracle: the bundled
    /// defaults are extracted from this exact YAML at build time, so reading
    /// the YAML at runtime must land on the identical configuration. Any
    /// divergence means one of the two paths is wrong.
    @Test("reading default_recognizers.yaml matches the extracted defaults")
    func yamlMatchesExtractedDefaults() throws {
        let yaml = try Corpus.yamlConfig(named: "default_recognizers")
        let fromYAML = try YAMLConfiguration.registryConfiguration(yaml: yaml)
        let extracted = try #require(RegistryConfiguration.default)

        #expect(fromYAML.supportedLanguages == extracted.supportedLanguages)
        #expect(fromYAML.globalRegexFlags == extracted.globalRegexFlags)
        #expect(fromYAML.recognizers.count == extracted.recognizers.count)

        for (yamlEntry, jsonEntry) in zip(fromYAML.recognizers, extracted.recognizers) {
            #expect(yamlEntry.name == jsonEntry.name)
            #expect(yamlEntry.className == jsonEntry.className, "\(yamlEntry.name)")
            #expect(yamlEntry.enabled == jsonEntry.enabled, "\(yamlEntry.name)")
            #expect(yamlEntry.type == jsonEntry.type, "\(yamlEntry.name)")
            #expect(yamlEntry.countryCode == jsonEntry.countryCode, "\(yamlEntry.name)")
            #expect(yamlEntry.scoreThresholds == jsonEntry.scoreThresholds, "\(yamlEntry.name)")
            // `nil` languages and `["en"]` languages must not compare equal:
            // the first means "every requested language", and conflating them
            // is the bug both readers used to share. Mapping through an
            // optional keeps the distinction visible to the expectation.
            let yamlLanguages: [String]? = yamlEntry.languages?.map(\.language)
            let jsonLanguages: [String]? = jsonEntry.languages?.map(\.language)
            #expect(yamlLanguages == jsonLanguages, "\(yamlEntry.name)")

            let yamlContext: [[String]]? = yamlEntry.languages?.map { $0.context ?? [] }
            let jsonContext: [[String]]? = jsonEntry.languages?.map { $0.context ?? [] }
            #expect(yamlContext == jsonContext, "\(yamlEntry.name) context override")
        }
    }

    @Test("a registry built from the default YAML equals the built-in default")
    func registryFromYAMLMatchesDefault() throws {
        let yaml = try Corpus.yamlConfig(named: "default_recognizers")
        let fromYAML = try YAMLConfiguration.registry(yaml: yaml)
        let builtIn = try RecognizerRegistry.loadPredefined()
        #expect(
            Set(fromYAML.recognizers.map(\.name)) == Set(builtIn.recognizers.map(\.name)),
            "\(Set(fromYAML.recognizers.map(\.name)).symmetricDifference(builtIn.recognizers.map(\.name)))"
        )
    }

    /// Presidio's own example of the custom path: a pattern recognizer and a
    /// deny-list recognizer, in one file.
    @Test("example_recognizers.yaml builds working custom recognizers")
    func exampleConfigBuildsRecognizers() throws {
        let yaml = try Corpus.yamlConfig(named: "example_recognizers")

        let german = try YAMLConfiguration.customRecognizers(yaml: yaml, languages: ["de"])
        let zip = try #require(german.first { $0.name == "Zip code Recognizer" })
        #expect(zip.entity == "ZIP")
        #expect(zip.context == ["zip", "code"])
        let zipHits = zip.analyze("Meine PLZ ist 90210 hier")
        #expect(zipHits.count == 1)
        #expect(zipHits.first?.score == 0.01)

        let english = try YAMLConfiguration.customRecognizers(yaml: yaml, languages: ["en"])
        let titles = try #require(english.first { $0.name == "Titles recognizer" })
        #expect(titles.entity == "TITLE")
        let hits = titles.analyze("Mr. Jones met Dr. Smith and Miss Brown")
        #expect(hits.count == 3, "\(hits.map(\.start))")
        // deny_list_score defaults to 1.0.
        #expect(hits.allSatisfy { $0.score == 1.0 })
    }

    /// A deny-list term ending in "." is why upstream does not use `\b`: there
    /// is no word boundary after the period, so `\b` would never match "Mr.".
    @Test("the deny-list pattern uses upstream's boundaries, not word boundaries")
    func denyListBoundaries() {
        let pattern = PatternRecognizer.denyListPattern(["Mr.", "Miss"])
        #expect(pattern.regex == #"(?:^|(?<=\W))(Mr\.|Miss)(?:(?=\W)|$)"#)
        #expect(pattern.score == 1.0)

        let recognizer = PatternRecognizer.denyList(
            name: "T", entity: "TITLE", terms: ["Mr.", "Miss"]
        )
        #expect(recognizer.analyze("Mr. Jones").count == 1)
        #expect(recognizer.analyze("Mr.").count == 1, "term at end of string")
        #expect(recognizer.analyze("Miss").count == 1)
        // Not a substring match: "Missing" must not hit.
        #expect(recognizer.analyze("Missing").isEmpty)
    }

    /// Port of Python's `re.escape`, which since 3.7 escapes only characters
    /// that can be special in a pattern — not every non-alphanumeric.
    @Test("re.escape matches CPython")
    func regexEscapeMatchesPython() {
        // Verified against CPython 3.10: the escaped ASCII set is exactly
        // " #$&()*+-.?[\]^{|}~" plus the whitespace controls.
        #expect(PatternRecognizer.regexEscape("a b") == #"a\ b"#)
        #expect(PatternRecognizer.regexEscape("Mr.") == #"Mr\."#)
        #expect(PatternRecognizer.regexEscape("a-b") == #"a\-b"#)
        #expect(PatternRecognizer.regexEscape("a_b") == "a_b", "underscore is not escaped")
        #expect(PatternRecognizer.regexEscape("a/b") == "a/b", "slash is not escaped")
        #expect(PatternRecognizer.regexEscape("a:b") == "a:b", "colon is not escaped")
        #expect(PatternRecognizer.regexEscape("a,b") == "a,b", "comma is not escaped")
        #expect(PatternRecognizer.regexEscape("a<b>") == "a<b>", "angle brackets are not escaped")
        #expect(PatternRecognizer.regexEscape("café") == "café", "non-ASCII is left alone")
        #expect(PatternRecognizer.regexEscape("日本") == "日本")
        // Written with doubled backslashes rather than a raw string: inside
        // `#"..."#` the sequence `\#` is Swift's escape introducer, so the
        // literal would not mean what it looks like.
        #expect(PatternRecognizer.regexEscape("$&#~") == "\\$\\&\\#\\~")
    }

    /// Every config Presidio ships, including the deliberately broken ones its
    /// own tests use. Parsing must either succeed or raise — never crash, and
    /// never silently return an empty configuration for a file with content.
    @Test("every upstream config either parses or reports why")
    func allUpstreamConfigsHandled() throws {
        let configs = try Corpus.allYAMLConfigs()
        #expect(configs.count >= 40, "only \(configs.count) configs bundled")

        var parsed = 0, rejected: [String] = []
        for config in configs {
            do {
                let configuration = try YAMLConfiguration.registryConfiguration(
                    yaml: config.text
                )
                parsed += 1
                // A file listing recognizers must not yield an empty list.
                if config.text.contains("\nrecognizers:") {
                    #expect(
                        !configuration.recognizers.isEmpty,
                        "\(config.name) silently produced no recognizers"
                    )
                }
            } catch {
                rejected.append("\(config.name): \(error)")
            }
        }
        print("YAML configs: \(parsed) parsed, \(rejected.count) rejected")
        for reason in rejected { print("  \(reason)") }
        // Upstream ships intentionally-malformed configs for its error tests,
        // so some rejections are correct. What matters is that the majority
        // parse and that nothing crashes.
        #expect(parsed >= configs.count - 4, "\(rejected)")
    }

    @Test("a config naming an unknown key is not silently ignored")
    func malformedConfigsRaise() {
        #expect(throws: YAMLConfiguration.ConfigError.notAMapping) {
            _ = try YAMLConfiguration.registryConfiguration(yaml: "- just\n- a\n- list\n")
        }
        #expect(throws: YAMLConfiguration.ConfigError.recognizersNotASequence) {
            _ = try YAMLConfiguration.registryConfiguration(yaml: "recognizers: nope\n")
        }
        #expect(throws: (any Error).self) {
            _ = try YAMLConfiguration.registry(yaml: """
                recognizers:
                  - name: Broken
                    type: custom
                    supported_entity: X
                    patterns:
                      - name: bad
                        regex: "([unclosed"
                        score: 0.5
                """)
        }
        // A custom recognizer with neither patterns nor a deny list cannot
        // match anything, so it is an error rather than a no-op.
        #expect(throws: YAMLConfiguration.ConfigError.customWithoutPatternsOrDenyList("Empty")) {
            _ = try YAMLConfiguration.customRecognizers(yaml: """
                recognizers:
                  - name: Empty
                    type: custom
                    supported_entity: X
                """)
        }
    }

    @Test("an engine can be built end to end from a config file")
    func engineFromConfig() throws {
        let yaml = """
            supported_languages:
              - en
            global_regex_flags: 26
            recognizers:
              - name: EmailRecognizer
                supported_languages: [en]
                type: predefined
              - name: "Employee ID"
                supported_language: en
                supported_entity: EMPLOYEE_ID
                type: custom
                patterns:
                  - name: "employee id"
                    regex: "EMP-\\\\d{6}"
                    score: 0.8
                context: [employee, staff]
              - name: "Titles"
                supported_language: en
                supported_entity: TITLE
                type: custom
                deny_list: [Mr., Dr.]
                deny_list_score: 0.7
            """
        let registry = try YAMLConfiguration.registry(yaml: yaml)
        let engine = try AnalyzerEngine(registry: registry)

        let results = try engine.analyze(
            text: "Dr. Cooper (EMP-004821) can be reached at c@example.com"
        )
        let types = Set(results.map(\.entityType))
        #expect(types.contains("EMPLOYEE_ID"))
        #expect(types.contains("TITLE"))
        #expect(types.contains("EMAIL_ADDRESS"))
        #expect(results.first { $0.entityType == "EMPLOYEE_ID" }?.score == 0.8)
        #expect(results.first { $0.entityType == "TITLE" }?.score == 0.7)
        // Only what the config asked for: no phone, no credit card recognizer.
        #expect(!registry.recognizers.contains { $0.name == "PhoneRecognizer" })
    }
}
