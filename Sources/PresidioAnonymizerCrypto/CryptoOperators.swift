import PresidioAnonymizer

/// Replaces the span with `urlsafe_b64encode(iv + AES-CBC(text))`.
///
/// Reversible with `DecryptOperator` given the same key, which is what makes it
/// different in kind from `hash` — it is pseudonymization, not redaction.
public struct EncryptOperator: AnonymizerOperator {
    public static let keyKey = "key"

    public let name = "encrypt"
    public let type = OperatorType.anonymize
    public init() {}

    public func validate(params: [String: OperatorParam]) throws(AnonymizerError) {
        guard let key = params[Self.keyKey]?.bytesValue else {
            throw .invalidParam("Expected parameter key")
        }
        guard AESCipher.isValidKeySize(key) else {
            throw .invalidParam(
                "Invalid input, key must be of length 128, 192 or 256 bits"
            )
        }
    }

    public func operate(
        text: String, params: [String: OperatorParam]
    ) throws(AnonymizerError) -> String {
        guard let key = params[Self.keyKey]?.bytesValue else {
            throw .invalidParam("Expected parameter key")
        }
        do {
            return try AESCipher.encrypt(key: key, text: text)
        } catch {
            throw .invalidParam("Encryption failed: \(error)")
        }
    }
}

/// Reverses `EncryptOperator`. Registered as a deanonymize operator, so it is
/// unreachable from `anonymize`.
public struct DecryptOperator: AnonymizerOperator {
    public static let keyKey = "key"

    public let name = "decrypt"
    public let type = OperatorType.deanonymize
    public init() {}

    public func validate(params: [String: OperatorParam]) throws(AnonymizerError) {
        try EncryptOperator().validate(params: params)
    }

    public func operate(
        text: String, params: [String: OperatorParam]
    ) throws(AnonymizerError) -> String {
        guard let key = params[Self.keyKey]?.bytesValue else {
            throw .invalidParam("Expected parameter key")
        }
        do {
            return try AESCipher.decrypt(key: key, text: text)
        } catch {
            throw .invalidParam("Decryption failed: \(error)")
        }
    }
}

extension AnonymizerEngine {
    /// An engine including `encrypt` alongside the built-in operators.
    public static func withCrypto() -> AnonymizerEngine {
        AnonymizerEngine(operators: [
            ReplaceOperator(), RedactOperator(), MaskOperator(),
            KeepOperator(), CustomOperator(), HashOperator(),
            EncryptOperator(),
        ])
    }
}

extension DeanonymizeEngine {
    /// A deanonymize engine including `decrypt`.
    public static func withCrypto() -> DeanonymizeEngine {
        DeanonymizeEngine(operators: [DeanonymizeKeepOperator(), DecryptOperator()])
    }
}

/// The AES operators, for registering with an engine.
///
/// `AnonymizerEngine()` and `DeanonymizeEngine()` default to the operators in
/// `PresidioAnonymizer`, which deliberately excludes these — swift-crypto
/// vendors BoringSSL and not every caller wants it linked. Pass this to opt in.
public enum CryptoOperators {
    /// Both directions; an engine keeps only the ones matching its own type.
    public static var all: [any AnonymizerOperator] {
        [EncryptOperator(), DecryptOperator()]
    }
}
