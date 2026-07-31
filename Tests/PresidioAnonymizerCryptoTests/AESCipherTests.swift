import Testing
import Foundation
import PresidioConformance
import PresidioCore
import PresidioAnonymizer
@testable import PresidioAnonymizerCrypto

/// Interop tests against Presidio's own cipher.
///
/// Encryption is not byte-reproducible upstream — `aes_cipher.py:24` calls
/// `os.urandom(16)` per invocation — so the bar is not "identical ciphertext".
/// Two properties are testable and both are checked:
///
///  1. **Known-answer**: with the IV pinned, Swift must produce the exact
///     ciphertext Python does. This pins the cipher, the PKCS#7 padding and the
///     URL-safe base64 alphabet.
///  2. **Interop**: ciphertexts Presidio actually produced, with its random IV,
///     must decrypt to the original plaintext. This is the property that
///     matters operationally — data written by the Python service has to be
///     readable by the Swift one.
@Suite("AES-CBC interop with Presidio")
struct AESCipherTests {

    struct Reference: Decodable {
        struct KnownAnswer: Decodable {
            let keyName: String
            let key: String
            let iv: [UInt8]
            let plaintext: String
            let ciphertext: String

            enum CodingKeys: String, CodingKey {
                case keyName = "key_name"
                case key, iv, plaintext, ciphertext
            }
        }
        struct Interop: Decodable {
            let keyName: String
            let key: String
            let plaintext: String
            let ciphertext: String

            enum CodingKeys: String, CodingKey {
                case keyName = "key_name"
                case key, plaintext, ciphertext
            }
        }
        let knownAnswer: [KnownAnswer]
        let interop: [Interop]
        let validKeySizes: [Int]
        let invalidKeySizes: [Int]

        enum CodingKeys: String, CodingKey {
            case knownAnswer = "known_answer"
            case interop
            case validKeySizes = "valid_key_sizes"
            case invalidKeySizes = "invalid_key_sizes"
        }
    }

    static let reference: Reference = {
        // swiftlint:disable:next force_try
        try! JSONDecoder().decode(
            Reference.self, from: Corpus.data(named: "crypto_reference")
        )
    }()

    @Test("fixed-IV ciphertexts are byte-identical to Python")
    func knownAnswerVectors() throws {
        var checked = 0
        for vector in Self.reference.knownAnswer {
            let produced = try AESCipher.encrypt(
                key: Array(vector.key.utf8), text: vector.plaintext, iv: vector.iv
            )
            #expect(
                produced == vector.ciphertext,
                """
                \(vector.keyName) / \(vector.plaintext.debugDescription)
                  python \(vector.ciphertext)
                  swift  \(produced)
                """
            )
            checked += 1
        }
        #expect(checked >= 40, "only \(checked) vectors checked")
    }

    @Test("ciphertexts produced by Presidio decrypt to the original plaintext")
    func interopDecrypt() throws {
        var checked = 0
        for vector in Self.reference.interop {
            let produced = try AESCipher.decrypt(
                key: Array(vector.key.utf8), text: vector.ciphertext
            )
            #expect(
                produced == vector.plaintext,
                """
                \(vector.keyName): decrypted \(produced.debugDescription), \
                expected \(vector.plaintext.debugDescription)
                """
            )
            checked += 1
        }
        #expect(checked >= 40)
    }

    @Test("Swift-encrypted text round-trips through Swift")
    func roundTrip() throws {
        for vector in Self.reference.interop {
            let key = Array(vector.key.utf8)
            let ciphertext = try AESCipher.encrypt(key: key, text: vector.plaintext)
            #expect(try AESCipher.decrypt(key: key, text: ciphertext) == vector.plaintext)
        }
    }

    @Test("a random IV makes repeated encryption differ")
    func ivIsRandom() throws {
        // If this ever passes trivially, the IV has been fixed and equal
        // plaintexts have become linkable.
        let key = Array("0123456789abcdef".utf8)
        let first = try AESCipher.encrypt(key: key, text: "same input")
        let second = try AESCipher.encrypt(key: key, text: "same input")
        #expect(first != second)
        #expect(try AESCipher.decrypt(key: key, text: first) == "same input")
        #expect(try AESCipher.decrypt(key: key, text: second) == "same input")
    }

    @Test("key sizes match upstream's accepted set")
    func keySizes() {
        for size in Self.reference.validKeySizes {
            #expect(AESCipher.isValidKeySize([UInt8](repeating: 0, count: size)))
        }
        for size in Self.reference.invalidKeySizes {
            #expect(!AESCipher.isValidKeySize([UInt8](repeating: 0, count: size)))
        }
    }

    /// Python's `urlsafe_b64decode` silently discards characters outside the
    /// alphabet; `Data(base64Encoded:)` returns nil. A ciphertext that picked up
    /// whitespace in transit must still decode.
    @Test("base64 decoding is lenient like Python's")
    func lenientBase64() throws {
        let key = Array("0123456789abcdef".utf8)
        let clean = try AESCipher.encrypt(key: key, text: "hello")
        let dirty = clean.enumerated()
            .map { $0.offset == 4 ? "\n\($0.element)" : String($0.element) }
            .joined()
        #expect(try AESCipher.decrypt(key: key, text: dirty) == "hello")
    }

    @Test("the URL-safe alphabet is used, not the standard one")
    func urlSafeAlphabet() throws {
        // Over many random IVs a '+' or '/' would appear if the standard
        // alphabet leaked through.
        let key = Array("0123456789abcdef".utf8)
        for _ in 0..<200 {
            let ciphertext = try AESCipher.encrypt(key: key, text: "some text here")
            #expect(!ciphertext.contains("+"))
            #expect(!ciphertext.contains("/"))
        }
    }

    // MARK: - Operators

    @Test("encrypt then decrypt through the engines")
    func endToEnd() throws {
        let key = "0123456789abcdef"
        let text = "My name is Bond"
        let anonymizer = AnonymizerEngine.withCrypto()
        let anonymized = try anonymizer.anonymize(
            text: text,
            analyzerResults: [
                RecognizerResult(entityType: "PERSON", start: 11, end: 15, score: 0.8)
            ],
            operators: ["PERSON": OperatorConfig("encrypt", ["key": .string(key)])]
        )
        #expect(anonymized.text != text)
        #expect(anonymized.items.count == 1)

        let deanonymizer = DeanonymizeEngine.withCrypto()
        let restored = try deanonymizer.deanonymize(
            text: anonymized.text,
            entities: anonymized.items,
            operators: ["PERSON": OperatorConfig("decrypt", ["key": .string(key)])]
        )
        #expect(restored.text == text)
    }

    @Test("encrypt rejects a bad key size")
    func encryptRejectsBadKey() {
        #expect(throws: AnonymizerError.self) {
            try EncryptOperator().validate(params: ["key": .string("tooshort")])
        }
    }

    @Test("decrypt is not reachable from the anonymize engine")
    func decryptIsDeanonymizeOnly() {
        #expect(!AnonymizerEngine.withCrypto().supportedOperators.contains("decrypt"))
        #expect(DeanonymizeEngine.withCrypto().supportedOperators.contains("decrypt"))
    }
}
