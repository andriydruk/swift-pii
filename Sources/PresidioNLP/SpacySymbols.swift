import Foundation

/// spaCy's reserved string-store symbols.
///
/// `StringStore` hashes with MurmurHash64A, except for a fixed table of 457
/// names that carry small integer ids. Word shapes hit this immediately — the
/// shape of a single capital letter is `"X"`, which is the UPOS symbol with id
/// 101 — and several symbols are ordinary words (`case`, `mark`, `conj`,
/// `root`), so a token whose NORM is one of them would hash wrongly too.
enum SpacySymbols {

    private struct Payload: Decodable { let symbols: [String: UInt64] }

    private static let table: [String: UInt64] = {
        guard let url = Bundle.module.url(
            forResource: "spacy_symbols", withExtension: "json"
        ),
        let bytes = try? Data(contentsOf: url),
        let decoded = try? JSONDecoder().decode(Payload.self, from: bytes)
        else { return [:] }
        return decoded.symbols
    }()

    static var count: Int { table.count }

    @inline(__always)
    static func id(for text: String) -> UInt64? { table[text] }
}
