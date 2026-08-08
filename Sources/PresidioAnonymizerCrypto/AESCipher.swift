import Foundation
import Crypto
import _CryptoExtras
import PresidioAnonymizer

/// AES-CBC + PKCS#7, wire-compatible with Presidio's `AESCipher`.
///
/// This lives in its own target so `PresidioAnonymizer` stays dependency-free.
/// `swift-crypto` vendors BoringSSL, which does not build everywhere (WASM in
/// particular), and there is no reason to make the whole anonymizer pay for a
/// feature most callers do not use.
///
/// **`CryptoKit` cannot do this.** Its `AES` enum exposes only `GCM` and
/// `KeyWrap` — there is no CBC mode at all. `AES._CBC` lives in swift-crypto's
/// `_CryptoExtras`, which is BoringSSL-backed on every platform including
/// Darwin, so the bytes match Python's `cryptography` everywhere.
///
/// Note "byte-compatible" is the wrong goal for *encryption*: upstream calls
/// `os.urandom(16)` per invocation, so ciphertext is not reproducible even
/// Python-to-Python. The achievable property — and the one tested — is
/// round-trip interoperability plus byte-identical decryption.
public enum AESCipher {

    /// A key or ciphertext the cipher will not accept.
    ///
    /// Distinct from `AnonymizerError` because these come from the crypto
    /// primitive rather than from the operator spec — a wrong key length is a
    /// different problem from a misspelled operator name.
    public enum CipherError: Error, CustomStringConvertible {
        case invalidKeySize(Int)
        case malformedCiphertext(String)
        case invalidPadding
        case invalidUTF8

        public var description: String {
            switch self {
            case .invalidKeySize(let bits):
                return "Invalid key size \(bits) bits; expected 128, 192 or 256"
            case .malformedCiphertext(let detail):
                return "Malformed ciphertext: \(detail)"
            case .invalidPadding:
                return "Invalid PKCS#7 padding"
            case .invalidUTF8:
                return "Decrypted bytes are not valid UTF-8"
            }
        }
    }

    /// `len(key) * 8 in algorithms.AES.key_sizes`
    public static func isValidKeySize(_ key: [UInt8]) -> Bool {
        [16, 24, 32].contains(key.count)
    }

    /// Encrypt and return `urlsafe_b64encode(iv + ciphertext)`.
    ///
    /// The IV is random per call, matching upstream, so the output differs on
    /// every invocation by design.
    public static func encrypt(key: [UInt8], text: String) throws -> String {
        guard isValidKeySize(key) else { throw CipherError.invalidKeySize(key.count * 8) }
        var ivBytes = [UInt8](repeating: 0, count: 16)
        for index in ivBytes.indices { ivBytes[index] = UInt8.random(in: 0...255) }
        return try encrypt(key: key, text: text, iv: ivBytes)
    }

    /// Encrypt with a caller-supplied IV. Exposed for known-answer tests; a
    /// fixed IV in production would leak plaintext equality.
    public static func encrypt(key: [UInt8], text: String, iv ivBytes: [UInt8]) throws -> String {
        guard isValidKeySize(key) else { throw CipherError.invalidKeySize(key.count * 8) }
        guard ivBytes.count == 16 else {
            throw CipherError.malformedCiphertext("IV must be 16 bytes")
        }
        let iv = try AES._CBC.IV(ivBytes: ivBytes)
        // AES._CBC applies PKCS#7 unless noPadding is set, matching
        // `padding.PKCS7(algorithms.AES.block_size)`.
        let ciphertext = try AES._CBC.encrypt(
            Array(text.utf8), using: SymmetricKey(data: key), iv: iv
        )
        return Base64URL.encode(ivBytes + Array(ciphertext))
    }

    /// Decrypt `urlsafe_b64encode(iv + ciphertext)` back to the plaintext.
    public static func decrypt(key: [UInt8], text: String) throws -> String {
        guard isValidKeySize(key) else { throw CipherError.invalidKeySize(key.count * 8) }
        let decoded = Base64URL.decode(text)
        guard decoded.count > 16 else {
            throw CipherError.malformedCiphertext("shorter than one IV plus block")
        }
        let iv = try AES._CBC.IV(ivBytes: Array(decoded[0..<16]))
        let plaintext = try AES._CBC.decrypt(
            Array(decoded[16...]), using: SymmetricKey(data: key), iv: iv
        )
        guard let string = String(bytes: plaintext, encoding: .utf8) else {
            throw CipherError.invalidUTF8
        }
        return string
    }
}

/// URL-safe base64, matching Python's `base64.urlsafe_b64*`.
///
/// Two mismatches with Foundation that would otherwise bite:
///
///  * Python's URL-safe alphabet uses `-` and `_` where the standard alphabet
///    uses `+` and `/`, and keeps `=` padding. `Data.base64EncodedString()`
///    emits the standard alphabet.
///  * `urlsafe_b64decode` silently *discards* characters outside the alphabet,
///    where `Data(base64Encoded:)` returns nil. Reproducing the lenient
///    behaviour matters because upstream will happily decode a ciphertext that
///    picked up stray whitespace.
enum Base64URL {

    static func encode(_ bytes: [UInt8]) -> String {
        var encoded = Data(bytes).base64EncodedString()
        encoded = encoded.replacingOccurrences(of: "+", with: "-")
        encoded = encoded.replacingOccurrences(of: "/", with: "_")
        return encoded
    }

    static func decode(_ text: String) -> [UInt8] {
        let alphabet = Set(
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_="
        )
        var filtered = String(text.filter { alphabet.contains($0) })
        filtered = filtered.replacingOccurrences(of: "-", with: "+")
        filtered = filtered.replacingOccurrences(of: "_", with: "/")
        // Foundation is strict about padding; Python infers it.
        let remainder = filtered.count % 4
        if remainder != 0 {
            filtered += String(repeating: "=", count: 4 - remainder)
        }
        return Array(Data(base64Encoded: filtered) ?? Data())
    }
}
