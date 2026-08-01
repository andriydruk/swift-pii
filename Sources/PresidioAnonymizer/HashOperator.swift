import PresidioCore
/// Replaces the span with a salted SHA-2 digest.
///
/// Upstream requires a salt of at least 16 bytes, or generates 32 random bytes
/// when none is supplied. The random default means the output is **not
/// reproducible** — two runs over the same text differ — which is deliberate:
/// an unsalted hash of a short PII value is trivially reversible by brute
/// force.
///
/// Because a random salt cannot be reproduced, a caller who needs stable output
/// must pass one explicitly. This port therefore *requires* an explicit salt
/// rather than silently generating one: there is no portable random source in
/// this dependency-free target, and quietly substituting a fixed salt would
/// turn an unreversible hash into a reversible one.
public struct HashOperator: AnonymizerOperator {
    public static let hashTypeKey = "hash_type"
    public static let saltKey = "salt"

    public static let sha256 = "sha256"
    public static let sha512 = "sha512"

    /// Upstream's floor: 16 bytes / 128 bits.
    public static let minimumSaltBytes = 16

    public let name = "hash"
    public let type = OperatorType.anonymize
    public init() {}

    private func hashType(_ params: [String: OperatorParam]) -> String {
        params[Self.hashTypeKey]?.stringValue ?? Self.sha256
    }

    public func validate(params: [String: OperatorParam]) throws(AnonymizerError) {
        let type = hashType(params)
        guard type == Self.sha256 || type == Self.sha512 else {
            throw .invalidParam(
                "Parameter hash_type value \(type) is not in range of values "
                + "['\(Self.sha256)', '\(Self.sha512)']"
            )
        }
        guard let salt = params[Self.saltKey] else {
            throw .invalidParam(
                "Parameter salt is required. Upstream would generate 32 random "
                + "bytes here, but this target has no portable random source and "
                + "a fixed default would make the hash reversible."
            )
        }
        guard let bytes = salt.bytesValue else {
            throw .invalidParam("Invalid parameter value for salt. Expecting 'string' or bytes")
        }
        if bytes.isEmpty {
            throw .invalidParam(
                "Salt parameter cannot be empty. Provide a salt of at least 16 bytes (128 bits)."
            )
        }
        if bytes.count < Self.minimumSaltBytes {
            throw .invalidParam(
                "Salt must be at least 16 bytes (128 bits). Provided salt is "
                + "\(bytes.count) bytes."
            )
        }
    }

    public func operate(
        text: String, params: [String: OperatorParam]
    ) throws(AnonymizerError) -> String {
        guard let salt = params[Self.saltKey]?.bytesValue else {
            throw .invalidParam("Parameter salt is required")
        }
        // Upstream: `text.encode() + salt`, i.e. salt appended, not prepended.
        let salted = Array(text.utf8) + salt
        let digest = hashType(params) == Self.sha512
            ? SHA2.sha512(salted)
            : SHA2.sha256(salted)
        return SHA2.hex(digest)
    }
}
