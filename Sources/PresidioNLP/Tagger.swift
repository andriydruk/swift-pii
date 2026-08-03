import Foundation

/// spaCy's part-of-speech tagger.
///
/// Exists for one reason: rule-mode lemmatization keys off the coarse POS tag,
/// so exact lemmas are unreachable without it.
///
/// The tagger is a `Softmax` over the pipeline's **shared** tok2vec, which is a
/// different network from the one inside `ner/model` — six embedded attributes
/// rather than four, and separately trained weights. So this loads
/// `tok2vec/model` in addition to `tagger/model`; the NER port's tok2vec cannot
/// be reused, which was checked rather than assumed.
///
/// Architecture, from the model's own config:
///
///     MultiHashEmbed(width=96,
///                    attrs=[NORM, PREFIX, SUFFIX, SHAPE, SPACY, IS_SPACE],
///                    rows=[5000, 1000, 2500, 2500, 50, 50])
///     MaxoutWindowEncoder(width=96, depth=4, window_size=1, maxout_pieces=3)
///     Softmax(nO=50)
public final class TaggerModel: @unchecked Sendable {

    /// Fine-grained Penn Treebank tags, in the order the softmax emits them.
    public let labels: [String]

    let width = 96
    // Embedding tables, one per attribute, in column order.
    var embE: [[Float]] = []
    var embRows: [Int] = []
    var embSeed: [UInt32] = []
    var embColumn: [Int] = []

    // Embedding maxout + layer norm.
    var moW: [Float] = []
    var moB: [Float] = []
    var moNI = 0
    var lnG: [Float] = []
    var lnB: [Float] = []

    // Four residual maxout-window blocks.
    var encW: [[Float]] = []
    var encB: [[Float]] = []
    var encG: [[Float]] = []
    var encLB: [[Float]] = []

    // Output softmax.
    var softW: [Float] = []
    var softB: [Float] = []

    public enum LoadError: Error, CustomStringConvertible {
        case missing(String)
        case malformed(String)

        public var description: String {
            switch self {
            case .missing(let path): return "tagger: \(path) not found"
            case .malformed(let what): return "tagger: \(what)"
            }
        }
    }

    /// - Parameter directory: an unpacked spaCy model directory.
    public init(directory: String) throws {
        let tokPath = directory + "/tok2vec/model"
        let tagPath = directory + "/tagger/model"
        let cfgPath = directory + "/tagger/cfg"
        for path in [tokPath, tagPath, cfgPath] where
            !FileManager.default.fileExists(atPath: path) {
            throw LoadError.missing(path)
        }

        // --- labels -------------------------------------------------------
        guard let cfg = try? JSONSerialization.jsonObject(
                with: Data(readFile(cfgPath))
              ) as? [String: Any],
              let labels = cfg["labels"] as? [String], !labels.isEmpty
        else { throw LoadError.malformed("tagger/cfg has no labels") }
        self.labels = labels

        // --- shared tok2vec ----------------------------------------------
        var reader = MPReader(readFile(tokPath))
        let root = reader.value()
        guard let nodes = root.m("nodes")?.asArr,
              let params = root.m("params")?.asArr,
              let attrs = root.m("attrs")?.asArr
        else { throw LoadError.malformed("tok2vec/model is not a thinc model") }

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
                else { throw LoadError.malformed("hashembed node \(i) is incomplete") }
                embeds.append((i, table, UInt32(seed), column))
            case "maxout":
                guard let w = tensor(i, "W"), let b = tensor(i, "b")
                else { throw LoadError.malformed("maxout node \(i) is incomplete") }
                maxouts.append((i, w, b))
            case "layernorm":
                guard let g = tensor(i, "G"), let b = tensor(i, "b")
                else { throw LoadError.malformed("layernorm node \(i) is incomplete") }
                norms.append((i, g, b))
            default:
                break
            }
        }
        guard embeds.count == 6 else {
            throw LoadError.malformed("expected 6 embedded attributes, found \(embeds.count)")
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

        // The embedding maxout consumes the concatenated attribute vectors
        // (6 x 96 = 576); the encoder ones consume a 3-token window (288).
        guard let embedMaxout = maxouts.first(where: { $0.1.shape[2] != 3 * width }),
              let embedNorm = norms.min(by: {
                  abs($0.0 - embedMaxout.0) < abs($1.0 - embedMaxout.0)
              })
        else { throw LoadError.malformed("no embedding maxout") }
        moW = embedMaxout.1.data
        moB = embedMaxout.2.data
        moNI = embedMaxout.1.shape[2]
        lnG = embedNorm.1.data
        lnB = embedNorm.2.data

        let encoderMaxouts = maxouts.filter { $0.1.shape[2] == 3 * width }
        let encoderNorms = norms.filter { $0.0 != embedNorm.0 }
        guard encoderMaxouts.count == 4, encoderNorms.count == 4 else {
            throw LoadError.malformed(
                "expected 4 encoder blocks, found \(encoderMaxouts.count)"
            )
        }
        for (i, maxout) in encoderMaxouts.enumerated() {
            encW.append(maxout.1.data)
            encB.append(maxout.2.data)
            encG.append(encoderNorms[i].1.data)
            encLB.append(encoderNorms[i].2.data)
        }

        // --- softmax ------------------------------------------------------
        var tagReader = MPReader(readFile(tagPath))
        let tagRoot = tagReader.value()
        guard let tagNodes = tagRoot.m("nodes")?.asArr,
              let tagParams = tagRoot.m("params")?.asArr
        else { throw LoadError.malformed("tagger/model is not a thinc model") }
        var found = false
        for i in 0..<tagNodes.count where tagNodes[i].m("name")?.asStr == "softmax" {
            guard let w = tagParams[i].m("W").map(mpTensor),
                  let b = tagParams[i].m("b").map(mpTensor)
            else { continue }
            softW = w.data
            softB = b.data
            found = true
            break
        }
        guard found, softB.count == labels.count else {
            throw LoadError.malformed(
                "softmax has \(softB.count) outputs for \(labels.count) labels"
            )
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
    func featureIDs(
        token: Token, followedBySpace: Bool
    ) -> [UInt64] {
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

    /// Predict a tag for every token.
    public func tags(for tokens: [Token], text: String) -> [String] {
        guard !tokens.isEmpty else { return [] }
        let count = tokens.count
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
            var block_ = [Float](repeating: 0, count: padded * width)
            for t in 0..<padded {
                for o in 0..<width {
                    var best = encoded[t * width * pieces + o * pieces]
                    for q in 1..<pieces {
                        let value = encoded[t * width * pieces + o * pieces + q]
                        if value > best { best = value }
                    }
                    block_[t * width + o] = best
                }
                layerNorm(&block_, t * width, width, encG[block], encLB[block])
            }
            for i in 0..<(padded * width) { hidden[i] += block_[i] }
        }

        // ---- softmax, argmax ----
        // Only the argmax is needed, so the exponential is skipped: softmax is
        // monotonic in its input, so the largest logit is the predicted tag.
        let classes = labels.count
        var out: [String] = []
        out.reserveCapacity(count)
        for t in 0..<count {
            var bestIndex = 0
            var bestScore = -Float.greatestFiniteMagnitude
            for c in 0..<classes {
                var sum = softB[c]
                let row = c * width
                for j in 0..<width {
                    sum += hidden[(t + pad) * width + j] * softW[row + j]
                }
                if sum > bestScore { bestScore = sum; bestIndex = c }
            }
            out.append(labels[bestIndex])
        }
        return out
    }
}
