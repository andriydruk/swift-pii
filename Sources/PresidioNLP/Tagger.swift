import Foundation

/// spaCy's part-of-speech tagger.
///
/// Exists for one reason: rule-mode lemmatization keys off the coarse POS tag,
/// so exact lemmas are unreachable without it.
///
/// The tagger is a `Softmax` over the pipeline's **shared** tok2vec — see
/// `Tok2Vec`, which owns that network and is shared with the parser.
public final class TaggerModel: @unchecked Sendable {

    /// Fine-grained Penn Treebank tags, in the order the softmax emits them.
    public let labels: [String]

    let tok2vec: Tok2Vec
    var width: Int { tok2vec.width }

    // Output softmax.
    var softW: [Float] = []
    var softB: [Float] = []

    /// Kept as a nested name because that is how callers and tests refer to it;
    /// the cases are shared with every other component loader.
    public typealias LoadError = ComponentLoadError

    /// - Parameters:
    ///   - directory: an unpacked spaCy model directory.
    ///   - component: which `spacy.Tagger.v2` component to read. The tagger is
    ///     the obvious one, but German's `lemmatizer` is the *same architecture*
    ///     — a softmax over the shared tok2vec — differing only in what its
    ///     classes mean: 1,311 edit-tree ids instead of 52 tags. Parameterizing
    ///     this is the whole reason `EditTreeLemmatizer` needs no forward pass
    ///     of its own.
    public init(directory: String, component: String = "tagger") throws {
        let tagPath = directory + "/\(component)/model"
        let cfgPath = directory + "/\(component)/cfg"
        for path in [tagPath, cfgPath] where
            !FileManager.default.fileExists(atPath: path) {
            throw LoadError.missing(path)
        }

        // --- labels -------------------------------------------------------
        // The tagger's labels are strings; the lemmatizer's are integer tree
        // ids. Both are just names for softmax columns here.
        guard let cfg = try? JSONSerialization.jsonObject(
                with: Data(readFile(cfgPath))
              ) as? [String: Any]
        else { throw LoadError.malformed("\(component)/cfg is not JSON") }
        let labels: [String]
        if let strings = cfg["labels"] as? [String] {
            labels = strings
        } else if let numbers = cfg["labels"] as? [Int] {
            labels = numbers.map(String.init)
        } else {
            labels = []
        }
        guard !labels.isEmpty else {
            throw LoadError.malformed("\(component)/cfg has no labels")
        }
        self.labels = labels

        self.tok2vec = try Tok2Vec(path: directory + "/tok2vec/model")

        // --- softmax ------------------------------------------------------
        var tagReader = MPReader(readFile(tagPath))
        let tagRoot = tagReader.value()
        guard let tagNodes = tagRoot.m("nodes")?.asArr,
              let tagParams = tagRoot.m("params")?.asArr
        else { throw LoadError.malformed("\(component)/model is not a thinc model") }
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

    /// Predict a tag for every token.
    public func tags(for tokens: [Token], text: String) -> [String] {
        predictions(for: tokens, text: text).map { labels[$0] }
    }

    /// The argmax softmax column per token, before it is named.
    ///
    /// `tags(for:text:)` turns these into tag strings; the lemmatizer turns the
    /// same numbers into edit-tree ids.
    public func predictions(for tokens: [Token], text: String) -> [Int] {
        guard !tokens.isEmpty else { return [] }
        let hidden = tok2vec.encode(tokens: tokens, text: text)

        // Only the argmax is needed, so the exponential is skipped: softmax is
        // monotonic in its input, so the largest logit is the predicted tag.
        let classes = labels.count
        var out: [Int] = []
        out.reserveCapacity(tokens.count)
        for t in 0..<tokens.count {
            var bestIndex = 0
            var bestScore = -Float.greatestFiniteMagnitude
            for c in 0..<classes {
                var sum = softB[c]
                let row = c * width
                for j in 0..<width {
                    sum += hidden[t * width + j] * softW[row + j]
                }
                if sum > bestScore { bestScore = sum; bestIndex = c }
            }
            out.append(bestIndex)
        }
        return out
    }
}
