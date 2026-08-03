import Testing
import PresidioCore
import PresidioAnonymizer
@testable import PresidioAnonymizerCrypto

/// Pins the README's round-trip example.
@Suite("README encryption example")
struct ReadmeCryptoTests {

    @Test("encrypting and decrypting round-trips")
    func roundTrip() throws {
        let key = "0123456789abcdef"
        let text = "Card 4095-2609-9393-4932"
        let results = [
            RecognizerResult(entityType: "CREDIT_CARD", start: 5, end: 24, score: 1.0)
        ]

        let sealed = try AnonymizerEngine(operators: CryptoOperators.all).anonymize(
            text: text, analyzerResults: results,
            operators: ["DEFAULT": OperatorConfig("encrypt", ["key": .string(key)])]
        )
        #expect(!sealed.text.contains("4095"))

        let restored = try DeanonymizeEngine(operators: CryptoOperators.all).deanonymize(
            text: sealed.text, entities: sealed.items,
            operators: ["DEFAULT": OperatorConfig("decrypt", ["key": .string(key)])]
        )
        #expect(restored.text == text)
    }
}
