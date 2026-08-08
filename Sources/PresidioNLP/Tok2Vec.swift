import Foundation

/// Why a spaCy component failed to load.
///
/// Shared by every component that reads the model directory, because the two
/// things that go wrong are always the same two: the file is not there, or it
/// is not the network the loader expected. `TaggerModel.LoadError` is an alias
/// for this, which is why the tagger's tests still name it that.
public enum ComponentLoadError: Error, CustomStringConvertible {
    /// A file the component needs is absent.
    case missing(String)
    /// The file is present but is not the architecture this loader reads.
    case malformed(String)

    public var description: String {
        switch self {
        case .missing(let path): return "\(path) not found"
        case .malformed(let what): return what
        }
    }
}

/// The pipeline's **shared** token-to-vector network.
///
/// `tok2vec/model` in an unpacked spaCy model: a `MultiHashEmbed` over six
/// lexical attributes followed by four residual maxout-window blocks. Every
/// component configured as a `Tok2VecListener` — the tagger, the lemmatizer's
/// edit-tree classifier, the dependency parser — consumes this one forward
/// pass, which is the reason it is factored out here rather than living inside
/// whichever component happened to need it first.
///
/// It is *not* the network inside `ner/model`. That one embeds four attributes
/// with separately trained weights, so NER runs its own encoder and cannot
/// share this one. That was checked rather than assumed.
///
/// Architecture, from the model's own config:
///
///     MultiHashEmbed(width=96,
///                    attrs=[NORM, PREFIX, SUFFIX, SHAPE, SPACY, IS_SPACE],
///                    rows=[5000, 1000, 2500, 2500, 50, 50])
///     MaxoutWindowEncoder(width=96, depth=4, window_size=1, maxout_pieces=3)
///
/// `@unchecked Sendable` on the same grounds as `NERModel`: every stored
/// property is a weight array written once during `init` and only read after.
final class Tok2Vec: @unchecked Sendable {

    let width = 96

    // Embedding tables, one per attribute, in column order.
    private(set) var embE: [[Float]] = []
    private(set) var embRows: [Int] = []
    private(set) var embSeed: [UInt32] = []
    private(set) var embColumn: [Int] = []

    // Embedding maxout + layer norm.
    private(set) var moW: [Float] = []
    private(set) var moB: [Float] = []
    private(set) var moNI = 0
    private(set) var lnG: [Float] = []
    private(set) var lnB: [Float] = []

    // Four residual maxout-window blocks.
    private(set) var encW: [[Float]] = []
    private(set) var encB: [[Float]] = []
    private(set) var encG: [[Float]] = []
    private(set) var encLB: [[Float]] = []

    init(path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw ComponentLoadError.missing(path)
        }
        var reader = MPReader(readFile(path))
        let root = reader.value()
        guard let nodes = root.m("nodes")?.asArr,
              let params = root.m("params")?.asArr,
              let attrs = root.m("attrs")?.asArr
        else { throw ComponentLoadError.malformed("\(path) is not a thinc model") }

        func nodeName(_ i: Int) -> String { nodes[i].m("name")?.asStr ?? "" }
        func tensor(_ i: Int, _ key: String) -> Tensor? {
            params[i].m(key).map(mpTensor)
        }
        func attrInt(_ i: Int, _ key: String) -> Int? {
            guard let bin = attrs[i].m(key)?.asBin else { return nil }
            var r = MPReader(Array(bin))
            return r.value().asInt
        }

        var embeds: [(index: Int, table: Tensor, seed: UInt32, column: Int)] = []
        var maxouts: [(Int, Tensor, Tensor)] = []
        var norms: [(Int, Tensor, Tensor)] = []
        for i in 0..<nodes.count {
            switch nodeName(i) {
            case "hashembed":
                guard let table = tensor(i, "E"), let seed = attrInt(i, "seed"),
                      let column = attrInt(i, "column")
                else { throw ComponentLoadError.malformed("hashembed node \(i) is incomplete") }
                embeds.append((i, table, UInt32(seed), column))
            case "maxout":
                guard let w = tensor(i, "W"), let b = tensor(i, "b")
                else { throw ComponentLoadError.malformed("maxout node \(i) is incomplete") }
                maxouts.append((i, w, b))
            case "layernorm":
                guard let g = tensor(i, "G"), let b = tensor(i, "b")
                else { throw ComponentLoadError.malformed("layernorm node \(i) is incomplete") }
                norms.append((i, g, b))
            default:
                break
            }
        }
        guard embeds.count == 6 else {
            throw ComponentLoadError.malformed(
                "expected 6 embedded attributes, found \(embeds.count)"
            )
        }

        // Node order is the serialization order, which is also column order.
        embeds.sort { $0.index < $1.index }
        maxouts.sort { $0.0 < $1.0 }
        norms.sort { $0.0 < $1.0 }
        for embed in embeds {
            embE.append(embed.table.data)
            embRows.append(embed.table.shape[0])
            embSeed.append(embed.seed)
            embColumn.append(embed.column)
        }

        // `featureIDs` produces the six attributes positionally, in the order
        // `MultiHashEmbed` declares them. Each `hashembed` node also records the
        // column it reads, so the assumption is checkable rather than merely
        // documented — a model whose columns were serialized in another order
        // would embed the shape into the NORM table and fail nowhere obvious.
        guard embColumn == Array(0..<embeds.count) else {
            throw ComponentLoadError.malformed(
                "embedded attribute columns are \(embColumn), expected "
                + "\(Array(0..<embeds.count)) — this loader reads them positionally"
            )
        }

        // The embedding maxout consumes the concatenated attribute vectors
        // (6 x 96 = 576); the encoder ones consume a 3-token window (288).
        guard let embedMaxout = maxouts.first(where: { $0.1.shape[2] != 3 * width }),
              let embedNorm = norms.min(by: {
                  abs($0.0 - embedMaxout.0) < abs($1.0 - embedMaxout.0)
              })
        else { throw ComponentLoadError.malformed("no embedding maxout") }
        moW = embedMaxout.1.data
        moB = embedMaxout.2.data
        moNI = embedMaxout.1.shape[2]
        lnG = embedNorm.1.data
        lnB = embedNorm.2.data

        let encoderMaxouts = maxouts.filter { $0.1.shape[2] == 3 * width }
        let encoderNorms = norms.filter { $0.0 != embedNorm.0 }
        guard encoderMaxouts.count == 4, encoderNorms.count == 4 else {
            throw ComponentLoadError.malformed(
                "expected 4 encoder blocks, found \(encoderMaxouts.count)"
            )
        }
        for (i, maxout) in encoderMaxouts.enumerated() {
            encW.append(maxout.1.data)
            encB.append(maxout.2.data)
            encG.append(encoderNorms[i].1.data)
            encLB.append(encoderNorms[i].2.data)
        }
    }

    /// spaCy's string-store id.
    ///
    /// MurmurHash64A *except* for the 457 reserved symbols, which have small
    /// integer ids. That exception is not academic: the shape of a single
    /// capital letter is "X", the UPOS symbol with id 101, so hashing it
    /// mis-embeds every one-letter capitalised token — which is exactly where
    /// the first tagger divergences appeared.
    @inline(__always)
    func stringID(_ text: String) -> UInt64 {
        SpacySymbols.id(for: text) ?? murmurHash64A(Array(text.utf8), 1)
    }

    /// Feature ids for one token, in column order.
    ///
    /// `SPACY` and `IS_SPACE` are boolean lexeme attributes, so their "id" is
    /// literally 0 or 1 rather than a string-store hash — `Doc.to_array` emits
    /// the raw attribute value.
    func featureIDs(token: Token, followedBySpace: Bool) -> [UInt64] {
        let text = token.text
        let isSpace = !text.isEmpty && text.allSatisfy {
            $0.unicodeScalars.allSatisfy { $0.properties.isWhitespace }
        }
        return [
            stringID(token.norm),
            stringID(lexPrefix(text)),
            stringID(lexSuffix(text)),
            stringID(wordShape(text)),
            followedBySpace ? 1 : 0,
            isSpace ? 1 : 0,
        ]
    }

    /// One vector per token, row-major, `tokens.count * width` floats.
    ///
    /// `text` is needed only to decide `SPACY` — whether a token is followed by
    /// whitespace — which the tokenizer records as a gap between offsets rather
    /// than as a flag.
    func encode(tokens: [Token], text: String) -> [Float] {
        let count = tokens.count
        guard count > 0 else { return [] }
        let scalars = Array(text.unicodeScalars)

        // ---- embed ----
        var embedded = [Float](repeating: 0, count: count * moNI)
        for t in 0..<count {
            let end = tokens[t].end
            let followedBySpace = end < scalars.count
                && scalars[end].properties.isWhitespace
            let ids = featureIDs(token: tokens[t], followedBySpace: followedBySpace)
            for column in 0..<embE.count {
                let (k0, k1, k2, k3) = mmh3x86_128_u64(ids[column], embSeed[column])
                let rows = UInt32(embRows[column])
                let base = t * moNI + column * width
                for key in [k0, k1, k2, k3] {
                    let row = Int(key % rows) * width
                    for j in 0..<width { embedded[base + j] += embE[column][row + j] }
                }
            }
        }

        // ---- embedding maxout + layer norm ----
        let pieces = 3
        var projected = [Float](repeating: 0, count: count * width * pieces)
        for t in 0..<count {
            for o in 0..<(width * pieces) { projected[t * width * pieces + o] = moB[o] }
        }
        embedded.withUnsafeBufferPointer { input in
            moW.withUnsafeBufferPointer { weights in
                projected.withUnsafeMutableBufferPointer { output in
                    gemmT(input.baseAddress!, weights.baseAddress!,
                          output.baseAddress!, count, moNI, width * pieces)
                }
            }
        }

        // The window encoder reads one token either side, so the sequence is
        // padded rather than special-cased at the ends. Four is what spaCy's
        // `with_array` pads by; anything ≥ 1 would do for a window of 1, and
        // matching spaCy keeps the arithmetic identical.
        let pad = 4
        var hidden = [Float](repeating: 0, count: (count + 2 * pad) * width)
        for t in 0..<count {
            for o in 0..<width {
                var best = projected[t * width * pieces + o * pieces]
                for q in 1..<pieces {
                    let value = projected[t * width * pieces + o * pieces + q]
                    if value > best { best = value }
                }
                hidden[(t + pad) * width + o] = best
            }
            layerNorm(&hidden, (t + pad) * width, width, lnG, lnB)
        }

        // ---- 4 residual maxout-window blocks ----
        let padded = count + 2 * pad
        var window = [Float](repeating: 0, count: padded * 3 * width)
        var encoded = [Float](repeating: 0, count: padded * width * pieces)
        for block in 0..<encW.count {
            for i in 0..<(padded * 3 * width) { window[i] = 0 }
            for t in 0..<padded {
                let base = t * 3 * width
                if t > 0 {
                    for j in 0..<width { window[base + j] = hidden[(t - 1) * width + j] }
                }
                for j in 0..<width { window[base + width + j] = hidden[t * width + j] }
                if t + 1 < padded {
                    for j in 0..<width {
                        window[base + 2 * width + j] = hidden[(t + 1) * width + j]
                    }
                }
            }
            for t in 0..<padded {
                for o in 0..<(width * pieces) {
                    encoded[t * width * pieces + o] = encB[block][o]
                }
            }
            window.withUnsafeBufferPointer { input in
                encW[block].withUnsafeBufferPointer { weights in
                    encoded.withUnsafeMutableBufferPointer { output in
                        gemmT(input.baseAddress!, weights.baseAddress!,
                              output.baseAddress!, padded, 3 * width, width * pieces)
                    }
                }
            }
            var residual = [Float](repeating: 0, count: padded * width)
            for t in 0..<padded {
                for o in 0..<width {
                    var best = encoded[t * width * pieces + o * pieces]
                    for q in 1..<pieces {
                        let value = encoded[t * width * pieces + o * pieces + q]
                        if value > best { best = value }
                    }
                    residual[t * width + o] = best
                }
                layerNorm(&residual, t * width, width, encG[block], encLB[block])
            }
            for i in 0..<(padded * width) { hidden[i] += residual[i] }
        }

        // Drop the padding: callers index by token, not by padded position.
        var out = [Float](repeating: 0, count: count * width)
        for t in 0..<count {
            for j in 0..<width { out[t * width + j] = hidden[(t + pad) * width + j] }
        }
        return out
    }
}
