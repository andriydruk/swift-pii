import Testing
import PresidioCore
@testable import PresidioAnonymizer

/// Behaviours the generated differential corpus cannot reach: error paths, the
/// `custom` operator (its lambda is not serializable), and deanonymization.
@Suite("Operators and engine edges")
struct OperatorTests {

    // MARK: - Errors

    @Test("an unknown operator is rejected by name")
    func unknownOperator() {
        let engine = AnonymizerEngine()
        #expect(throws: AnonymizerError.unknownOperator("fake")) {
            try engine.anonymize(
                text: "this is my text",
                analyzerResults: [
                    RecognizerResult(entityType: "number", start: 0, end: 4, score: 0)
                ],
                operators: ["number": OperatorConfig("fake")]
            )
        }
    }

    @Test("a span beyond the text is rejected with upstream's message")
    func spanOutOfRange() {
        let engine = AnonymizerEngine()
        #expect(throws: AnonymizerError.self) {
            try engine.anonymize(
                text: "hello world",
                analyzerResults: [
                    RecognizerResult(entityType: "type", start: 12, end: 16, score: 0.5)
                ]
            )
        }
    }

    @Test("an inverted span is rejected")
    func invertedSpan() {
        #expect(throws: AnonymizerError.self) {
            try PIIEntity(start: 8, end: 3, entityType: "X").validate()
        }
    }

    @Test("a deanonymize-only operator is not reachable from anonymize")
    func operatorDirectionIsEnforced() {
        // `keep` exists on both sides, so use the engine's own registry: the
        // anonymize engine must not expose a deanonymize operator.
        let engine = AnonymizerEngine(operators: [DeanonymizeKeepOperator()])
        #expect(engine.supportedOperators.isEmpty)
    }

    // MARK: - Mask validation

    @Test("mask rejects a multi-scalar masking character")
    func maskRejectsMultiScalarChar() {
        let op = MaskOperator()
        #expect(throws: AnonymizerError.self) {
            try op.validate(params: [
                MaskOperator.maskingCharKey: .string("ab"),
                MaskOperator.charsToMaskKey: .int(2),
                MaskOperator.fromEndKey: .bool(false),
            ])
        }
    }

    @Test("mask accepts a single astral scalar")
    func maskAcceptsAstralChar() throws {
        // Upstream measures with len(), i.e. code points, so one emoji passes.
        let op = MaskOperator()
        let params: [String: OperatorParam] = [
            MaskOperator.maskingCharKey: .string("\u{1F608}"),
            MaskOperator.charsToMaskKey: .int(2),
            MaskOperator.fromEndKey: .bool(false),
        ]
        try op.validate(params: params)
        #expect(try op.operate(text: "abcd", params: params) == "\u{1F608}\u{1F608}cd")
    }

    @Test("mask requires all three parameters", arguments: [
        MaskOperator.maskingCharKey, MaskOperator.charsToMaskKey, MaskOperator.fromEndKey,
    ])
    func maskRequiresParams(missing: String) {
        var params: [String: OperatorParam] = [
            MaskOperator.maskingCharKey: .string("*"),
            MaskOperator.charsToMaskKey: .int(2),
            MaskOperator.fromEndKey: .bool(false),
        ]
        params.removeValue(forKey: missing)
        #expect(throws: AnonymizerError.self) { try MaskOperator().validate(params: params) }
    }

    // MARK: - Hash

    @Test("hash refuses to invent a salt")
    func hashRequiresSalt() {
        // Upstream generates os.urandom(32) here. This target has no portable
        // random source, and a fixed default would make the digest reversible,
        // so an explicit salt is required instead.
        #expect(throws: AnonymizerError.self) {
            try HashOperator().validate(params: [:])
        }
    }

    @Test("hash enforces the 16-byte salt floor", arguments: [0, 1, 15])
    func hashRejectsShortSalt(length: Int) {
        #expect(throws: AnonymizerError.self) {
            try HashOperator().validate(params: [
                HashOperator.saltKey: .string(String(repeating: "a", count: length))
            ])
        }
    }

    @Test("hash rejects an unknown digest")
    func hashRejectsUnknownType() {
        #expect(throws: AnonymizerError.self) {
            try HashOperator().validate(params: [
                HashOperator.hashTypeKey: .string("md5"),
                HashOperator.saltKey: .string(String(repeating: "a", count: 16)),
            ])
        }
    }

    // MARK: - Custom

    @Test("custom applies the supplied function")
    func customOperator() throws {
        let engine = AnonymizerEngine()
        let result = try engine.anonymize(
            text: "My name is Bond",
            analyzerResults: [
                RecognizerResult(entityType: "PERSON", start: 11, end: 15, score: 0.8)
            ],
            operators: [
                "PERSON": OperatorConfig("custom", [
                    CustomOperator.lambdaKey: .function { $0.uppercased() }
                ])
            ]
        )
        #expect(result.text == "My name is BOND")
        #expect(result.items.count == 1)
        #expect(result.items[0].text == "BOND")
    }

    @Test("custom rejects a non-function parameter")
    func customRejectsNonFunction() {
        #expect(throws: AnonymizerError.self) {
            try CustomOperator().validate(params: [
                CustomOperator.lambdaKey: .string("not a function")
            ])
        }
    }

    // MARK: - Deanonymize

    @Test("deanonymize maps spans back through an operator")
    func deanonymizeRoundTrip() throws {
        let engine = DeanonymizeEngine(operators: [DeanonymizeKeepOperator()])
        let result = try engine.deanonymize(
            text: "My name is BOND",
            entities: [
                OperatorResult(
                    start: 11, end: 15, entityType: "PERSON",
                    text: "BOND", operator: "keep"
                )
            ],
            operators: ["PERSON": OperatorConfig("keep")]
        )
        #expect(result.text == "My name is BOND")
    }

    // MARK: - Offsets

    /// The engine works in scalar offsets, so an astral character before a span
    /// must not shift it — the same invariant PresidioCore's TextDocument holds.
    @Test("astral characters do not shift spans")
    func astralOffsets() throws {
        let engine = AnonymizerEngine()
        let text = "\u{1F608}\u{1F608} Bond"
        let result = try engine.anonymize(
            text: text,
            analyzerResults: [
                RecognizerResult(entityType: "PERSON", start: 3, end: 7, score: 0.8)
            ],
            operators: ["PERSON": OperatorConfig("replace", ["new_value": .string("X")])]
        )
        #expect(result.text == "\u{1F608}\u{1F608} X")
        #expect(result.items[0].start == 3)
        #expect(result.items[0].end == 4)
    }
}
