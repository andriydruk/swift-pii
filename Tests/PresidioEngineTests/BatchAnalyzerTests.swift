import Testing
import Foundation
import PresidioConformance
import PresidioCore
import PresidioAnalyzer
@testable import PresidioEngine

/// `BatchAnalyzerEngine` against Presidio's own, over the behaviour that is
/// actually its own: how keys become context, which values are skipped, and how
/// `keys_to_skip` propagates into nested dictionaries.
@Suite("BatchAnalyzerEngine conformance")
struct BatchAnalyzerTests {

    struct Reference: Decodable {
        struct Expected: Decodable {
            let entity: String
            let start: Int
            let end: Int
            let score: Double
        }
        struct Node: Decodable {
            let key: String
            let kind: String
            // Exactly one of these is populated, per `kind`.
            let results: ResultPayload
        }
        enum ResultPayload: Decodable {
            case flat([Expected])
            case lists([[Expected]])
            case nested([Node])

            init(from decoder: any Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let flat = try? container.decode([Expected].self) { self = .flat(flat) }
                else if let lists = try? container.decode([[Expected]].self) { self = .lists(lists) }
                else { self = .nested(try container.decode([Node].self)) }
            }
        }
        struct IteratorCase: Decodable {
            let texts: [String]
            let results: [[Expected]]
        }
        struct DictCase: Decodable {
            let name: String
            let keysToSkip: [String]
            let results: [Node]

            enum CodingKeys: String, CodingKey {
                case name, results
                case keysToSkip = "keys_to_skip"
            }
        }
        let iterator: [IteratorCase]
        let dicts: [DictCase]
    }

    static func reference() throws -> Reference {
        try JSONDecoder().decode(
            Reference.self, from: try Corpus.data(named: "batch_reference")
        )
    }

    static func makeBatch() throws -> BatchAnalyzerEngine {
        var registry = try RecognizerRegistry.loadPredefined()
        registry.add(SpacyRecognizer())
        return BatchAnalyzerEngine(
            analyzer: try AnalyzerEngine(registry: registry)
        )
    }

    static func key(_ result: RecognizerResult) -> String {
        "\(result.entityType)@\(result.start)-\(result.end)=\((result.score * 1e6).rounded() / 1e6)"
    }

    static func key(_ expected: Reference.Expected) -> String {
        "\(expected.entity)@\(expected.start)-\(expected.end)=\((expected.score * 1e6).rounded() / 1e6)"
    }

    /// The oracle was produced with a spaCy model, so PERSON/DATE_TIME results
    /// exist that this engine cannot produce without weights. Comparing only
    /// the entity types both sides can find keeps the test about batching.
    static let nerEntities: Set<String> = [
        "PERSON", "LOCATION", "ORGANIZATION", "NRP", "DATE_TIME",
    ]

    static func comparable(_ keys: [String]) -> [String] {
        keys.filter { key in
            !nerEntities.contains(String(key.prefix { $0 != "@" }))
        }.sorted()
    }

    @Test("analyze over a list of texts matches Presidio")
    func iteratorMatches() throws {
        let reference = try Self.reference()
        let batch = try Self.makeBatch()
        #expect(!reference.iterator.isEmpty)

        for testCase in reference.iterator {
            let got = try batch.analyze(texts: testCase.texts)
            #expect(got.count == testCase.results.count)
            for (results, expected) in zip(got, testCase.results) {
                #expect(
                    Self.comparable(results.map(Self.key))
                        == Self.comparable(expected.map(Self.key)),
                    "\(testCase.texts)"
                )
            }
        }
    }

    /// Rebuilds each recorded dictionary case, since the fixture stores the
    /// input as a Python repr rather than as data.
    static func input(for name: String) -> [(key: String, value: BatchValue)] {
        switch name {
        case "keys_as_context":
            return [("credit_card", .text("4095-2609-9393-4932")),
                    ("notes", .text("4095-2609-9393-4932"))]
        case "falsy_values_skipped":
            return [("empty", .text("")), ("zero", .integer(0)),
                    ("false", .boolean(false)), ("real", .text("a@example.com"))]
        case "keys_to_skip":
            return [("email", .text("a@example.com")), ("phone", .text("212-555-5555"))]
        case "nested":
            return [
                ("outer", .dictionary([
                    ("email", .text("a@example.com")),
                    ("inner", .dictionary([("phone", .text("212-555-5555"))])),
                ])),
                ("top", .text("4095-2609-9393-4932")),
            ]
        case "nested_keys_to_skip":
            return [("outer", .dictionary([
                ("email", .text("a@example.com")),
                ("phone", .text("212-555-5555")),
            ]))]
        case "list_value":
            return [("emails", .list([.text("a@example.com"), .text("b@example.com")])),
                    ("n", .integer(42))]
        case "primitive_types":
            return [("num", .integer(4_095_260_993_934_932)),
                    ("flag", .boolean(true)), ("flt", .number(3.5))]
        default:
            return []
        }
    }

    static func compare(
        _ got: [DictAnalyzerResult], _ want: [Reference.Node], path: String
    ) {
        #expect(got.count == want.count, "\(path): shape")
        for (actual, expected) in zip(got, want) {
            #expect(actual.key == expected.key, "\(path)")
            let here = "\(path)/\(actual.key)"
            switch (actual.results, expected.results) {
            case (.single(let results), .flat(let reference)):
                #expect(
                    comparable(results.map(key)) == comparable(reference.map(key)), "\(here)"
                )
            case (.list(let lists), .lists(let reference)):
                #expect(lists.count == reference.count, "\(here): list length")
                for (results, want) in zip(lists, reference) {
                    #expect(
                        comparable(results.map(key)) == comparable(want.map(key)), "\(here)"
                    )
                }
            case (.nested(let entries), .nested(let reference)):
                compare(entries, reference, path: here)
            // An empty `.single` and an empty `.lists` are the same answer;
            // the fixture cannot tell them apart because Python yields `[]`.
            case (.single(let results), .lists(let reference)):
                #expect(results.isEmpty && reference.isEmpty, "\(here): kind mismatch")
            case (.list(let lists), .flat(let reference)):
                #expect(lists.isEmpty && reference.isEmpty, "\(here): kind mismatch")
            default:
                Issue.record("\(here): result kinds differ")
            }
        }
    }

    @Test("analyzeDictionary matches Presidio across the recorded cases")
    func dictionaryMatches() throws {
        let reference = try Self.reference()
        let batch = try Self.makeBatch()
        #expect(reference.dicts.count >= 7)

        for testCase in reference.dicts {
            let input = Self.input(for: testCase.name)
            #expect(!input.isEmpty, "no input rebuilt for \(testCase.name)")
            let got = try batch.analyzeDictionary(
                input, keysToSkip: testCase.keysToSkip
            )
            Self.compare(got, testCase.results, path: testCase.name)
        }
    }

    /// The key really is doing work — this is the whole point of the class.
    @Test("a dictionary key raises the score of its own value")
    func keyActsAsContext() throws {
        let batch = try Self.makeBatch()
        let results = try batch.analyzeDictionary([
            ("bank account", .text("12345678")),
            ("misc", .text("12345678")),
        ])
        let named = results[0].results.flattened
            .first { $0.entityType == "US_BANK_NUMBER" }
        let anonymous = results[1].results.flattened
            .first { $0.entityType == "US_BANK_NUMBER" }
        #expect(try #require(named).score > #require(anonymous).score)
    }

    @Test("nested keys_to_skip is rewritten for the inner level")
    func nestedKeysToSkip() {
        #expect(
            BatchAnalyzerEngine.nestedKeysToSkip("outer", ["outer.phone", "other.x"])
                == ["phone"]
        )
        #expect(BatchAnalyzerEngine.nestedKeysToSkip("a", []) == [])
        // Prefix matching, not path matching — ported as upstream wrote it.
        #expect(
            BatchAnalyzerEngine.nestedKeysToSkip("ab", ["ab.b", "abc"]) == ["b", "abc"]
        )
    }

    @Test("a list of containers is rejected rather than silently flattened")
    func rejectsNonPrimitives() throws {
        let batch = try Self.makeBatch()
        #expect(throws: (any Error).self) {
            _ = try batch.analyze(texts: [.list([.text("x")])])
        }
    }
}
