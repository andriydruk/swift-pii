import Testing
import PresidioCore
@testable import PresidioAnonymizer

/// Known-answer tests for the hand-written SHA-2.
///
/// Values generated from Python's `hashlib`, which is what upstream uses. The
/// lengths are chosen to straddle every padding boundary — 55/56 and 63/64 for
/// SHA-256 (56-byte length field, 64-byte block), and 111/112 and 127/128 for
/// SHA-512 — because an off-by-one in Merkle-Damgard padding only shows up
/// exactly there.
@Suite("SHA-2")
struct SHA2Tests {

    static func repeated(_ c: Character, _ n: Int) -> [UInt8] {
        Array(String(repeating: String(c), count: n).utf8)
    }

    @Test("SHA-256 matches hashlib", arguments: [
        ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
        ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
        ("The quick brown fox jumps over the lazy dog",
         "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592"),
    ])
    func sha256Literals(input: String, expected: String) {
        #expect(SHA2.hex(SHA2.sha256(Array(input.utf8))) == expected)
    }

    @Test("SHA-256 padding boundaries", arguments: [
        (55, "d5e285683cd4efc02d021a5c62014694958901005d6f71e89e0989fac77e4072"),
        (56, "04c26261370ee7541549d16dee320c723e3fd14671e66a099afe0a377c16888e"),
        (63, "75220b47218278e656f2013bb8f0c455a25eaf01e86c64924e9d48d89776d6f2"),
        (64, "7ce100971f64e7001e8fe5a51973ecdfe1ced42befe7ee8d5fd6219506b5393c"),
        (111, "5ba60613dba318e9ed9020301e5dc59c721c19d82862e4d03718708aa75d2bad"),
        (128, "24da1b81d0b16df6428eee73c69fcb2a93c76bc6df706f0c6670fe6bfe800464"),
        (200, "c2a908d98f5df987ade41b5fce213067efbcc21ef2240212a41e54b5e7c28ae5"),
    ])
    func sha256Padding(length: Int, expected: String) {
        let char: Character = length == 200 ? "a" : "x"
        #expect(SHA2.hex(SHA2.sha256(Self.repeated(char, length))) == expected)
    }

    @Test("SHA-512 matches hashlib", arguments: [
        ("", "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce"
           + "47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e"),
        ("abc", "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a"
              + "2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"),
        ("The quick brown fox jumps over the lazy dog",
         "07e547d9586f6a73f73fbac0435ed76951218fb7d0c8d788a309d785436bbb64"
       + "2e93a252a954f23912547d1e8a3b5ed6e1bfd7097821233fa0538f3db854fee6"),
    ])
    func sha512Literals(input: String, expected: String) {
        #expect(SHA2.hex(SHA2.sha512(Array(input.utf8))) == expected)
    }

    @Test("SHA-512 padding boundaries", arguments: [
        (111, "9a2a120825c2319867758ec277924f6faa254968bf752046dacdd948d8ad299b"
            + "10359fd04bfd7d3810b5fa1b16a294236138baff981cbb85248478053ac4d3dd"),
        (112, "a3722b515ef40c910f2419f6e0da8ca51d410114ce6272faae64045f9e9f630e"
            + "7fa8dd5a3243c9860b899d148c3da4bc0f9e07454542604d030bb55531fe0d5b"),
        (127, "1d5a8893e7b7ed83d485d26f88cfb846f3760279916976fe538e539fc16f7cd1"
            + "9ba3e1c2cd5fda78749a74205755cdf694e8fa90b2bfed8815f406af76c1d7bf"),
        (128, "e2e22f8422b54b06e35c3ea30a383d1de7a8fbc27992923074103117020d8dd7"
            + "024c3ecf7d6d1a15a6de5a75ff32fb486b9e8ced4c02ffe05822bf2cb734d0e0"),
        (55, "db9981645857e59805132f7699e78bbcf39f69380a41aac8e6fa158a0593f2017"
           + "ffe48764687aa855dae3023fcceefd51a1551d57730423df18503e80ba381ba"),
        (56, "a9436ec7761f9f0d5fa48e652d72b54622f763b36106e6551900b32f6cd7f4d8"
           + "8dbeaadeb866d7f5311663eda3bbcda04ffb5a8e6779e14b84e95da5327c083e"),
    ])
    func sha512Padding(length: Int, expected: String) {
        #expect(SHA2.hex(SHA2.sha512(Self.repeated("x", length))) == expected)
    }

    /// The operator appends the salt (`text.encode() + salt`), not prepends.
    /// Getting that backwards produces a plausible-looking but wrong digest.
    @Test("salted digests match the operator's byte order", arguments: [
        ("Bond", "f1a489fb27d79afe25e32610333265869c19a586b97542e2e023acc0d4680744"),
        ("James Bond", "17c18da75ff4fee9dafc876e41609f48f700cd95b647a579ac2166b50564007f"),
        ("\u{1F608}", "1f1c8c2c038e893fca83567a55eba4237a487d5ae63b6d51f029014e4e701ca6"),
    ])
    func saltedDigest(text: String, expected: String) throws {
        let salt = "0123456789abcdef0123456789abcdef"
        let op = HashOperator()
        let params: [String: OperatorParam] = [
            HashOperator.saltKey: .string(salt)
        ]
        try op.validate(params: params)
        #expect(try op.operate(text: text, params: params) == expected)
    }
}
